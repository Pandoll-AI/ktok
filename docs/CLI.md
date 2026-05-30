# ktok CLI Manual

`ktok` is a KakaoTalk macOS automation tool and the owner of the shared local workspace at `KTOK_HOME` or `~/.ktok`.

## Global Environment

| Name | Meaning |
| --- | --- |
| `KTOK_HOME` | Override shared workspace root. Defaults to `~/.ktok`. |
| `.env` | Optional login settings source. Prefer storing passwords in the platform secret backend. |

Commands that support `--json` emit one JSON object. Common failure codes include `ACCOUNT_UNKNOWN`, `INVALID_ARGUMENT`, `CHAT_NOT_FOUND`, `NO_FILE_FOUND`, `FILE_EXPIRED`, `DOWNLOAD_NOT_OBSERVED`, `CONFIRMATION_REQUIRED`, and `PROCESS_TIMEOUT`.

## status

```bash
ktok status
ktok status --verbose
```

Checks Accessibility, KakaoTalk process status, active account, and storage paths.

## login / logout / assume / whoami

```bash
scripts/setup-login-env.sh --alias work
ktok login work
ktok login private --env-file /path/to/.env --timeout 45
ktok login work --trust-state
ktok logout
ktok assume work
ktok whoami --json
```

`scripts/setup-login-env.sh` writes `KTOK_LOGIN_<ALIAS>_ID`, optional profile name, and keep-logged-in settings to `~/.ktok/config/.env`. It stores the password in the platform secret backend and removes `KTOK_LOGIN_<ALIAS>_PASSWORD` from the env file if present.

`login` writes account state and metadata under `~/.ktok/accounts/<alias>/`. Passwords should stay in the platform secret backend.

## chats

```bash
ktok chats
ktok chats --json
ktok chats --limit 50 --detail --keep-window
```

Refreshes `accounts/<alias>/rooms.json`. This is the authoritative room-list refresh trigger.

## read

```bash
ktok read "채팅방"
ktok read "채팅방" --limit 50 --json
ktok read "채팅방" --json --no-record-events
```

Options:

| Option | Meaning |
| --- | --- |
| `--limit`, `-l <n>` | Maximum messages. Default `20`. |
| `--debug` | Show raw extracted message info. |
| `--trace-ax` | Print Accessibility trace. |
| `--keep-window`, `-k` | Keep auto-opened chat window. |
| `--deep-recovery` | Use slower recovery if fast window resolution fails. |
| `--json` | Emit JSON. |
| `--record-events` / `--no-record-events` | Record observed messages/attachments to workspace. Default on. |

JSON shape:

```json
{
  "chat": "채팅방",
  "fetched_at": "2026-05-29T10:00:00.000Z",
  "count": 1,
  "messages": [
    {"author": "홍길동", "time_raw": "10:00", "body": "메시지"}
  ],
  "attachments": [
    {
      "attachment_id": "att_0123456789abcdef",
      "chat": "채팅방",
      "filename": "report.pdf",
      "candidate_value": "report.pdf",
      "author": "홍길동",
      "time_raw": "10:00",
      "row_index": 42,
      "reason": "extension"
    }
  ]
}
```

## watch

```bash
ktok watch "채팅방"
ktok watch "채팅방" --json
ktok watch "채팅방" --poll-interval 3 --include-system --no-record-events
```

Options:

| Option | Meaning |
| --- | --- |
| `--poll-interval <seconds>` | Poll interval, clamped to `0.2...10.0`. |
| `--trace-ax` | Print Accessibility trace. |
| `--keep-window`, `-k` | Keep auto-opened chat window after exit. |
| `--deep-recovery` | Use slower recovery. |
| `--json` | Emit each event as JSON. |
| `--include-system` | Include system rows. |
| `--record-events` / `--no-record-events` | Record emitted events to workspace. Default on. |

Message event:

```json
{"chat":"채팅방","event":"message","detected_at":"2026-05-29T10:00:03.000Z","message":{"author":"홍길동","time_raw":"10:00","body":"안녕하세요"}}
```

Attachment event:

```json
{"chat":"채팅방","event":"attachment","detected_at":"2026-05-29T10:00:03.000Z","attachment":{"attachment_id":"att_0123456789abcdef","chat":"채팅방","filename":"report.pdf","candidate_value":"report.pdf","row_index":42,"reason":"extension"}}
```

## send / send-image / send-file

```bash
ktok send "채팅방" "안녕하세요"
ktok send --chat-id chat_abc123 "안녕하세요"
ktok send-image "채팅방" /path/to/image.png
ktok send-file "채팅방" /path/to/report.pdf
```

Common options include `--trace-ax`, `--no-cache`, `--keep-window`, and `--deep-recovery`. `send-file` supports `--confirm`.

## download-file

```bash
ktok download-file "채팅방" --attachment-id att_0123456789abcdef --json
ktok download-file "채팅방" --attachment-id att_0123456789abcdef --save-dir /explicit/path --json
ktok download-file "채팅방" --filename report.pdf --save-dir /explicit/path --json
```

Options:

| Option | Meaning |
| --- | --- |
| `--attachment-id <id>` | Match candidate from `read` or `watch`. |
| `--filename <text>` | Filename substring fallback. |
| `--save-dir <path>` | Destination. If omitted with `--attachment-id`, defaults to room-scoped `rooms/<chat_id>/attachments/<attachment_id>/`. Otherwise defaults to `downloads/`. |
| `--max-scroll <n>` | Scroll-up attempts, clamped `0...30`. |
| `--stable-timeout-sec <n>` | Wait for stable download, clamped `1...300`. |
| `--json` | Emit JSON. |
| `--confirm` | Return `CONFIRMATION_REQUIRED`. |

JSON includes `attachment_id`, `candidate_value`, `downloaded_file`, `save_dir`, `watched_dirs`, `status`, and workspace event paths when recorded.

## storage

```bash
ktok storage paths --json
ktok storage paths --account work --chat "채팅방" --json
ktok storage validate --json
```

`paths` resolves root, account, input, event, room, attachment, history, download, export, and cache paths. `validate` creates and checks base workspace directories.

## events

```bash
ktok events append --account work --type message --json-file event.json --json
printf '{"body":"hello"}' | ktok events append --account work --type message --json-file - --json
```

Appends an event JSON payload to account-level JSONL and, when a chat scope is supplied, room-level JSONL.

Options:

| Option | Meaning |
| --- | --- |
| `--account <alias>` | Account alias. |
| `--chat-id <id>` | Optional chat scope. |
| `--chat <title>` | Optional chat title to resolve through `rooms.json`; fallback chat ID is generated if unresolved. |
| `--type <type>` | Event type. |
| `--source <name>` | Source name. Default `ktok_events`. |
| `--json-file <path|->` | JSON payload path or stdin. |
| `--json` | Emit JSON. |

## inputs

```bash
ktok inputs save-text --account work --source service --text "hello" --json
ktok inputs save-file --account work --source service /path/to/file.pdf --json
```

`save-text` stores `inputs/text/yyyy-mm-dd/<input_id>.json` and appends an `input_text` event.

`save-file` stores `inputs/files/yyyy-mm-dd/<input_id>/original.*`, writes `metadata.json`, and appends an `input_file` event.

Options:

| Option | Meaning |
| --- | --- |
| `--account <alias>` | Account alias. |
| `--chat-id <id>` | Optional chat scope. |
| `--chat <title>` | Optional chat title to resolve. |
| `--source <name>` | Source/caller name. |
| `--text <text>` | Text for `save-text`. |
| `<file>` | File path for `save-file`. |
| `--json` | Emit JSON. |

## sync-history / import-history / history

```bash
ktok sync-history "채팅방" --json
ktok import-history /path/to/KakaoTalkChats.csv --chat-name "채팅방" --json
ktok history "채팅방" --since 2026-05-01 --query "보고서" --json
ktok history --attachments --kind file --limit 100
```

These commands operate on `accounts/<alias>/history.sqlite`, the raw searchable history DB. It remains separate from live JSONL events.

## cache / inspect / dump-chat-ui

```bash
ktok cache status
ktok cache clear
ktok inspect --window 1 --depth 5 --all
ktok dump-chat-ui "채팅방" --json
```

Debug and maintenance commands for Accessibility state.

## mcp-server

```bash
ktok mcp-server
```

MCP tools:

| Tool | CLI equivalent |
| --- | --- |
| `ktok_read` | `ktok read --json` |
| `ktok_send` | `ktok send` |
| `ktok_send_image` | `ktok send-image` |
| `ktok_send_file` | `ktok send-file` |
| `ktok_download_file` | `ktok download-file --json` |
| `ktok_sync_history` | `ktok sync-history --json` |
| `ktok_import_history` | `ktok import-history --json` |
| `ktok_query_history` | `ktok history --json` |
| `ktok_storage_paths` | `ktok storage paths --json` |
| `ktok_inputs_save_text` | `ktok inputs save-text --json` |
| `ktok_inputs_save_file` | `ktok inputs save-file --json` |
| `ktok_events_append` | `ktok events append --json` |

`ktok watch --json` is not exposed as an MCP tool because it is a long-running stream.
