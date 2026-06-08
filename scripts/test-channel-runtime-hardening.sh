#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
BIN="${KTOK_BIN:-$ROOT/.build/release/ktok}"
if [[ ! -x "$BIN" ]]; then
  echo "ktok binary not found: $BIN" >&2
  exit 2
fi

TMP="$(mktemp -d)"
cleanup() { rm -rf "$TMP"; }
trap cleanup EXIT
export KTOK_HOME="$TMP/ktok-home"
DB="$KTOK_HOME/channel/channel.sqlite"
NOW="2026-01-01T00:00:00Z"

json_field() {
  python3 -c 'import json,sys; data=json.load(sys.stdin); key=sys.argv[1]; obj=data[0] if isinstance(data, list) else data; val=obj.get(key, ""); print("" if val is None else val)' "$1"
}

seed_chat() {
  "$BIN" channel status --json >/dev/null
  sqlite3 "$DB" "INSERT OR REPLACE INTO channel_chats(chat_id,title,last_message,first_seen_at,updated_at,is_monitored,mode,priority) VALUES ('chat_test','Emergency Lee','','$NOW','$NOW',1,'self_control',10);"
}

seed_chat

# RED/GREEN 1: claimed queue rows must expire and become claimable by another worker.
item_json="$($BIN channel queue add-test --title 'Emergency Lee' --body 'lease expiry verify' --json)"
item_id="$(printf '%s' "$item_json" | json_field id)"
claim_json="$($BIN channel queue claim --worker stale-worker --lease-seconds 1 --json)"
claimed_by="$(printf '%s' "$claim_json" | json_field claimed_by)"
lease_expires_at="$(printf '%s' "$claim_json" | json_field lease_expires_at)"
[[ "$claimed_by" == "stale-worker" ]] || { echo "expected stale-worker claim, got $claimed_by" >&2; exit 1; }
[[ -n "$lease_expires_at" ]] || { echo "expected lease_expires_at on claimed row" >&2; exit 1; }
sleep 2
reclaim_json="$($BIN channel queue claim --worker fresh-worker --lease-seconds 60 --json)"
reclaimed_id="$(printf '%s' "$reclaim_json" | json_field id)"
reclaimed_by="$(printf '%s' "$reclaim_json" | json_field claimed_by)"
attempts="$(printf '%s' "$reclaim_json" | json_field attempts)"
[[ "$reclaimed_id" == "$item_id" ]] || { echo "expected stale id $item_id to be reclaimed, got $reclaimed_id" >&2; exit 1; }
[[ "$reclaimed_by" == "fresh-worker" ]] || { echo "expected fresh-worker reclaim, got $reclaimed_by" >&2; exit 1; }
[[ "$attempts" == "2" ]] || { echo "expected attempts=2 after reclaim, got $attempts" >&2; exit 1; }
if "$BIN" channel queue complete "$item_id" --worker stale-worker --json >/tmp/ktok-stale-complete.json 2>&1; then
  echo "expected stale worker complete to fail after reclaim" >&2
  exit 1
fi
if "$BIN" channel queue complete "$item_id" --json >/tmp/ktok-unowned-complete.json 2>&1; then
  echo "expected complete without worker to fail for worker-owned claim" >&2
  exit 1
fi
complete_json="$($BIN channel queue complete "$item_id" --worker fresh-worker --json)"
completed_status="$(printf '%s' "$complete_json" | json_field status)"
completed_lease="$(printf '%s' "$complete_json" | json_field lease_expires_at)"
[[ "$completed_status" == "completed" ]] || { echo "expected completed status, got $completed_status" >&2; exit 1; }
[[ -z "$completed_lease" ]] || { echo "expected completed lease_expires_at to be cleared, got $completed_lease" >&2; exit 1; }

# RED/GREEN 2: short SQLite writer contention should wait instead of failing immediately with SQLITE_BUSY.
item_json="$($BIN channel queue add-test --title 'Emergency Lee' --body 'busy timeout verify' --json)"
python3 - "$DB" <<'PY' &
import sqlite3, sys, time
con = sqlite3.connect(sys.argv[1], isolation_level=None)
con.execute('BEGIN EXCLUSIVE')
time.sleep(1.0)
con.execute('COMMIT')
con.close()
PY
locker=$!
sleep 0.15
busy_claim="$($BIN channel queue claim --worker busy-worker --lease-seconds 60 --json)"
wait "$locker"
busy_by="$(printf '%s' "$busy_claim" | json_field claimed_by)"
[[ "$busy_by" == "busy-worker" ]] || { echo "expected busy-worker claim after waiting out lock, got $busy_by" >&2; exit 1; }

echo "channel runtime hardening tests passed"