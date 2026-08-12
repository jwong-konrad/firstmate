#!/usr/bin/env bash
# fm-env-clean.sh - run a command with a deny-by-default environment.
#
# Usage: fm-env-clean.sh [options] [--] [NAME=VALUE ...] <command> [arg ...]
#        fm-env-clean.sh --print-allowed [options]
#
# Options:
#   --allow-file <path>  extra allowed NAMEs, one per line ('#' comments, blank
#                        lines ignored). A missing file is not an error - that is
#                        the default state. Repeatable.
#   --allow <NAME>       one extra allowed NAME. Repeatable.
#   --print-allowed      validate the inputs, print the resolved allowed entries
#                        one per line, and exit without running anything. This is
#                        the spawn-time validation gate and the test hook.
#   -h, --help           print this header.
#
# WHY THIS EXISTS
# ---------------
# firstmate launches a worker by typing a command line into a pane whose shell is
# an ordinary login shell. That shell holds the captain's whole environment, so
# every worker inherited every exported secret. On 2026-07-31 `LINEAR_API_KEY`
# reached a worker that way and its pipeline serialized the value verbatim into a
# public PR description. The leaked variable was the symptom; blanket inheritance
# was the defect. docs/worker-environment.md owns the incident record, the
# verification evidence, and the residual risks this control does NOT cover.
#
# WHAT IT DOES
# ------------
# It runs INSIDE the worker's pane, so it sees that pane's real environment, then
# `exec env -i` with only:
#   1. allowed NAMEs that are actually set in the pane (unset stays unset), and
#   2. the explicit NAME=VALUE assignments passed as arguments.
# Explicit assignments win over copied ones. Everything else is dropped, so a new
# secret in the captain's shell is denied by default rather than by having been
# predicted.
#
# Running in the pane (rather than snapshotting firstmate's own environment) is
# deliberate: TERM, PATH, and the multiplexer's own ids are pane-authoritative,
# and copying firstmate's values instead would hand the worker the wrong terminal
# type and a PATH that never had to resolve the harness binary.
#
# The leading-assignment form mirrors `env`'s own interface, so an existing launch
# line keeps working unchanged when this wrapper is placed in front of it: the
# harness templates' own `VAR=value <harness> ...` prefixes are simply parsed as
# explicit assignments.
#
# WHAT IS NOT ALLOWED THROUGH
# ---------------------------
# Nothing credential-shaped. `SSH_AUTH_SOCK` in particular is dropped, so a worker
# cannot use the captain's ssh-agent. Names added through --allow/--allow-file are
# refused when they look credential-shaped: a real per-project credential belongs
# in the scoped injection seam in bin/fm-spawn.sh, not in a home-wide name list.
set -eu

usage() {
  sed -n '2,52p' "$0" | sed 's/^# \{0,1\}//'
}

# The built-in allowlist. Every entry is a location, a locale, a terminal
# capability, or a network/TLS policy knob - never a credential. A trailing '*'
# matches by prefix. Keep additions to that same standard: if a name could ever
# carry a secret in some home, it does not belong here.
FM_ENV_CLEAN_BUILTIN=(
  # Core process and filesystem context.
  HOME PATH USER LOGNAME SHELL PWD TMPDIR TZ
  # Locale.
  LANG LANGUAGE 'LC_*'
  # Terminal capabilities. Pane-authoritative, which is why this runs in the pane.
  TERM TERMINFO TERMINFO_DIRS TERM_PROGRAM TERM_PROGRAM_VERSION TERM_FEATURES
  COLORTERM COLORFGBG LINES COLUMNS
  # Multiplexer identity. Terminal/session ids the pane owns, which is what
  # fm_backend_detect and discover_supervisor_target/_backend read to find the
  # backend and the pane a worker's own supervision talks to. Ids, never
  # credentials - hence the two cmux names spelled out rather than a 'CMUX_*'
  # prefix, which would also hand over CMUX_SOCKET_PASSWORD.
  TMUX TMUX_PANE
  HERDR_ENV HERDR_PANE_ID HERDR_SESSION HERDR_SOCKET_PATH HERDR_TAB_ID HERDR_WORKSPACE_ID
  'ZELLIJ*'
  CMUX_WORKSPACE_ID CMUX_SURFACE_ID
  # macOS login-session context.
  __CF_USER_TEXT_ENCODING COMMAND_MODE SECURITYSESSIONID
  # Editors and pagers. Not needed for capability, but an unset EDITOR is how a
  # `git commit` with no -m wedges a pane on an interactive editor.
  EDITOR VISUAL GIT_EDITOR PAGER GIT_PAGER LESS
  # Toolchain locations. These are paths; the toolchains they point at are the
  # ones a worker builds and tests with.
  NVM_DIR NVM_BIN NVM_INC
  HOMEBREW_PREFIX HOMEBREW_CELLAR HOMEBREW_REPOSITORY MANPATH INFOPATH
  JAVA_HOME
  SDKMAN_DIR SDKMAN_CANDIDATES_DIR SDKMAN_CANDIDATES_API SDKMAN_PLATFORM
  'CONDA_*' PYENV_ROOT RBENV_ROOT ASDF_DIR ASDF_DATA_DIR VOLTA_HOME
  CARGO_HOME RUSTUP_HOME
  GOPATH GOROOT GOMODCACHE GOCACHE GOTMPDIR
  COREPACK_ENABLE_AUTO_PIN
  # Worktree provider, so a worker's own `treehouse` calls resolve the same pool.
  TREEHOUSE_DIR
  # Network and TLS policy. Without these a worker behind a corporate proxy or a
  # custom CA simply cannot reach the network. See docs/worker-environment.md for
  # the one caveat: a proxy URL can itself embed credentials.
  HTTP_PROXY HTTPS_PROXY ALL_PROXY NO_PROXY FTP_PROXY
  http_proxy https_proxy all_proxy no_proxy ftp_proxy
  SSL_CERT_FILE SSL_CERT_DIR CURL_CA_BUNDLE REQUESTS_CA_BUNDLE NODE_EXTRA_CA_CERTS
)

# Credential-shaped names are refused from --allow/--allow-file. The built-in
# list above is held to the same standard by tests/fm-spawn-env-allowlist.test.sh.
fm_env_clean_name_is_credential_shaped() {  # <name>
  local upper
  upper=$(printf '%s' "$1" | tr '[:lower:]' '[:upper:]')
  case "$upper" in
    *KEY*|*TOKEN*|*SECRET*|*PASSWORD*|*PASSWD*|*CREDENTIAL*|*AUTH*|*PRIVATE*|*COOKIE*|*SIGNING*)
      return 0
      ;;
  esac
  return 1
}

fm_env_clean_valid_name() {  # <name>
  case "$1" in
    '') return 1 ;;
    [!A-Za-z_]*) return 1 ;;
    *[!A-Za-z0-9_]*) return 1 ;;
  esac
  return 0
}

ALLOW_EXTRA=()

fm_env_clean_add_allow() {  # <name> <source>
  local name=$1 source=$2
  if ! fm_env_clean_valid_name "$name"; then
    echo "fm-env-clean.sh: $source: '$name' is not a valid environment variable name (letters, digits, underscore; no wildcards)" >&2
    return 1
  fi
  if fm_env_clean_name_is_credential_shaped "$name"; then
    echo "fm-env-clean.sh: $source: refusing '$name' - it looks like a credential. A credential a worker genuinely needs is passed per project through fm-spawn's injection seam, not allowed fleet-wide by name (docs/worker-environment.md)." >&2
    return 1
  fi
  ALLOW_EXTRA+=("$name")
  return 0
}

fm_env_clean_read_allow_file() {  # <path>
  local file=$1 line name lineno=0
  [ -e "$file" ] || return 0
  if [ ! -r "$file" ]; then
    echo "fm-env-clean.sh: --allow-file $file exists but is not readable" >&2
    return 1
  fi
  while IFS= read -r line || [ -n "$line" ]; do
    lineno=$((lineno + 1))
    line=${line%%#*}
    name=${line#"${line%%[![:space:]]*}"}
    name=${name%"${name##*[![:space:]]}"}
    [ -n "$name" ] || continue
    fm_env_clean_add_allow "$name" "$file line $lineno" || return 1
  done < "$file"
  return 0
}

PRINT_ALLOWED=0
while [ "$#" -gt 0 ]; do
  case "$1" in
    -h|--help) usage; exit 0 ;;
    --print-allowed) PRINT_ALLOWED=1; shift ;;
    --allow-file)
      [ "$#" -ge 2 ] || { echo "fm-env-clean.sh: --allow-file requires a value" >&2; exit 2; }
      fm_env_clean_read_allow_file "$2" || exit 2
      shift 2
      ;;
    --allow-file=*)
      fm_env_clean_read_allow_file "${1#--allow-file=}" || exit 2
      shift
      ;;
    --allow)
      [ "$#" -ge 2 ] || { echo "fm-env-clean.sh: --allow requires a value" >&2; exit 2; }
      fm_env_clean_add_allow "$2" '--allow' || exit 2
      shift 2
      ;;
    --allow=*)
      fm_env_clean_add_allow "${1#--allow=}" '--allow' || exit 2
      shift
      ;;
    --) shift; break ;;
    --*) echo "fm-env-clean.sh: unknown option '$1'" >&2; exit 2 ;;
    *) break ;;
  esac
done

if [ "$PRINT_ALLOWED" = 1 ]; then
  printf '%s\n' "${FM_ENV_CLEAN_BUILTIN[@]}" "${ALLOW_EXTRA[@]+"${ALLOW_EXTRA[@]}"}"
  exit 0
fi

fm_env_clean_name_allowed() {  # <name>
  local name=$1 entry
  for entry in "${FM_ENV_CLEAN_BUILTIN[@]}" "${ALLOW_EXTRA[@]+"${ALLOW_EXTRA[@]}"}"; do
    case "$entry" in
      *'*')
        # shellcheck disable=SC2254  # the trailing '*' is a deliberate prefix match
        case "$name" in ${entry%\*}*) return 0 ;; esac
        ;;
      *)
        if [ "$name" = "$entry" ]; then
          return 0
        fi
        ;;
    esac
  done
  return 1
}

# Copy the allowed names that are actually SET in this pane. An unset name is
# left unset rather than passed through as empty: set-but-empty is a different,
# and occasionally load-bearing, state.
CLEAN_ENV=()
while IFS= read -r envname; do
  fm_env_clean_name_allowed "$envname" || continue
  [ -n "${!envname+set}" ] || continue
  CLEAN_ENV+=("$envname=${!envname}")
done < <(compgen -e || true)

# Explicit assignments come last so they win over anything copied above. Parsing
# stops at the first argument that is not an assignment - that argument is the
# command, exactly as `env` itself behaves.
while [ "$#" -gt 0 ]; do
  case "$1" in
    [A-Za-z_]*=*) CLEAN_ENV+=("$1"); shift ;;
    *) break ;;
  esac
done

if [ "$#" -eq 0 ]; then
  echo "fm-env-clean.sh: no command given" >&2
  exit 2
fi

exec env -i "${CLEAN_ENV[@]+"${CLEAN_ENV[@]}"}" "$@"
