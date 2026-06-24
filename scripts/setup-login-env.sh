#!/usr/bin/env bash
set -euo pipefail

usage() {
  cat <<'EOF'
Usage: scripts/setup-login-env.sh [--alias <alias>] [--env-file <path>] [--keychain <path>] [--ktok-bin <path>] [--login]

Interactively configure ktok login credentials.

Default behavior:
  - Writes non-secret login settings to ~/.ktok/config/.env
  - Saves the password in macOS Keychain:
      service: ktok
      account: login:<alias>
  - Writes KTOK_KEYCHAIN_PATH so ktok reads the same Keychain file
  - Removes KTOK_LOGIN_<ALIAS>_PASSWORD from the env file if present

Options:
  --alias <alias>     Default alias to edit. Defaults to work.
  --env-file <path>   Env file to update. Defaults to ~/.ktok/config/.env.
  --keychain <path>   Keychain file. Defaults to ~/Library/Keychains/login.keychain-db.
  --ktok-bin <path>   ktok binary to trust for Keychain access. Defaults to command -v ktok.
  --login             Run "ktok login <alias>" after saving.
  -h, --help          Show this help.
EOF
}

env_file="${KTOK_LOGIN_ENV_FILE:-${KTOK_ENV_FILE:-$HOME/.ktok/config/.env}}"
alias_input="work"
run_login=false
keychain_path="${KTOK_KEYCHAIN_PATH:-$HOME/Library/Keychains/login.keychain-db}"
ktok_bin="${KTOK_BIN:-}"
ktok_bin_resolved=""

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
    --keychain)
      [[ $# -ge 2 ]] || { echo "Missing value for --keychain" >&2; exit 2; }
      keychain_path="$2"
      shift 2
      ;;
    --ktok-bin)
      [[ $# -ge 2 ]] || { echo "Missing value for --ktok-bin" >&2; exit 2; }
      ktok_bin="$2"
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

if [[ "$(id -u)" -eq 0 ]]; then
  cat >&2 <<'EOF'
Do not run this script with sudo.

sudo stores files and Keychain items as root, which makes ktok unable to read
them as your normal macOS user. Fix ownership first if a previous sudo run
created root-owned files.
EOF
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

resolve_existing_path() {
  local path="$1"
  local dir base target

  while [[ -L "$path" ]]; do
    dir="$(cd "$(dirname "$path")" && pwd -P)"
    base="$(basename "$path")"
    target="$(readlink "$dir/$base")"
    case "$target" in
      /*) path="$target" ;;
      *) path="$dir/$target" ;;
    esac
  done

  dir="$(cd "$(dirname "$path")" && pwd -P)"
  base="$(basename "$path")"
  printf '%s/%s' "$dir" "$base"
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
  security find-generic-password -s ktok -a "login:${alias_lower}" -w "$keychain_path" >/dev/null 2>&1
}

save_password_to_keychain() {
  local alias_lower="$1"
  local password="$2"
  local output status
  local args

  security delete-generic-password -s ktok -a "login:${alias_lower}" "$keychain_path" >/dev/null 2>&1 || true

  args=(add-generic-password -s ktok -a "login:${alias_lower}")
  if [[ -n "$ktok_bin" ]]; then
    args+=(-T "$ktok_bin")
  fi
  if [[ -n "$ktok_bin_resolved" && "$ktok_bin_resolved" != "$ktok_bin" ]]; then
    args+=(-T "$ktok_bin_resolved")
  fi
  args+=(-T /usr/bin/security -w "$password" "$keychain_path")

  if output=$(security "${args[@]}" 2>&1 >/dev/null); then
    return 0
  fi

  status=$?
  if grep -q "User interaction is not allowed" <<<"$output"; then
    unlock_keychain
    security "${args[@]}" >/dev/null
    return
  fi

  printf '%s\n' "$output" >&2
  return "$status"
}

if ! command -v security >/dev/null 2>&1; then
  echo "macOS 'security' command not found. Cannot save ktok password to Keychain." >&2
  exit 1
fi

keychain_path="${keychain_path/#\~/$HOME}"
if [[ ! -f "$keychain_path" ]]; then
  cat >&2 <<EOF
User login keychain not found:
  $keychain_path

Create or unlock your login keychain in Keychain Access, or pass --keychain <path>.
EOF
  exit 1
fi

if [[ ! -w "$keychain_path" ]]; then
  cat >&2 <<EOF
User login keychain is not writable:
  $keychain_path

Do not use sudo. Check ownership/permissions in ~/Library/Keychains.
EOF
  exit 1
fi

if [[ -z "$ktok_bin" ]]; then
  ktok_bin="$(command -v ktok || true)"
fi

if [[ -n "$ktok_bin" ]]; then
  ktok_bin="${ktok_bin/#\~/$HOME}"
  if [[ ! -x "$ktok_bin" ]]; then
    cat >&2 <<EOF
ktok binary is not executable:
  $ktok_bin

Install ktok globally first, or pass --ktok-bin <path>.
EOF
    exit 1
  fi
  ktok_bin_resolved="$(resolve_existing_path "$ktok_bin")"
  if [[ ! -x "$ktok_bin_resolved" ]]; then
    cat >&2 <<EOF
Resolved ktok binary is not executable:
  $ktok_bin_resolved

Install ktok globally first, or pass --ktok-bin <path>.
EOF
    exit 1
  fi
else
  cat >&2 <<'EOF'
ktok binary was not found in PATH.

Install ktok globally first, or pass --ktok-bin <path>. The script needs this
path so Keychain can allow ktok to read the saved password without a prompt.
EOF
  exit 1
fi

unlock_keychain() {
  cat >&2 <<EOF
The login keychain is locked or cannot prompt from this session.
Unlock it now with your macOS login/keychain password.

Keychain:
  $keychain_path

EOF
  security unlock-keychain "$keychain_path"
}

if ! security show-keychain-info "$keychain_path" >/dev/null 2>&1; then
  unlock_keychain
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
  prompt_yes_no replace_password "Keychain already has password for login:${alias_lower}. Replace it so ktok is trusted" "y"
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
keychain_key="KTOK_KEYCHAIN_PATH"

tmp_file="$(mktemp "${TMPDIR:-/tmp}/ktok-env.XXXXXX")"
cleanup() {
  rm -f "$tmp_file"
  restore_tty
}
trap cleanup EXIT

remove_re="^(export[[:space:]]+)?(${id_key}|${password_key}|${profile_key}|${keep_key}|${keychain_key})="
grep -Ev "$remove_re" "$env_file" > "$tmp_file" || true

{
  printf '\n'
  printf '# ktok login alias: %s\n' "$alias_lower"
  printf '%s=%s\n' "$keychain_key" "$(dotenv_quote "$keychain_path")"
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
  macOS Keychain:
    file: $keychain_path
    service: ktok
    account: login:${alias_lower}
    trusted app: $ktok_bin
    trusted app resolved: $ktok_bin_resolved

Next:
  ktok login ${alias_lower}
  ktok whoami --json
EOF

if [[ "$run_login" == "true" ]]; then
  echo
  ktok login "$alias_lower"
fi
