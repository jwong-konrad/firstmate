#!/usr/bin/env bash
# Shared primitives for the cold archive (docs/archive.md): the staging root,
# the card mount check, the internal free-space floor, per-file locks, and the
# append-only transcript sync that both bin/fm-archive.sh and
# bin/fm-transcript-archive-hook.sh use.
#
# Source this; it sets no shell options and prints nothing on load.
#
# Test and operator seams (all optional):
#   FM_ARCHIVE_ROOT          staging root (default ~/Code/firstmate-archive)
#   FM_CARD_VOLUMES_FILE     pinned "<NAME> <Volume UUID>" lines (default ~/.config/firstmate/card-volumes)
#   FM_CARD_MOUNT_ROOT       where card volumes mount (default /Volumes)
#   FM_ARCHIVE_MIN_FREE_GIB  internal free-space floor in GiB (default 15)
#
# FM_ARCHIVE_FREE_GIB, FM_CARD_MOUNT, FM_CARD_REASON, and FM_ARCHIVE_SYNC are
# output variables read by the sourcing script.

# shellcheck disable=SC2034
fm_archive_root() {
  printf '%s\n' "${FM_ARCHIVE_ROOT:-$HOME/Code/firstmate-archive}"
}

fm_archive_now_iso() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

# fm_archive_log <message>: append one line to <root>/archive.log when the root
# exists; never prints, never fails.
fm_archive_log() {
  local root
  root=$(fm_archive_root)
  [ -d "$root" ] || return 0
  printf '%s %s\n' "$(fm_archive_now_iso)" "$*" >> "$root/archive.log" 2>/dev/null || true
}

fm_archive_stat_size() {  # <path>
  if [ "$(uname)" = Darwin ]; then
    stat -f %z "$1" 2>/dev/null
  else
    stat -c %s "$1" 2>/dev/null
  fi
}

# fm_archive_sha256: hex sha256 of stdin.
fm_archive_sha256() {
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum | cut -d' ' -f1
  else
    shasum -a 256 | cut -d' ' -f1
  fi
}

# fm_archive_list <root> <find-expression...>: print "<size><TAB><relative path>"
# for every file the find expression prints. The expression is evaluated from
# inside <root> with paths starting "./"; it carries no action of its own (an -exec stat is appended).
fm_archive_list() {
  local root=$1
  shift
  [ -d "$root" ] || return 0
  (
    cd "$root" 2>/dev/null || exit 0
    if [ "$(uname)" = Darwin ]; then
      find . "$@" -exec stat -f $'%z\t%N' {} + 2>/dev/null
    else
      find . "$@" -exec stat -c $'%s\t%n' {} + 2>/dev/null
    fi
  ) | awk -F'\t' 'NF >= 2 { sub(/^\.\//, "", $2); print $1 "\t" $2 }'
}

# fm_archive_join <src-list> <dst-list>: print "<rel><TAB><src size><TAB><dst size>"
# for every source file that is missing from the destination (dst size -1) or has
# a different size there.
fm_archive_join() {
  awk -F'\t' -v dstf="$2" '
    FILENAME == dstf { d[$2] = $1; next }
    {
      if (!($2 in d)) print $2 "\t" $1 "\t-1"
      else if (d[$2] != $1) print $2 "\t" $1 "\t" d[$2]
    }
  ' "$2" "$1"
}

# fm_archive_free_kib <path>: free KiB on the filesystem holding <path>, or its
# nearest existing ancestor when it does not exist yet.
fm_archive_free_kib() {
  local p=$1
  while [ -n "$p" ] && [ ! -e "$p" ] && [ "$p" != / ]; do
    p=$(dirname "$p")
  done
  df -Pk "$p" 2>/dev/null | awk 'NR == 2 { print $4 }'
}

# fm_archive_floor_ok <path> [min-gib]: 0 when at least the floor is free on the
# filesystem holding <path>; 1 below it or when the free space cannot be read
# (refuse rather than risk filling the disk). Sets FM_ARCHIVE_FREE_GIB.
fm_archive_floor_ok() {
  local path=$1 min=${2:-${FM_ARCHIVE_MIN_FREE_GIB:-15}} free_kib
  case "$min" in ''|*[!0-9]*) min=15 ;; esac
  free_kib=$(fm_archive_free_kib "$path")
  case "$free_kib" in ''|*[!0-9]*) FM_ARCHIVE_FREE_GIB=unknown; return 1 ;; esac
  FM_ARCHIVE_FREE_GIB=$((free_kib / 1048576))
  [ "$free_kib" -ge $((min * 1048576)) ]
}

# fm_card_ok <volume-name>: 0 only when the pinned volume is mounted, carries the
# pinned UUID, and a write test succeeds. Otherwise returns 2 (not mounted), 3
# (wrong volume or no pin), 4 (not writable), or 5 (diskutil unavailable).
# Sets FM_CARD_MOUNT to the mount point and FM_CARD_REASON to a one-line reason.
# It never creates anything under the mount root until the mount is proven, so a
# missing card cannot make a stray directory appear under a bare /Volumes path.
fm_card_ok() {
  local vol=$1 root mp want have probe
  root=${FM_CARD_MOUNT_ROOT:-/Volumes}
  mp="$root/$vol"
  FM_CARD_MOUNT=$mp
  FM_CARD_REASON=
  if ! mount 2>/dev/null | grep -qF " on $mp ("; then
    FM_CARD_REASON="not mounted: $mp"
    return 2
  fi
  want=$(awk -v v="$vol" '$1 == v { print $2 }' "${FM_CARD_VOLUMES_FILE:-$HOME/.config/firstmate/card-volumes}" 2>/dev/null)
  if [ -z "$want" ]; then
    FM_CARD_REASON="no pinned UUID for $vol"
    return 3
  fi
  if ! command -v diskutil >/dev/null 2>&1; then
    FM_CARD_REASON="diskutil unavailable, cannot verify the volume UUID"
    return 5
  fi
  have=$(diskutil info "$mp" 2>/dev/null | awk -F': *' '/Volume UUID/ { print $2; exit }')
  if [ "$have" != "$want" ]; then
    FM_CARD_REASON="wrong volume at $mp (UUID ${have:-unknown})"
    return 3
  fi
  probe="$mp/.fm-write-test.$$"
  if ! { : > "$probe"; } 2>/dev/null; then
    FM_CARD_REASON="not writable: $mp"
    return 4
  fi
  rm -f "$probe"
  return 0
}

# fm_archive_lock_acquire <lock-dir> <tenths-of-seconds-to-wait>: mkdir lock with
# a pid file; a lock whose pid is dead is stolen atomically. 1 when not acquired.
fm_archive_lock_acquire() {
  local dir=$1 tries=${2:-0} pid
  while :; do
    if mkdir "$dir" 2>/dev/null; then
      printf '%s\n' "$$" > "$dir/pid" 2>/dev/null || true
      return 0
    fi
    pid=$(cat "$dir/pid" 2>/dev/null || true)
    if [ -n "$pid" ] && ! kill -0 "$pid" 2>/dev/null; then
      if mv "$dir" "$dir.stale.$$" 2>/dev/null; then
        rm -rf "$dir.stale.$$"
      fi
      continue
    fi
    [ "$tries" -gt 0 ] || return 1
    tries=$((tries - 1))
    sleep 0.1
  done
}

fm_archive_lock_release() {  # <lock-dir>
  rm -rf "$1" 2>/dev/null || true
}

# fm_archive_clone_copy <src> <dst>: copy-on-write clone where the filesystem
# supports it (APFS), plain copy otherwise.
fm_archive_clone_copy() {
  if [ "$(uname)" = Darwin ]; then
    cp -c "$1" "$2" 2>/dev/null && return 0
  else
    cp --reflink=auto "$1" "$2" 2>/dev/null && return 0
  fi
  cp "$1" "$2"
}

# fm_archive_sync_append <src> <dst> [lock-wait-tenths]: make <dst> hold <src>'s
# bytes by copying only what <dst> lacks. The staged size IS the offset, so the
# nightly archiver and the Stop hook agree without separate state and both are
# idempotent. A source that shrank never overwrites what is already archived.
# Sets FM_ARCHIVE_SYNC to one of: new grown same shrank busy error.
fm_archive_sync_append() {
  local src=$1 dst=$2 wait=${3:-300} root lock src_size dst_size tmp
  FM_ARCHIVE_SYNC=error
  src_size=$(fm_archive_stat_size "$src") || return 1
  [ -n "$src_size" ] || return 1
  mkdir -p "$(dirname "$dst")" 2>/dev/null || return 1
  root=$(fm_archive_root)
  mkdir -p "$root/.locks" 2>/dev/null || return 1
  lock="$root/.locks/f-$(printf '%s' "$dst" | cksum | cut -d' ' -f1)"
  if ! fm_archive_lock_acquire "$lock" "$wait"; then
    FM_ARCHIVE_SYNC=busy
    return 0
  fi
  if [ ! -e "$dst" ]; then
    tmp="$dst.tmp.$$"
    if fm_archive_clone_copy "$src" "$tmp" && mv "$tmp" "$dst"; then
      FM_ARCHIVE_SYNC=new
    else
      rm -f "$tmp"
    fi
  else
    dst_size=$(fm_archive_stat_size "$dst") || dst_size=
    if [ -z "$dst_size" ]; then
      :
    elif [ "$src_size" -gt "$dst_size" ]; then
      if tail -c +$((dst_size + 1)) "$src" >> "$dst" 2>/dev/null; then
        FM_ARCHIVE_SYNC=grown
      fi
    elif [ "$src_size" -eq "$dst_size" ]; then
      FM_ARCHIVE_SYNC=same
    else
      FM_ARCHIVE_SYNC=shrank
    fi
  fi
  fm_archive_lock_release "$lock"
  [ "$FM_ARCHIVE_SYNC" != error ]
}

# fm_archive_transcript_rel <transcript-path> [claude-dir]: the staged path of a
# transcript relative to <root>/transcripts. A file under <claude-dir>/projects
# keeps its relative path; anything else is filed under _other by checksum.
fm_archive_transcript_rel() {
  local path=$1 claude=${2:-${FM_ARCHIVE_CLAUDE_DIR:-$HOME/.claude}} base
  case "$path" in
    "$claude/projects/"*) printf '%s\n' "${path#"$claude/projects/"}" ;;
    *)
      base=$(basename "$path")
      printf '_other/%s-%s\n' "$(printf '%s' "$path" | cksum | cut -d' ' -f1)" "$base"
      ;;
  esac
}
