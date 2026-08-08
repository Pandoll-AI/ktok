#!/usr/bin/env bash
# Deterministic, offline coverage for bot room selection, legacy monitor
# inactivity, install-daemon argument propagation, and fail-closed defaults.
# Does not require KakaoTalk UI, LaunchAgent writes, or network.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="${KTOK_BIN:-$ROOT/.build/debug/ktok}"
if [[ ! -x "$BIN" ]]; then
  BIN="$ROOT/.build/release/ktok"
fi
if [[ ! -x "$BIN" ]]; then
  echo "ktok binary not found under .build/debug or .build/release" >&2
  exit 2
fi

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT

export KTOK_HOME="$TMP/ktok-home"
export KTOK_NO_ACCESSIBILITY_PROMPT=1
DB="$KTOK_HOME/channel/channel.sqlite"
NOW="2026-01-01T00:00:00Z"
PASS=0
FAIL=0

assert_fails_with() {
  local label="$1"
  local needle="$2"
  shift 2
  local out rc
  set +e
  out="$("$@" 2>&1)"
  rc=$?
  set -e
  if [[ $rc -eq 0 ]]; then
    echo "FAIL: $label (expected non-zero exit)" >&2
    echo "$out" >&2
    FAIL=$((FAIL + 1))
    return
  fi
  if ! printf '%s' "$out" | grep -Fq "$needle"; then
    echo "FAIL: $label (expected message containing: $needle)" >&2
    echo "exit=$rc output:" >&2
    echo "$out" >&2
    FAIL=$((FAIL + 1))
    return
  fi
  echo "ok: $label"
  PASS=$((PASS + 1))
}

assert_ok_contains() {
  local label="$1"
  local needle="$2"
  shift 2
  local out rc
  set +e
  out="$("$@" 2>&1)"
  rc=$?
  set -e
  if [[ $rc -ne 0 ]]; then
    echo "FAIL: $label (expected exit 0, got $rc)" >&2
    echo "$out" >&2
    FAIL=$((FAIL + 1))
    return
  fi
  if ! printf '%s' "$out" | grep -Fq "$needle"; then
    echo "FAIL: $label (expected output containing: $needle)" >&2
    echo "$out" >&2
    FAIL=$((FAIL + 1))
    return
  fi
  echo "ok: $label"
  PASS=$((PASS + 1))
}

# Progress past room selection but stop before KakaoTalk UI (no active account).
assert_selection_ok_offline() {
  local label="$1"
  shift
  local out rc
  set +e
  out="$("$@" 2>&1)"
  rc=$?
  set -e
  if printf '%s' "$out" | grep -Eqi 'Multiple self_control|No default bot room|Use either --chat|Use --all-monitored|must be monitored with mode self_control|No monitored rooms'; then
    echo "FAIL: $label (room selection failed unexpectedly)" >&2
    echo "$out" >&2
    FAIL=$((FAIL + 1))
    return
  fi
  if printf '%s' "$out" | grep -Fq 'Accessibility permission required'; then
    echo "ok: $label (selection passed; stopped at accessibility gate)"
    PASS=$((PASS + 1))
    return
  fi
  # Selection succeeded and environment happened to have account+AX; still ok
  # as long as we did not hit a room-selection failure.
  if [[ $rc -eq 0 ]] || printf '%s' "$out" | grep -Eq 'event.:.started|started'; then
    echo "ok: $label (selection passed; continued past account gate)"
    PASS=$((PASS + 1))
    return
  fi
  echo "FAIL: $label (unexpected outcome after selection)" >&2
  echo "exit=$rc output:" >&2
  echo "$out" >&2
  FAIL=$((FAIL + 1))
}

# As above, but also require the pre-Accessibility selection event to identify
# the expected stable chat ID. This prevents priority tests from passing while
# selecting a different valid room.
assert_selection_with_id() {
  local label="$1"
  local expected_id="$2"
  shift 2
  local out rc
  set +e
  out="$("$@" 2>&1)"
  rc=$?
  set -e
  if printf '%s' "$out" | grep -Eqi 'Multiple self_control|No default bot room|Use either --chat|Use --all-monitored|must be monitored with mode self_control|No monitored rooms|duplicate title'; then
    echo "FAIL: $label (room selection failed unexpectedly)" >&2
    echo "$out" >&2
    FAIL=$((FAIL + 1))
    return
  fi
  local json_compact="\"chat_ids\":\"$expected_id\""
  local json_spaced="\"chat_ids\": \"$expected_id\""
  if ! printf '%s' "$out" | grep -Fq "chat_ids=$expected_id" \
    && ! printf '%s' "$out" | grep -Fq "$json_compact" \
    && ! printf '%s' "$out" | grep -Fq "$json_spaced"; then
    echo "FAIL: $label (expected selected chat_id=$expected_id)" >&2
    echo "exit=$rc output:" >&2
    echo "$out" >&2
    FAIL=$((FAIL + 1))
    return
  fi
  echo "ok: $label (selected chat_id=$expected_id)"
  PASS=$((PASS + 1))
}

write_persona() {
  local name="$1"
  local extra_json_fields="$2"
  mkdir -p "$KTOK_HOME/persona"
  cat >"$KTOK_HOME/persona/${name}.json" <<EOF
{
  "name": "${name}",
  "system_prompt": "test persona for offline selector checks",
  "max_reply_chars": 100,
  "owner_tokens": [],
  "excluded_names": [],
  "triggers": {
    "direct_call": [],
    "greeting": [],
    "empathy": [],
    "question": [],
    "profile": [],
    "search": []
  },
  "fallback_replies": {
    "default": "ok"
  }${extra_json_fields}
}
EOF
}

seed_channel_db() {
  "$BIN" channel status --json >/dev/null
  sqlite3 "$DB" <<SQL
INSERT OR REPLACE INTO channel_chats(
  chat_id, title, last_message, first_seen_at, updated_at, is_monitored, mode, priority
) VALUES
  ('chat_self', 'SelfChat', '', '$NOW', '$NOW', 1, 'self_control', 10),
  ('chat_other', 'OtherRoom', '', '$NOW', '$NOW', 1, 'self_control', 20),
  ('chat_observe', 'ObserveOnly', '', '$NOW', '$NOW', 1, 'observe_only', 30),
  ('chat_unmon', 'Unmonitored', '', '$NOW', '$NOW', 0, 'self_control', 40);
SQL
}

echo "== bot room selector / monitor inactive / daemon args =="
echo "BIN=$BIN"
echo "KTOK_HOME=$KTOK_HOME"

# ---------------------------------------------------------------------------
# 1) Mutual exclusion (no DB required)
# ---------------------------------------------------------------------------
assert_fails_with \
  "mutual exclusion: --chat and --chat-id" \
  "Use either --chat or --chat-id, not both." \
  "$BIN" bot run --persona luna --chat "A" --chat-id chat_x

assert_fails_with \
  "mutual exclusion: --all-monitored and --chat" \
  "Use --all-monitored or an explicit room override, not both." \
  "$BIN" bot run --persona luna --chat "A" --all-monitored

assert_fails_with \
  "mutual exclusion: --all-monitored and --chat-id" \
  "Use --all-monitored or an explicit room override, not both." \
  "$BIN" bot run --persona luna --chat-id chat_x --all-monitored

assert_fails_with \
  "install-daemon mutual exclusion: --chat and --chat-id" \
  "Use either --chat or --chat-id, not both." \
  "$BIN" bot install-daemon --persona luna --chat "A" --chat-id chat_x --dry-run

# ---------------------------------------------------------------------------
# 2) Legacy monitor inactive (fails closed, no KakaoTalk)
# ---------------------------------------------------------------------------
assert_fails_with \
  "monitor inactive exit" \
  "ktok monitor is inactive" \
  "$BIN" monitor "any-room" --persona luna

# ---------------------------------------------------------------------------
# 3) Daemon argument propagation (--dry-run only; no LaunchAgent write/load)
# ---------------------------------------------------------------------------
assert_ok_contains \
  "daemon propagates --chat-id" \
  "<string>--chat-id</string>" \
  "$BIN" bot install-daemon --persona luna --chat-id chat_self --dry-run

assert_ok_contains \
  "daemon propagates chat_id value" \
  "<string>chat_self</string>" \
  "$BIN" bot install-daemon --persona luna --chat-id chat_self --dry-run

assert_ok_contains \
  "daemon propagates --chat title" \
  "<string>--chat</string>" \
  "$BIN" bot install-daemon --persona luna --chat "SelfChat" --dry-run

assert_ok_contains \
  "daemon propagates --all-monitored" \
  "<string>--all-monitored</string>" \
  "$BIN" bot install-daemon --persona luna --all-monitored --dry-run

assert_ok_contains \
  "daemon propagates --trigger-mode" \
  "<string>greeting</string>" \
  "$BIN" bot install-daemon --persona luna --chat-id chat_self --trigger-mode greeting --dry-run

# ---------------------------------------------------------------------------
# 4) Fail-closed defaults with temporary channel DB + persona
# ---------------------------------------------------------------------------
seed_channel_db

# No persona self_* fields and two self_control rooms → fail closed.
write_persona "emptybot" ""
assert_fails_with \
  "fail-closed: multiple self_control without persona default" \
  "Multiple self_control rooms are configured" \
  "$BIN" bot run --persona emptybot --max-loops 1 --dry-run

# Empty channel allowlist path: wipe monitored flags and require unique default.
sqlite3 "$DB" "UPDATE channel_chats SET is_monitored=0;"
assert_fails_with \
  "fail-closed: no default self_control room" \
  "No default bot room is configured" \
  "$BIN" bot run --persona emptybot --max-loops 1 --dry-run

# Restore seed for remaining checks.
seed_channel_db

# Persona self_chat_id must be monitored + self_control.
write_persona "idobserve" ',
  "self_chat_id": "chat_observe"'
assert_fails_with \
  "fail-closed: self_chat_id not self_control" \
  "persona self_chat_id" \
  "$BIN" bot run --persona idobserve --max-loops 1 --dry-run

write_persona "idunmon" ',
  "self_chat_id": "chat_unmon"'
assert_fails_with \
  "fail-closed: self_chat_id not monitored" \
  "persona self_chat_id" \
  "$BIN" bot run --persona idunmon --max-loops 1 --dry-run

# self_chat_title must also be self_control when used as default.
write_persona "titleobserve" ',
  "self_chat_title": "ObserveOnly"'
assert_fails_with \
  "fail-closed: self_chat_title not self_control" \
  "persona self_chat_title" \
  "$BIN" bot run --persona titleobserve --max-loops 1 --dry-run

# Valid self_chat_id wins even when multiple self_control rooms exist.
write_persona "idok" ',
  "self_chat_id": "chat_self",
  "self_chat_title": "OtherRoom"'
assert_selection_with_id \
  "priority: self_chat_id over title and multiple self_control" \
  "chat_self" \
  "$BIN" bot run --persona idok --max-loops 1 --dry-run --json

# Without self_chat_id, self_chat_title that is self_control succeeds offline past selection.
write_persona "titleok" ',
  "self_chat_title": "SelfChat"'
assert_selection_with_id \
  "priority: self_chat_title when id absent" \
  "chat_self" \
  "$BIN" bot run --persona titleok --max-loops 1 --dry-run --json

# Explicit --chat-id also passes selection offline.
assert_selection_with_id \
  "explicit --chat-id selection" \
  "chat_self" \
  "$BIN" bot run --persona emptybot --chat-id chat_self --max-loops 1 --dry-run --json

# Duplicate title must fail before Accessibility/UI, even when chat_id selects
# a monitored self_control row unambiguously in the channel database.
sqlite3 "$DB" <<SQL
INSERT OR REPLACE INTO channel_chats(
  chat_id, title, last_message, first_seen_at, updated_at, is_monitored, mode, priority
) VALUES ('chat_duplicate', 'SelfChat', '', '$NOW', '$NOW', 1, 'self_control', 50);
SQL
write_persona "collisionbot" ',
  "self_chat_id": "chat_duplicate"'
assert_fails_with \
  "fail-closed: duplicate title before UI" \
  "duplicate title 'SelfChat'" \
  "$BIN" bot run --persona collisionbot --max-loops 1 --dry-run --json

# Remove the collision fixture before testing the unique fallback.
sqlite3 "$DB" "DELETE FROM channel_chats WHERE chat_id='chat_duplicate';"

# Unique self_control fallback: leave only one monitored self_control.
sqlite3 "$DB" "UPDATE channel_chats SET is_monitored=0 WHERE chat_id!='chat_self';"
write_persona "fallbackbot" ""
assert_selection_with_id \
  "priority: unique monitored self_control fallback" \
  "chat_self" \
  "$BIN" bot run --persona fallbackbot --max-loops 1 --dry-run --json

echo
echo "passed=$PASS failed=$FAIL"
if [[ $FAIL -ne 0 ]]; then
  exit 1
fi
echo "bot room selector tests passed"
