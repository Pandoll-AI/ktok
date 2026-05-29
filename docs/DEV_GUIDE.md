# ktok Shared Workspace Dev Guide

This guide is for local services that integrate with `ktok`.

`~/.ktok` is the canonical shared local workspace for ktok account state, room cache, live events, user inputs, and files. The recommended write path is the ktok CLI. Services may read returned paths directly from the filesystem.

## Workspace Root

Use `KTOK_HOME` to override the workspace root. If unset, ktok uses `~/.ktok`.

```bash
KTOK_HOME=/shared/ktok-home ktok storage paths --json
```

Do not store secrets in the workspace. Passwords and tokens belong in Keychain or another platform secret backend.

## Layout

```text
~/.ktok/
  config/
  state/current-account.json
  accounts/<alias>/
    account.json
    rooms.json
    history.sqlite
    events/yyyy-mm-dd.jsonl
    inputs/
      text/yyyy-mm-dd/<input_id>.json
      files/yyyy-mm-dd/<input_id>/original.*
      files/yyyy-mm-dd/<input_id>/metadata.json
    rooms/<chat_id>/
      events/yyyy-mm-dd.jsonl
      attachments/<attachment_id>/metadata.json
      attachments/<attachment_id>/original.*
    downloads/
    exports/
    jobs/
  cache/ax-cache.json
  logs/
```

`history.sqlite` is only the raw history DB populated by `sync-history` and `import-history`. Live events are JSONL.

## Preferred Write API

Use CLI writes first:

```bash
ktok inputs save-text --account work --source service --text "hello" --json
ktok inputs save-file --account work --source service /path/to/file.pdf --json
ktok events append --account work --type message --json-file event.json --json
ktok storage paths --account work --chat "채팅방" --json
```

Every write returns the stable paths that the service can read:

```json
{
  "ok": true,
  "id": "inp_...",
  "account_alias": "work",
  "chat_id": "chat_...",
  "path": "/Users/me/.ktok/accounts/work/inputs/text/2026-05-29/inp_....json",
  "event_path": "/Users/me/.ktok/accounts/work/rooms/chat_.../events/2026-05-29.jsonl",
  "event_paths": ["..."],
  "created_at": "2026-05-29T10:00:00.000Z"
}
```

## Event Schema

JSONL event rows use schema version 1:

```json
{
  "schema_version": 1,
  "event_id": "evt_...",
  "event_type": "message",
  "account_alias": "work",
  "account_key": "account_...",
  "chat_id": "chat_...",
  "chat_title": "채팅방",
  "source": "ktok_watch",
  "created_at": "2026-05-29T10:00:00.000Z",
  "observed_at": "2026-05-29T10:00:00.000Z",
  "payload": {},
  "paths": {}
}
```

Event types used by ktok:

| Type | Meaning |
| --- | --- |
| `message` | Live or read text message observation. |
| `system` | System/date separator row observation. |
| `attachment` | Attachment candidate observation. |
| `input_text` | User text saved through `ktok inputs`. |
| `input_file` | User file saved through `ktok inputs`. |
| `download` | Attachment download attempt/result. |

Consumers should dedupe by `event_id`.

## Input File Metadata

`inputs save-file` writes:

```json
{
  "schema_version": 1,
  "input_id": "inp_...",
  "source": "service",
  "account_alias": "work",
  "chat_id": "chat_...",
  "chat_title": "채팅방",
  "chat_resolved": true,
  "original_filename": "report.pdf",
  "stored_path": "/Users/me/.ktok/accounts/work/inputs/files/2026-05-29/inp_.../original.pdf",
  "sha256": "...",
  "size_bytes": 12345,
  "created_at": "2026-05-29T10:00:00.000Z"
}
```

## Chat Resolution

When a service passes `--chat-id`, ktok uses it directly.

When a service passes `--chat`, ktok tries to resolve it from `accounts/<alias>/rooms.json`. If not found, ktok generates a fallback `chat_<hash>` and marks `chat_resolved=false` in metadata/path output. Services that need stable room identity should run:

```bash
ktok chats --json
```

before account-scoped automation.

## Direct File Writes

Direct writes are advanced usage. If a service writes without the CLI, it must follow these rules:

- Create parent directories first.
- Write normal JSON files through temp-file plus atomic rename in the same directory.
- Append JSONL under an exclusive lock file named `.<jsonl-name>.lock`.
- Write one complete JSON object per line.
- Never rewrite JSONL event files.
- Preserve unknown fields when updating JSON metadata.
- Do not write secrets to the workspace.

The CLI already implements these rules.

## Read/Watch Recording

`ktok read` and `ktok watch` record observed messages and attachments by default:

```bash
ktok read "채팅방" --json
ktok watch "채팅방" --json
```

Disable recording for a diagnostic run:

```bash
ktok read "채팅방" --json --no-record-events
ktok watch "채팅방" --json --no-record-events
```

## Attachments

Attachment observations and downloads are stored under:

```text
accounts/<alias>/rooms/<chat_id>/attachments/<attachment_id>/
  metadata.json
  original.*
```

If `download-file --attachment-id` omits `--save-dir`, ktok uses the attachment directory as the default destination. If `--save-dir` is provided, ktok saves there and records the chosen path in metadata and events.

## SDK Policy

No language SDK is required for v1. The CLI is the stable write API, and filesystem paths are the read API.

Add a TypeScript or Python SDK only when at least two services need the same non-trivial client logic, such as lock handling, schema migrations, or typed event readers. Until then, keep the CLI contract authoritative.
