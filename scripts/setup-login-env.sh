#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/setup-login-env.sh [--alias <alias>] [--env-file <path>] [--login]

Interactively configure ktok login credentials.

Default behavior:
  - Writes non-secret login settings to ~/.ktok/config/.env
  - Saves the password in macOS Keychain:
      service: ktok
      account: login:<alias>
  - Removes KTOK_LOGIN_<ALIAS>_PASSWORD from the env file if present

Options:
  --alias <alias>     Default alias to edit. Defaults to work.
  --env-file <path>   Env file to update. Defaults to ~/.ktok/config/.env.
  --login             Run "ktok login <alias>" after saving.
  -h, --help          Show this help.
EOF
}

env_file="${KTOK_LOGIN_ENV_FILE:-${KTOK_ENV_FILE:-$HOME/.ktok/config/.env}}"
alias_input="work"
run_login=false

while [[ $# -gt 0 ]]; do
  case "$1" in
    --alias)
      [[ $# -ge 2 ]] || { echo "Missing value for --alias" >&2; exit 2; }
      alias_input="$2"
      shift 2
      ;;
    --env-file)
      [[ $# -ge 2 ]] || { echo "Missing value for --env-file" >&2; exit 2; }
      env_file="$2"
      shift 2
      ;;
    --login)
      run_login=true
      shift
      ;;
    -h|--help)
      usage
      exit 0
      ;;
    *)
      echo "Unknown option: $1" >&2
      usage >&2
      exit 2
      ;;
  esac
done

if [[ ! -t 0 ]]; then
  echo "This script is interactive. Run it from a terminal so the password prompt can hide input." >&2
  exit 1
fi

restore_tty() {
  stty echo 2>/dev/null || true
}
trap restore_tty EXIT

trim() {
  sed -E 's/^[[:space:]]+//; s/[[:space:]]+$//' <<<"$1"
}

normalize_alias() {
  local raw upper normalized
  raw="$(trim "$1")"
  [[ -n "$raw" ]] || return 1
  upper="$(printf '%s' "$raw" | tr '[:lower:]' '[:upper:]')"
  [[ "$upper" =~ ^[A-Z0-9_-]+$ ]] || return 1
  normalized="${upper//-/_}"
  normalized="$(sed -E 's/_+/_/g; s/^_+//; s/_+$//' <<<"$normalized")"
  [[ -n "$normalized" ]] || return 1
  printf '%s' "$normalized"
}

to_lower() {
  tr '[:upper:]' '[:lower:]' <<<"$1"
}

prompt() {
  local __var="$1"
  local label="$2"
  local default="${3:-}"
  local value

  if [[ -n "$default" ]]; then
    read -r -p "$label [$default]: " value
    value="${value:-$default}"
  else
    read -r -p "$label: " value
  fi

  printf -v "$__var" '%s' "$value"
}

prompt_yes_no() {
  local __var="$1"
  local label="$2"
  local default="${3:-n}"
  local suffix answer normalized

  if [[ "$default" == "y" ]]; then
    suffix="[Y/n]"
  else
    suffix="[y/N]"
  fi

  while true; do
    read -r -p "$label $suffix: " answer
    answer="${answer:-$default}"
    normalized="$(to_lower "$(trim "$answer")")"
    case "$normalized" in
      y|yes) printf -v "$__var" '%s' "true"; return 0 ;;
      n|no) printf -v "$__var" '%s' "false"; return 0 ;;
      *) echo "Please answer y or n." ;;
    esac
  done
}

prompt_secret_confirmed() {
  local __var="$1"
  local first second

  while true; do
    printf 'KakaoTalk password: '
    stty -echo
    IFS= read -r first
    stty echo
    printf '\n'

    if [[ -z "$first" ]]; then
      echo "Password is required."
      continue
    fi

    printf 'Confirm password: '
    stty -echo
    IFS= read -r second
    stty echo
    printf '\n'

    if [[ "$first" == "$second" ]]; then
      printf -v "$__var" '%s' "$first"
      return 0
    fi

    echo "Passwords did not match. Try again."
  done
}

dotenv_quote() {
  local value="$1"
  value="${value//\\/\\\\}"
  value="${value//\"/\\\"}"
  value="${value//$'\n'/\\n}"
  value="${value//$'\r'/\\r}"
  value="${value//$'\t'/\\t}"
  printf '"%s"' "$value"
}

keychain_has_password() {
  local alias_lower="$1"
  security find-generic-password -s ktok -a "login:${alias_lower}" -w >/dev/null 2>&1
}

save_password_to_keychain() {
  local alias_lower="$1"
  local password="$2"
  security add-generic-password -U -s ktok -a "login:${alias_lower}" -w "$password" >/dev/null
}

if ! command -v security >/dev/null 2>&1; then
  echo "macOS 'security' command not found. Cannot save ktok password to Keychain." >&2
  exit 1
fi

prompt alias_input "Login alias" "$alias_input"
if ! alias_normalized="$(normalize_alias "$alias_input")"; then
  echo "Invalid alias. Use letters, numbers, dash, or underscore." >&2
  exit 1
fi
alias_lower="$(to_lower "$alias_normalized" | tr -d '\n')"

prompt account_id "KakaoTalk account ID/email/phone"
account_id="$(trim "$account_id")"
if [[ -z "$account_id" ]]; then
  echo "Account ID is required." >&2
  exit 1
fi

prompt profile_name "KakaoTalk profile name for verification (optional)"
profile_name="$(trim "$profile_name")"

prompt_yes_no keep_logged_in "Keep KakaoTalk logged in" "y"

replace_password="true"
if keychain_has_password "$alias_lower"; then
  prompt_yes_no replace_password "Keychain already has password for login:${alias_lower}. Replace it" "n"
fi

if [[ "$replace_password" == "true" ]]; then
  prompt_secret_confirmed password
  save_password_to_keychain "$alias_lower" "$password"
  unset password
fi

env_file="${env_file/#\~/$HOME}"
env_dir="$(dirname "$env_file")"
mkdir -p "$env_dir"
touch "$env_file"
chmod 600 "$env_file"

id_key="KTOK_LOGIN_${alias_normalized}_ID"
password_key="KTOK_LOGIN_${alias_normalized}_PASSWORD"
profile_key="KTOK_LOGIN_${alias_normalized}_PROFILE_NAME"
keep_key="KTOK_LOGIN_${alias_normalized}_KEEP_LOGGED_IN"

tmp_file="$(mktemp "${TMPDIR:-/tmp}/ktok-env.XXXXXX")"
cleanup() {
  rm -f "$tmp_file"
  restore_tty
}
trap cleanup EXIT

remove_re="^(export[[:space:]]+)?(${id_key}|${password_key}|${profile_key}|${keep_key})="
grep -Ev "$remove_re" "$env_file" > "$tmp_file" || true

{
  printf '\n'
  printf '# ktok login alias: %s\n' "$alias_lower"
  printf '%s=%s\n' "$id_key" "$(dotenv_quote "$account_id")"
  if [[ -n "$profile_name" ]]; then
    printf '%s=%s\n' "$profile_key" "$(dotenv_quote "$profile_name")"
  fi
  printf '%s=%s\n' "$keep_key" "$keep_logged_in"
} >> "$tmp_file"

install -m 600 "$tmp_file" "$env_file"

cat <<EOF

Saved ktok login settings.

Env file:
  $env_file

Alias:
  $alias_lower

Password:
  macOS Keychain service 'ktok', account 'login:${alias_lower}'

Next:
  ktok login ${alias_lower}
  ktok whoami --json
EOF

if [[ "$run_login" == "true" ]]; then
  echo
  ktok login "$alias_lower"
fi
