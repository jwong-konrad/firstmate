#!/usr/bin/env bash
# Incremental archiver for agent activity: Claude Code transcripts (subagents
# included) and file-history, firstmate task reports, briefs, teardown ledgers,
# scrollback and scratch snapshots, handoffs, and task screenshots. docs/archive.md
# owns the layout, retention, privacy, and failure modes; this header owns the mechanics.
#
# Staging root (default ~/Code/firstmate-archive, FM_ARCHIVE_ROOT) lives outside
# the repo and outside data/. Transcripts are append-only: a new file is cloned
# (APFS copy-on-write where available), a file that grew gets only its new bytes
# appended (the staged size is the offset, shared with bin/fm-transcript-archive-hook.sh),
# and a file that shrank never overwrites what is archived. file-history and
# screenshots are copied once. Reports, ledgers, briefs, and handoffs are copied
# when they differ, and the old copy is kept beside it as <name>.<UTC time>.bak.
# Each run then appends sha256 entries to MANIFEST-YYYY-MM.sha256 for every staged
# file whose size differs from its latest entry, and runs the secret scan once a
# month (a report of pattern names and counts only; it never prints or stores a match).
#
# Then it mirrors staging to <FMVAULT>/secure/archive/ ONLY when the pinned volume
# is mounted, carries the pinned UUID (~/.config/firstmate/card-volumes), and passes
# a write test (bin/fm-archive-lib.sh fm_card_ok). Otherwise it prints
# "card absent, staging only" and exits 0; it never writes under a bare /Volumes
# path. A card write failure (full, read-only, ejected mid-run) stops the mirror,
# reports it, and leaves staging untouched. Text mirrors before file-history and
# screenshots, so a nearly full card keeps the small, high-value set current.
#
# The internal disk is protected by a free-space floor (FM_ARCHIVE_MIN_FREE_GIB,
# default 15): below it the run refuses with exit 3 and writes nothing, and it is
# rechecked every FM_ARCHIVE_FLOOR_CHECK_EVERY files (default 100) while staging. Polaris DB
# dumps are never sources; only the named paths above are read.
#
# Usage: fm-archive.sh [--no-mirror] [--no-scan] [--scan] [--verify] [--import <dir>]...
#   --no-mirror   stage and write manifests only
#   --no-scan     skip the monthly secret scan even when it is due
#   --scan        run the secret scan now regardless of the monthly marker
#   --verify      verify staged files against the manifests, then exit (1 on a problem)
#   --import <d>  also stage <d>/projects and <d>/file-history, for example the one-off
#                 raw clone of ~/.claude; repeatable
# Environment: FM_HOME (data/ comes from it), FM_ARCHIVE_ROOT, FM_ARCHIVE_CLAUDE_DIR
# (default ~/.claude), FM_ARCHIVE_VAULT_VOLUME (default FMVAULT),
# FM_ARCHIVE_MIRROR_SUBDIR (default secure/archive), FM_ARCHIVE_MIN_FREE_GIB,
# FM_ARCHIVE_CARD_MIN_FREE_GIB (default 2), FM_CARD_VOLUMES_FILE, FM_CARD_MOUNT_ROOT.
# Exit: 0 done or card absent, 1 usage or verify problem, 3 refused below the floor.
set -u

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FM_ROOT="${FM_ROOT_OVERRIDE:-$(cd "$SCRIPT_DIR/.." && pwd)}"
FM_HOME="${FM_HOME:-${FM_ROOT_OVERRIDE:-$FM_ROOT}}"
DATA="${FM_DATA_OVERRIDE:-$FM_HOME/data}"
# shellcheck source=bin/fm-archive-lib.sh
. "$SCRIPT_DIR/fm-archive-lib.sh"
umask 077

CLAUDE=${FM_ARCHIVE_CLAUDE_DIR:-$HOME/.claude}
ROOT=$(fm_archive_root)
VAULT=${FM_ARCHIVE_VAULT_VOLUME:-FMVAULT}
MIRROR_SUB=${FM_ARCHIVE_MIRROR_SUBDIR:-secure/archive}
CARD_MIN_GIB=${FM_ARCHIVE_CARD_MIN_FREE_GIB:-2}

DO_MIRROR=1
SCAN_MODE=auto
VERIFY_ONLY=0
IMPORTS=()
while [ "$#" -gt 0 ]; do
  case "$1" in
    --no-mirror) DO_MIRROR=0 ;;
    --no-scan) SCAN_MODE=off ;;
    --scan) SCAN_MODE=force ;;
    --verify) VERIFY_ONLY=1 ;;
    --import)
      [ "$#" -ge 2 ] || { echo "error: --import needs a directory" >&2; exit 1; }
      IMPORTS+=("$2")
      shift
      ;;
    -h|--help) sed -n '2,/^set -u$/p' "$0" | sed '$d' | sed 's/^# \{0,1\}//'; exit 0 ;;
    *) echo "error: unknown argument: $1" >&2; exit 1 ;;
  esac
  shift
done

say() { printf 'archive: %s\n' "$*"; fm_archive_log "$*"; }

MANIFEST_TAB=$'\t'

# ---------------------------------------------------------------- verification

# Latest manifest entry per path as "<size>\t<sha>\t<rel>".
manifest_latest() {
  cat "$ROOT"/MANIFEST-*.sha256 2>/dev/null | awk -F'\t' 'NF == 4 { s[$4] = $2; h[$4] = $1 } END { for (p in s) print s[p] "\t" h[p] "\t" p }'
}

verify_manifests() {
  local size sha rel actual have bad=0 ok=0 grown=0
  while IFS="$MANIFEST_TAB" read -r size sha rel; do
    [ -n "$rel" ] || continue
    if [ ! -f "$ROOT/$rel" ]; then
      echo "MISSING $rel"
      bad=$((bad + 1))
      continue
    fi
    actual=$(fm_archive_stat_size "$ROOT/$rel")
    if [ "$actual" -lt "$size" ]; then
      echo "TRUNCATED $rel (manifest $size bytes, file $actual)"
      bad=$((bad + 1))
      continue
    fi
    have=$(head -c "$size" "$ROOT/$rel" | fm_archive_sha256)
    if [ "$have" != "$sha" ]; then
      echo "CORRUPT $rel"
      bad=$((bad + 1))
    elif [ "$actual" -gt "$size" ]; then
      grown=$((grown + 1))
    else
      ok=$((ok + 1))
    fi
  done <<EOF
$(manifest_latest)
EOF
  echo "verify: ok=$ok grown-since-manifest=$grown problems=$bad"
  [ "$bad" -eq 0 ]
}

if [ "$VERIFY_ONLY" -eq 1 ]; then
  [ -d "$ROOT" ] || { echo "verify: no archive at $ROOT"; exit 0; }
  verify_manifests
  exit $?
fi

# ------------------------------------------------------------------- preflight

if ! fm_archive_floor_ok "$ROOT"; then
  echo "archive: refused: ${FM_ARCHIVE_FREE_GIB} GiB free on the internal disk, below the ${FM_ARCHIVE_MIN_FREE_GIB:-15} GiB floor; nothing was written" >&2
  exit 3
fi

mkdir -p "$ROOT/.locks" "$ROOT/.state" "$ROOT/reports" || { echo "archive: cannot create $ROOT" >&2; exit 1; }
chmod 700 "$ROOT" 2>/dev/null || true
if [ -f "$ROOT/archive.log" ] && [ "$(fm_archive_stat_size "$ROOT/archive.log")" -gt 1048576 ]; then
  tail -n 2000 "$ROOT/archive.log" > "$ROOT/archive.log.tmp" && mv "$ROOT/archive.log.tmp" "$ROOT/archive.log"
fi

RUN_LOCK="$ROOT/.locks/run"
if ! fm_archive_lock_acquire "$RUN_LOCK" 0; then
  echo "archive: another archive run is active; skipping"
  exit 0
fi
TMPD=$(mktemp -d "${TMPDIR:-/tmp}/fm-archive.XXXXXX")
# shellcheck disable=SC2329
cleanup() {
  rm -rf "$TMPD"
  fm_archive_lock_release "$RUN_LOCK"
}
trap cleanup EXIT

# Orphans from an interrupted copy.
find "$ROOT/transcripts" "$ROOT/file-history" "$ROOT/evidence" "$ROOT/tasks" "$ROOT/handoffs" \
  -type f -name '*.tmp.*' -mmin +120 -delete 2>/dev/null || true

# -------------------------------------------------------------------- staging

N_TR_NEW=0 N_TR_GROWN=0 N_TR_SHRANK=0 N_TR_REWRITTEN=0 N_TR_BUSY=0 N_TR_ERR=0
N_FH=0 N_EV=0 N_TASKS=0 N_HAND=0

FLOOR_TICKS=0
FLOOR_EVERY=${FM_ARCHIVE_FLOOR_CHECK_EVERY:-100}
case "$FLOOR_EVERY" in ''|*[!0-9]*|0) FLOOR_EVERY=100 ;; esac

# floor_tick: call before staging each file; every FLOOR_EVERY files it rechecks the
# internal floor, and once crossed records it and returns 1 so loops stop before
# writing anything more (every copy goes through a temp name, so no partial files).
floor_tick() {
  [ ! -e "$TMPD/floor.stop" ] || return 1
  FLOOR_TICKS=$((FLOOR_TICKS + 1))
  [ $((FLOOR_TICKS % FLOOR_EVERY)) -eq 0 ] || return 0
  if ! fm_archive_floor_ok "$ROOT"; then
    echo "${FM_ARCHIVE_FREE_GIB} GiB free on the internal disk, below the ${FM_ARCHIVE_MIN_FREE_GIB:-15} GiB floor" > "$TMPD/floor.stop"
    return 1
  fi
  return 0
}

copy_once() {  # <src> <dst>: clone to a temp name and move into place; 0 on success
  local tmp
  mkdir -p "$(dirname "$2")" || return 1
  tmp="$2.tmp.$$"
  if fm_archive_clone_copy "$1" "$tmp" && mv "$tmp" "$2"; then
    return 0
  fi
  rm -f "$tmp"
  return 1
}

copy_versioned() {  # <src> <dst>: copy when different, keeping the old copy as a .bak
  local src=$1 dst=$2 stamp
  if [ ! -e "$dst" ]; then
    copy_once "$src" "$dst" && return 0
    return 1
  fi
  cmp -s "$src" "$dst" && return 2
  stamp=$(date -u +%Y%m%dT%H%M%SZ)
  mv "$dst" "$dst.$stamp.bak" 2>/dev/null || mv "$dst" "$dst.$stamp.$$.bak" || return 1
  copy_once "$src" "$dst"
}

stage_transcripts() {  # <claude dir>
  local cdir=$1 rel ssize dsize
  [ -d "$cdir/projects" ] || return 0
  fm_archive_list "$cdir/projects" -type f -name '*.jsonl' > "$TMPD/tr.src"
  fm_archive_list "$ROOT/transcripts" -type f -name '*.jsonl' > "$TMPD/tr.dst"
  while IFS="$MANIFEST_TAB" read -r rel ssize dsize; do
    [ -n "$rel" ] || continue
    floor_tick || break
    if fm_archive_sync_append "$cdir/projects/$rel" "$ROOT/transcripts/$rel" 300; then
      case "$FM_ARCHIVE_SYNC" in
        new) N_TR_NEW=$((N_TR_NEW + 1)) ;;
        grown) N_TR_GROWN=$((N_TR_GROWN + 1)) ;;
        shrank)
          N_TR_SHRANK=$((N_TR_SHRANK + 1))
          fm_archive_log "source shrank, kept the archived copy: $rel (source $ssize, archived $dsize)"
          ;;
        rewritten)
          N_TR_REWRITTEN=$((N_TR_REWRITTEN + 1))
          fm_archive_log "source rewritten, archived copy kept: $rel"
          ;;
        busy) N_TR_BUSY=$((N_TR_BUSY + 1)) ;;
      esac
    else
      N_TR_ERR=$((N_TR_ERR + 1))
    fi
  done <<EOF
$(fm_archive_join "$TMPD/tr.src" "$TMPD/tr.dst")
EOF
}

# Copy files that do not exist in the destination yet. Prints the number copied.
stage_missing() {  # <src root> <dst root> <find expression...>
  local srcroot=$1 dstroot=$2 rel ssize dsize n=0
  shift 2
  [ -d "$srcroot" ] || { echo 0; return 0; }
  fm_archive_list "$srcroot" "$@" > "$TMPD/m.src"
  fm_archive_list "$dstroot" -type f > "$TMPD/m.dst"
  while IFS="$MANIFEST_TAB" read -r rel ssize dsize; do
    [ -n "$rel" ] || continue
    [ "$dsize" = -1 ] || continue
    floor_tick || break
    if copy_once "$srcroot/$rel" "$dstroot/$rel"; then
      n=$((n + 1))
    fi
  done <<EOF
$(fm_archive_join "$TMPD/m.src" "$TMPD/m.dst")
EOF
  echo "$n"
}

# Copy new and changed small curated files. Prints the number copied.
stage_versioned() {  # <src root> <dst root> <find expression...>
  local srcroot=$1 dstroot=$2 rel ssize n=0
  shift 2
  [ -d "$srcroot" ] || { echo 0; return 0; }
  fm_archive_list "$srcroot" "$@" > "$TMPD/v.src"
  while IFS="$MANIFEST_TAB" read -r ssize rel; do
    [ -n "$rel" ] || continue
    floor_tick || break
    if copy_versioned "$srcroot/$rel" "$dstroot/$rel"; then
      n=$((n + 1))
    fi
  done < "$TMPD/v.src"
  echo "$n"
}

stage_all() {
  local cdir n
  stage_transcripts "$CLAUDE"
  for cdir in ${IMPORTS[@]+"${IMPORTS[@]}"}; do
    stage_transcripts "$cdir"
  done
  for cdir in "$CLAUDE" ${IMPORTS[@]+"${IMPORTS[@]}"}; do
    n=$(stage_missing "$cdir/file-history" "$ROOT/file-history" -type f)
    N_FH=$((N_FH + n))
  done
  # data/<id>/{report.md,brief.md,ledger*.json,scrollback.txt,scratch/*}
  N_TASKS=$(stage_versioned "$DATA" "$ROOT/tasks" \
    -path ./handoffs -prune -o -type f \
    \( -path './*/report.md' -o -path './*/brief.md' -o -path './*/ledger*.json' \
       -o -path './*/scrollback.txt' -o -path './*/scratch/*' \))
  N_HAND=$(stage_versioned "$DATA/handoffs" "$ROOT/handoffs" -type f)
  N_EV=$(stage_missing "$DATA" "$ROOT/evidence" \
    -path ./handoffs -prune -o -type f -path './*/shots/*')
}

# ------------------------------------------------------------------- manifest

N_MANIFEST=0
update_manifest() {
  local d month mfile rel ssize sha now
  : > "$TMPD/staged.list"
  for d in transcripts tasks handoffs file-history evidence; do
    fm_archive_list "$ROOT/$d" -type f | awk -F'\t' -v p="$d/" '{ print $1 "\t" p $2 }' >> "$TMPD/staged.list"
  done
  manifest_latest | awk -F'\t' '{ print $1 "\t" $3 }' > "$TMPD/manifest.list"
  month=$(date -u +%Y-%m)
  mfile="$ROOT/MANIFEST-$month.sha256"
  now=$(fm_archive_now_iso)
  while IFS="$MANIFEST_TAB" read -r rel ssize _; do
    [ -n "$rel" ] || continue
    sha=$(head -c "$ssize" "$ROOT/$rel" 2>/dev/null | fm_archive_sha256)
    [ -n "$sha" ] || continue
    printf '%s\t%s\t%s\t%s\n' "$sha" "$ssize" "$now" "$rel" >> "$mfile"
    N_MANIFEST=$((N_MANIFEST + 1))
  done <<EOF
$(fm_archive_join "$TMPD/staged.list" "$TMPD/manifest.list")
EOF
}

# ---------------------------------------------------------------- secret scan

SCAN_NOTE=
secret_scan() {
  local month marker report name pattern files f n total=0
  month=$(date -u +%Y-%m)
  marker="$ROOT/.state/secret-scan-$month"
  case "$SCAN_MODE" in
    off) return 0 ;;
    auto) [ ! -e "$marker" ] || return 0 ;;
  esac
  report="$ROOT/reports/secret-scan-$month.txt"
  {
    echo "# secret scan $(fm_archive_now_iso) - report only: pattern name, match count, file; matches are never printed"
  } > "$report"
  while IFS='|' read -r name pattern; do
    [ -n "$name" ] || continue
    files=$(cd "$ROOT" && grep -rIlE -e "$pattern" transcripts tasks handoffs 2>/dev/null || true)
    [ -n "$files" ] || continue
    while IFS= read -r f; do
      [ -n "$f" ] || continue
      n=$(grep -cE -e "$pattern" "$ROOT/$f" 2>/dev/null || true)
      printf '%s\t%s\t%s\n' "$name" "${n:-0}" "$f" >> "$report"
      total=$((total + 1))
    done <<EOF
$files
EOF
  done <<'EOF'
aws-access-key|AKIA[0-9A-Z]{16}
github-token|gh[pousr]_[A-Za-z0-9]{36,}
slack-token|xox[baprs]-[A-Za-z0-9-]{10,}
private-key|-----BEGIN [A-Z ]*PRIVATE KEY-----
api-key-sk|sk-[A-Za-z0-9_-]{32,}
bearer-token|Bearer [A-Za-z0-9._-]{30,}
EOF
  : > "$marker"
  SCAN_NOTE="secret scan $month: $total file hits, see reports/secret-scan-$month.txt"
}

# --------------------------------------------------------------------- mirror

MIRROR_STATE=skipped
MIRROR_COPIED=0
MIRROR_FAILED=0

mirror_fail() {
  MIRROR_FAILED=1
  say "card write failed ($1); staging is intact, mirror stopped"
}

mirror_phase() {  # <mode: append|missing|replace> <dest root> <subdir> [find expression...]
  local mode=$1 dest=$2 sub=$3 rel ssize dsize srcroot dstroot have
  shift 3
  [ "$MIRROR_FAILED" -eq 0 ] || return 0
  srcroot="$ROOT/$sub"
  dstroot="$dest/$sub"
  [ -d "$srcroot" ] || return 0
  fm_archive_list "$srcroot" "$@" > "$TMPD/mp.src"
  case "$mode" in
    replace)
      while IFS="$MANIFEST_TAB" read -r ssize rel; do
        [ -n "$rel" ] || continue
        [ -e "$dstroot/$rel" ] && cmp -s "$srcroot/$rel" "$dstroot/$rel" && continue
        if copy_replace "$srcroot/$rel" "$dstroot/$rel"; then
          MIRROR_COPIED=$((MIRROR_COPIED + 1))
        else
          mirror_fail "$sub/$rel"
          return 0
        fi
      done < "$TMPD/mp.src"
      ;;
    *)
      fm_archive_list "$dstroot" "$@" > "$TMPD/mp.dst"
      while IFS="$MANIFEST_TAB" read -r rel ssize dsize; do
        [ -n "$rel" ] || continue
        if [ "$mode" = missing ]; then
          [ "$dsize" = -1 ] || continue
          copy_replace "$srcroot/$rel" "$dstroot/$rel" || { mirror_fail "$sub/$rel"; return 0; }
        else
          fm_archive_sync_append "$srcroot/$rel" "$dstroot/$rel" 50 || { mirror_fail "$sub/$rel"; return 0; }
          case "$FM_ARCHIVE_SYNC" in new|grown) ;; *) continue ;; esac
        fi
        # Verify what landed: the card copy must equal the same-length prefix of the source.
        have=$(fm_archive_stat_size "$dstroot/$rel")
        if ! head -c "$have" "$srcroot/$rel" | cmp -s - "$dstroot/$rel"; then
          rm -f "$dstroot/$rel"
          mirror_fail "verify mismatch on $sub/$rel"
          return 0
        fi
        MIRROR_COPIED=$((MIRROR_COPIED + 1))
      done <<EOF
$(fm_archive_join "$TMPD/mp.src" "$TMPD/mp.dst")
EOF
      ;;
  esac
}

copy_replace() {  # <src> <dst>: plain copy through a temp name, replacing any existing file
  local tmp
  mkdir -p "$(dirname "$2")" 2>/dev/null || return 1
  tmp="$2.tmp.$$"
  if cp "$1" "$tmp" 2>/dev/null && mv "$tmp" "$2" 2>/dev/null; then
    return 0
  fi
  rm -f "$tmp" 2>/dev/null
  return 1
}

mirror_manifests() {  # <dest root>
  local dest=$1 f
  [ "$MIRROR_FAILED" -eq 0 ] || return 0
  for f in "$ROOT"/MANIFEST-*.sha256; do
    [ -f "$f" ] || continue
    fm_archive_sync_append "$f" "$dest/$(basename "$f")" 50 || { mirror_fail "$(basename "$f")"; return 0; }
  done
}

mirror_all() {
  local dest
  if ! fm_card_ok "$VAULT"; then
    MIRROR_STATE=absent
    say "card absent, staging only (${FM_CARD_REASON})"
    return 0
  fi
  dest="$FM_CARD_MOUNT/$MIRROR_SUB"
  if ! mkdir -p "$dest" 2>/dev/null; then
    MIRROR_STATE=absent
    say "card absent, staging only (cannot create $dest)"
    return 0
  fi
  if ! fm_archive_floor_ok "$FM_CARD_MOUNT" "$CARD_MIN_GIB"; then
    MIRROR_STATE=full
    say "card nearly full (${FM_ARCHIVE_FREE_GIB} GiB free, floor ${CARD_MIN_GIB} GiB), staging only"
    return 0
  fi
  mirror_phase append "$dest" transcripts -type f \( -name '*.jsonl' -o -name '*.jsonl.rewritten-*' \)
  mirror_phase replace "$dest" tasks -type f
  mirror_phase replace "$dest" handoffs -type f
  mirror_phase replace "$dest" reports -type f
  mirror_manifests "$dest"
  if [ "$MIRROR_FAILED" -eq 0 ] && ! fm_archive_floor_ok "$FM_CARD_MOUNT" "$CARD_MIN_GIB"; then
    MIRROR_STATE=text-only
    say "card nearly full after text mirror (${FM_ARCHIVE_FREE_GIB} GiB free), skipping file-history and screenshots"
    return 0
  fi
  mirror_phase missing "$dest" file-history -type f
  mirror_phase missing "$dest" evidence -type f
  if [ "$MIRROR_FAILED" -eq 0 ]; then
    MIRROR_STATE=ok
  else
    MIRROR_STATE=failed
  fi
}

# ----------------------------------------------------------------------- main

stage_all
if [ -e "$TMPD/floor.stop" ]; then
  echo "archive: stopped: $(cat "$TMPD/floor.stop"); no partial files were left, the next run resumes" >&2
  fm_archive_log "stopped below the free-space floor: $(cat "$TMPD/floor.stop")"
  exit 3
fi
update_manifest
secret_scan
if [ "$DO_MIRROR" -eq 1 ]; then
  mirror_all
else
  MIRROR_STATE=disabled
fi

say "transcripts new=$N_TR_NEW grown=$N_TR_GROWN shrank=$N_TR_SHRANK rewritten=$N_TR_REWRITTEN busy=$N_TR_BUSY errors=$N_TR_ERR; file-history new=$N_FH; tasks changed=$N_TASKS; handoffs changed=$N_HAND; screenshots new=$N_EV; manifest +$N_MANIFEST"
[ -z "$SCAN_NOTE" ] || say "$SCAN_NOTE"
[ "$MIRROR_STATE" != ok ] || say "mirror ok ($MIRROR_COPIED files copied to $FM_CARD_MOUNT/$MIRROR_SUB)"
{
  printf 'time=%s\n' "$(fm_archive_now_iso)"
  printf 'mirror=%s\n' "$MIRROR_STATE"
  printf 'mirror_copied=%s\n' "$MIRROR_COPIED"
  printf 'transcripts_new=%s\n' "$N_TR_NEW"
  printf 'transcripts_grown=%s\n' "$N_TR_GROWN"
} > "$ROOT/.state/last-run"
exit 0
