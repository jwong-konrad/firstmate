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
#   FM_ARCHIVE_VAULT_VOLUME  name of the archive volume to mirror to; no default
#   FM_ARCHIVE_VOLUME_FILE   private config whose first word is that name when the variable is unset
#                            (default ~/.config/firstmate/archive-volume)
#   FM_CARD_VOLUMES_FILE     pinned "<NAME> <Volume UUID>" lines (default ~/.config/firstmate/card-volumes)
#   FM_CARD_MOUNT_ROOT       where card volumes mount (default /Volumes)
#   FM_ARCHIVE_MIN_FREE_GIB  internal free-space floor in GiB (default 15)
#
# FM_ARCHIVE_FREE_GIB, FM_CARD_MOUNT, FM_CARD_REASON, FM_ARCHIVE_SYNC, FM_ARCHIVE_REL, and
# FM_ARCHIVE_REJECT are
# output variables read by the sourcing script.

# shellcheck disable=SC2034
fm_archive_root() {
  printf '%s\n' "${FM_ARCHIVE_ROOT:-$HOME/Code/firstmate-archive}"
}

fm_archive_now_iso() {
  date -u +%Y-%m-%dT%H:%M:%SZ
}

# fm_archive_volume_name: the configured archive volume name, or empty when none is
# configured. There is deliberately no built-in default: the name is private configuration.
fm_archive_volume_name() {
  local name=${FM_ARCHIVE_VAULT_VOLUME:-} f
  if [ -z "$name" ]; then
    f=${FM_ARCHIVE_VOLUME_FILE:-$HOME/.config/firstmate/archive-volume}
    name=$(awk 'NF && $1 !~ /^#/ { print $1; exit }' "$f" 2>/dev/null)
  fi
  printf '%s\n' "$name"
}

# fm_archive_secret_patterns: "<name>|<extended regex>" lines for the credential
# patterns the monthly archive scan and the ledger's scratch snapshot both use.
fm_archive_secret_patterns() {
  cat <<'PATTERNS'
aws-access-key|AKIA[0-9A-Z]{16}
github-token|gh[pousr]_[A-Za-z0-9]{36,}
slack-token|xox[baprs]-[A-Za-z0-9-]{10,}
private-key|-----BEGIN [A-Z ]*PRIVATE KEY-----
api-key-sk|sk-[A-Za-z0-9_-]{32,}
bearer-token|Bearer [A-Za-z0-9._-]{30,}
PATTERNS
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

# fm_archive_mtime_age <path>: whole seconds since <path> was last modified, or
# empty when it cannot be read.
fm_archive_mtime_age() {
  local m
  if [ "$(uname)" = Darwin ]; then
    m=$(stat -f %m "$1" 2>/dev/null)
  else
    m=$(stat -c %Y "$1" 2>/dev/null)
  fi
  case "$m" in ''|*[!0-9]*) return 1 ;; esac
  echo $(( $(date +%s) - m ))
}

# fm_archive_lock_stale <lock-dir>: 0 when the holder is dead, or when no pid was
# ever written and the lock is older than FM_ARCHIVE_LOCK_STALE_SECS (default 30).
fm_archive_lock_stale() {
  local dir=$1 pid age
  pid=$(cat "$dir/pid" 2>/dev/null || true)
  if [ -n "$pid" ]; then
    kill -0 "$pid" 2>/dev/null && return 1
    return 0
  fi
  age=$(fm_archive_mtime_age "$dir") || return 1
  [ "$age" -ge "${FM_ARCHIVE_LOCK_STALE_SECS:-30}" ]
}

# fm_archive_lock_acquire <lock-dir> <tenths-of-seconds-to-wait>: mkdir lock with
# a pid file. A stale lock (see fm_archive_lock_stale) is removed only by the
# holder of a "<lock-dir>.steal" guard that re-checks staleness under the guard,
# so two waiters can never remove a lock another process has just taken. 1 when
# not acquired.
fm_archive_lock_acquire() {
  local dir=$1 tries=${2:-0} guard age
  guard="$dir.steal"
  while :; do
    if mkdir "$dir" 2>/dev/null; then
      printf '%s\n' "$$" > "$dir/pid" 2>/dev/null || true
      return 0
    fi
    if fm_archive_lock_stale "$dir"; then
      if mkdir "$guard" 2>/dev/null; then
        if fm_archive_lock_stale "$dir" && mv "$dir" "$dir.stale.$$" 2>/dev/null; then
          rm -rf "$dir.stale.$$"
          rmdir "$guard" 2>/dev/null || true
          continue
        fi
        rmdir "$guard" 2>/dev/null || true
      else
        age=$(fm_archive_mtime_age "$guard") || age=0
        if [ "$age" -ge "${FM_ARCHIVE_LOCK_STALE_SECS:-30}" ]; then
          rmdir "$guard" 2>/dev/null && continue
        fi
      fi
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
# supports it (APFS), plain copy otherwise. The copy is always made mode 0600,
# because a clone would otherwise keep the source's permissions.
fm_archive_clone_copy() {
  if [ "$(uname)" = Darwin ]; then
    cp -c "$1" "$2" 2>/dev/null || cp "$1" "$2" || return 1
  else
    cp --reflink=auto "$1" "$2" 2>/dev/null || cp "$1" "$2" || return 1
  fi
  chmod 600 "$2" 2>/dev/null || true
}

# fm_archive_prefix_ok <src> <dst> <dst-size>: 0 when the first and last 4 KiB of
# <dst> equal <src> at the same offsets.
fm_archive_prefix_ok() {
  local src=$1 dst=$2 size=$3 n=4096 start
  [ "$size" -ge "$n" ] || n=$size
  [ "$n" -gt 0 ] || return 0
  start=$((size - n))
  cmp -s <(head -c "$n" "$dst") <(head -c "$n" "$src") || return 1
  cmp -s <(tail -c "$n" "$dst") <(tail -c +$((start + 1)) "$src" | head -c "$n")
}

# fm_archive_save_rewritten <src> <dst>: keep a rewritten source beside the
# untouched archive as exactly one <dst>.rewritten-<UTC time> copy, grown by
# appending under the same prefix check; a new copy starts only when the current
# one no longer matches the source's prefix. Sets FM_ARCHIVE_SYNC=rewritten.
fm_archive_save_rewritten() {
  local src=$1 dst=$2 f cur='' src_size cur_size tmp
  for f in "$dst".rewritten-*; do
    [ -f "$f" ] && case "$f" in *.tmp.*) ;; *) cur=$f ;; esac
  done
  src_size=$(fm_archive_stat_size "$src") || return 0
  if [ -n "$cur" ]; then
    cur_size=$(fm_archive_stat_size "$cur") || cur_size=
    if [ -n "$cur_size" ] && fm_archive_prefix_ok "$src" "$cur" "$cur_size"; then
      FM_ARCHIVE_SYNC=rewritten
      if [ "$src_size" -gt "$cur_size" ]; then
        tail -c +$((cur_size + 1)) "$src" >> "$cur" 2>/dev/null || FM_ARCHIVE_SYNC=error
      fi
      return 0
    fi
  fi
  f="$dst.rewritten-$(date -u +%Y%m%dT%H%M%SZ)"
  [ ! -e "$f" ] || f="$f.$$"
  tmp="$f.tmp.$$"
  if fm_archive_clone_copy "$src" "$tmp" && mv "$tmp" "$f"; then
    FM_ARCHIVE_SYNC=rewritten
    fm_archive_log "source rewritten, kept the archived copy and saved the new source as $f"
  else
    rm -f "$tmp"
  fi
}

# fm_archive_sync_append <src> <dst> [lock-wait-tenths]: make <dst> hold <src>'s
# bytes by copying only what <dst> lacks. The staged size IS the offset, so the
# nightly archiver and the Stop hook agree without separate state and both are
# idempotent. A source that shrank never overwrites what is already archived.
# A source that grew is appended only when the staged bytes are still a prefix of
# it (first and last 4 KiB compared); otherwise the archived copy is untouched,
# the new source is saved beside it as one <dst>.rewritten-<UTC time> copy that
# later growth is appended to, and the result
# is "rewritten".
# Sets FM_ARCHIVE_SYNC to one of: new grown same shrank rewritten busy error.
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
      if fm_archive_prefix_ok "$src" "$dst" "$dst_size"; then
        if tail -c +$((dst_size + 1)) "$src" >> "$dst" 2>/dev/null; then
          FM_ARCHIVE_SYNC=grown
        fi
      else
        fm_archive_save_rewritten "$src" "$dst"
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

# fm_archive_transcript_rel <transcript-path> [claude-dir]: set FM_ARCHIVE_REL to the
# staged path of a transcript relative to <root>/transcripts and return 0, or return 1
# with FM_ARCHIVE_REJECT set to a short reason. It is called directly, never inside
# $(...), so both variables survive. A path is accepted only
# when it is absolute, contains no ".." component, is not a symlink itself, ends in
# .jsonl, and resolves (symlinked directories included) to a file under
# <claude-dir>/projects. Everything else is refused, so a hook payload cannot make
# the archive read an arbitrary file or write outside transcripts/.
fm_archive_transcript_rel() {
  local path=$1 claude=${2:-${FM_ARCHIVE_CLAUDE_DIR:-$HOME/.claude}} dir base rroot rdir
  FM_ARCHIVE_REJECT=
  FM_ARCHIVE_REL=
  case "$path" in
    /*) ;;
    *) FM_ARCHIVE_REJECT="path is not absolute"; return 1 ;;
  esac
  case "/$path/" in
    */../*|*/./*) FM_ARCHIVE_REJECT="path contains a dot component"; return 1 ;;
  esac
  case "$path" in
    *.jsonl) ;;
    *) FM_ARCHIVE_REJECT="not a .jsonl file"; return 1 ;;
  esac
  if [ -L "$path" ]; then
    FM_ARCHIVE_REJECT="path is a symlink"
    return 1
  fi
  [ -f "$path" ] || { FM_ARCHIVE_REJECT="not a regular file"; return 1; }
  rroot=$(cd "$claude/projects" 2>/dev/null && pwd -P) || { FM_ARCHIVE_REJECT="no projects directory"; return 1; }
  dir=$(dirname "$path")
  base=$(basename "$path")
  rdir=$(cd "$dir" 2>/dev/null && pwd -P) || { FM_ARCHIVE_REJECT="directory not resolvable"; return 1; }
  case "$rdir/" in
    "$rroot/"*) ;;
    *) FM_ARCHIVE_REJECT="outside the projects directory"; return 1 ;;
  esac
  FM_ARCHIVE_REL="${rdir#"$rroot"}/$base"
  FM_ARCHIVE_REL=${FM_ARCHIVE_REL#/}
}
