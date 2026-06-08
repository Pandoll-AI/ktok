# KakaoTalk Channel Runtime Implementation Plan

> For Hermes: implement in ktok first so future `ktok` installs include the runtime without requiring separate Hermes scripts.

Goal: Turn KakaoTalk automation into a Hermes-compatible channel runtime with separated chat access, lightweight hooks, durable queue/state, and adaptive daemon polling.

Architecture: ktok owns KakaoTalk access because it already has Accessibility permissions and chat/window resolvers. The channel runtime stores durable state in `~/.ktok/channel/channel.sqlite`, exports `~/.ktok/chat-id-map.json` for fast exact matching, and exposes `ktok channel ...` subcommands for Hermes or future gateway adapters. Hermes processing remains separate: the daemon only detects/enqueues messages and never sends replies or calls an LLM.

Tech stack: Swift Package executable, ArgumentParser, macOS Accessibility APIs, SQLite via existing `Database`, existing ktok chat list/read/send primitives.

---

## Safety and operating constraints

- Test target is only the user's self-chat: exact title `Emergency Lee`, chat_id `chat_134aa6b90437`.
- Do not test by sending messages to third parties.
- Use exact title matching only. Duplicate titles require chat_id disambiguation.
- The channel daemon detects and enqueues only; no automatic external replies.
- External sending remains explicit and should use `ktok send --chat-id ...` or future approved processor policy.

---

## Runtime split

1. Channel hook
   - `ktok channel daemon`
   - adaptive polling loop
   - detects new messages via `poll-once`

2. KakaoTalk access layer
   - existing `ktok chats`, `ktok read`, `ktok send`
   - new `ktok channel refresh-chats`, `poll-once`

3. Durable state / queue
   - `~/.ktok/channel/channel.sqlite`
   - tables: `channel_chats`, `channel_messages`, `channel_inbox_queue`, `channel_locks`

4. Hermes processor boundary
   - future worker claims `channel_inbox_queue`
   - invokes Hermes/gateway policies separately
   - replies only when explicit policy allows

---

## Implemented MVP tasks

### Task 1: Add channel state store

Files:
- Create: `Sources/ktok/Channel/ChannelStore.swift`

Behavior:
- Create channel DB under `~/.ktok/channel/channel.sqlite`.
- Migrate tables for chats, messages, queue, locks.
- Upsert chat map from `ktok chats` scan.
- Export stale-aware `~/.ktok/chat-id-map.json`.
- Resolve exact titles and reject duplicates.
- Insert transcript snapshots idempotently using SHA-256 message keys.
- Queue inbound messages; optionally queue self messages for tests.
- Compute adaptive polling interval:
  - last activity within 5 minutes: 5 seconds
  - 02:00-05:00: 15 minutes
  - Mon-Fri 08:00-15:00: 15 seconds
  - otherwise: 3 minutes

Verification:
- `swift build -c release`
- `ktok channel status --json`

### Task 2: Add `ktok channel` command tree

Files:
- Create: `Sources/ktok/Commands/ChannelCommand.swift`
- Modify: `Sources/ktok/ktok.swift`

Subcommands:
- `ktok channel refresh-chats [--force] [--ttl-seconds N] [--json]`
- `ktok channel status [--json]`
- `ktok channel monitor add --title TITLE [--mode MODE] [--priority N]`
- `ktok channel monitor remove --title TITLE`
- `ktok channel monitor list [--json]`
- `ktok channel poll-once --title TITLE [--enqueue-mine] [--json]`
- `ktok channel poll-once --all-monitored [--json]`
- `ktok channel daemon [--max-loops N] [--json]`

Verification:
- `ktok channel --help`
- `ktok channel refresh-chats --force --json`
- `ktok channel monitor add --title "Emergency Lee" --mode self_control --json`
- `ktok channel poll-once --title "Emergency Lee" --enqueue-mine --json`

### Task 3: Prepare future Hermes integration

Boundary:
- ktok provides the local channel runtime and queue.
- Hermes processor can later claim rows from `channel_inbox_queue` or a ktok wrapper command can be added:
  - `ktok channel queue claim`
  - `ktok channel queue complete`
  - `ktok channel queue fail`

Rationale:
- Keep hook/queue fast and non-LLM.
- Keep Hermes processing optional and policy-driven.
- Avoid blocking KakaoTalk polling on model latency.

---

## Next implementation phases

### Phase 2: Queue claim/complete API

Implemented in this iteration:
- `ktok channel queue list [--status pending|claimed|completed|failed] [--json]`
- `ktok channel queue claim --worker luna-kakao [--limit N] [--lease-seconds N] [--json]`
- `ktok channel queue complete ID [--worker luna-kakao] [--json]`
- `ktok channel queue fail ID [--worker luna-kakao] [--retry] [--delay-seconds N] [--json]`
- `ktok channel queue add-test --title "Emergency Lee" --body "..." --json`

`add-test` is intentionally local-only: it inserts a synthetic queue row into SQLite without sending to or reading from KakaoTalk. It exists so the queue lifecycle can be verified safely against the self-chat scope.

### Phase 2b: Polling fallback hardening

Implemented in this iteration:
- `poll-once --json` now returns a structured object with `ok`, `results`, and `errors` instead of crashing with an unstructured exception.
- `SEARCH_MISS` is reported with an operator hint: KakaoTalk did not expose a search field, but the queue/runtime state remains usable.
- Broad AX descendant traversal in `KakaoTalkApp.chatListWindow` was removed because it can block for minutes when KakaoTalk exposes a very large accessibility tree.
- Duplicate-title polling is refused before opening a room, because current KakaoTalk AX resolution is still title-based even when the operator supplied `--chat-id`.
- Channel DB privacy was hardened: `~/.ktok/channel` is set to `0700`, and `channel.sqlite`, `-wal`, and `-shm` files are set to `0600`.
- Message dedupe keys now include an occurrence index for identical `(chat_id, author, time_raw, body)` messages within a snapshot to avoid silently dropping repeated same-minute messages.
- Queue completion/failure now requires `status='claimed'`, and can optionally require `claimed_by` via `--worker`.
- SQLite connections set `PRAGMA busy_timeout = 5000`, so short writer contention between daemon and worker waits instead of immediately failing with `SQLITE_BUSY`.
- Claimed queue rows now receive `lease_expires_at`; `claim --lease-seconds N` can reclaim rows whose worker crashed or exceeded its lease.
- Added `scripts/test-channel-runtime-hardening.sh` to verify lease expiry/reclaim and busy-timeout behavior with an isolated `KTOK_HOME`.
- Room resolution now activates Chats before search by trying the `chatrooms` AX button, then the constrained `Window > Chats` menu item, then Cmd+2.
- Search root is re-selected after Chats activation because KakaoTalk may change the focused/main window reference.
- Search/window candidate scoring is normalized exact equality only; partial, contains, honorific, and Down+Enter result-opening fallbacks are disabled to avoid wrong-room targeting.
- After opening from search, `resolveOpenedChatWindow` accepts only exact-title matching windows and no longer accepts generic likely-chat-input fallback windows.

Remaining:
- KakaoTalk still sometimes fails to expose the chat-list search field through AX even after `Window > Chats`; this now fails closed with structured `SEARCH_MISS` rather than using physical/coordinate clicks.
- Prefer existing target chat windows for polling when already open.

### Phase 3: Hermes processor

Add external or Hermes plugin worker:
- reads claimed queue items
- applies chat policy
- calls Hermes only when needed
- writes response decision
- sends only with explicit allow policy

### Phase 4: launchd install

Add:
- `ktok channel install-daemon`
- writes `~/Library/LaunchAgents/ai.luna.ktok-channel.plist`
- uses installed ktok binary path
- logs to `~/.ktok/logs/channel-daemon.log`

### Phase 5: Hermes gateway adapter

When stable, promote from external runtime to Hermes gateway platform adapter:
- platform: `kakaotalk`
- incoming events from channel DB queue
- delivery via `ktok send --chat-id`

---

## Current acceptance criteria

- The ktok binary itself contains `channel` commands.
- Fresh ktok build/install brings the feature without copying separate scripts.
- All chat IDs can be refreshed and exported.
- Self-chat can be monitored and polled.
- Queue rows are durable and idempotent.
- The daemon can run one loop for test without sending messages.
