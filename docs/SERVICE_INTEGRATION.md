# Service Integration

`ktok` now treats `KTOK_HOME` / `~/.ktok` as the shared local workspace for ktok and other local services.

Use [DEV_GUIDE.md](DEV_GUIDE.md) as the authoritative integration guide. The previous guidance to keep service events, user inputs, summaries, and files outside `~/.ktok` has been superseded.

Recommended v1 pattern:

```bash
ktok storage paths --account work --chat "채팅방" --json
ktok inputs save-text --account work --source service --text "hello" --json
ktok inputs save-file --account work --source service /path/to/file.pdf --json
ktok events append --account work --type message --json-file event.json --json
ktok read "채팅방" --json
ktok watch "채팅방" --json
```

Services should write through ktok CLI commands first, then read the paths returned in JSON output. A separate language SDK is intentionally deferred until multiple services need the same client-side logic.
