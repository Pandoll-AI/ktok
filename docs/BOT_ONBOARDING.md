# Bot Operations Onboarding

This runbook is for humans and LLM agents operating `ktok bot` on a macOS
machine. Keep it generic: do not commit real account IDs, room titles, persona
content, logs, SQLite databases, exported config archives, or local paths that
identify a user.

## What Must Exist

- KakaoTalk is installed, running, and logged in.
- `ktok status` reports Accessibility permission granted.
- A login alias is active:

  ```bash
  ktok whoami --json
  ktok assume <alias>
  ```

- A persona config exists outside the repo:

  ```bash
  ktok persona validate --name <persona>
  ktok persona path --name <persona>
  ```

- The target room is allowlisted:

  ```bash
  ktok channel monitor add --title "<room-title>"
  ktok channel monitor list
  ```

- The Codex CLI can run in the same environment used by the bot.

## Codex CLI Requirements

`ktok bot` generates replies by launching `codex exec`. The executable is found
in this order:

1. `KTOK_CODEX_PATH`
2. `PATH`
3. Common fallback locations, including `~/.local/bin/codex`

Smoke test the same model and reasoning effort before enabling sends:

```bash
tmp="$(mktemp)"
printf 'Reply with exactly: OK\n' | \
  codex exec \
    --skip-git-repo-check \
    --ephemeral \
    --ignore-user-config \
    --ignore-rules \
    --sandbox read-only \
    --color never \
    -m gpt-5.4-mini \
    -c 'model_reasoning_effort="low"' \
    -o "$tmp" -
cat "$tmp"
rm -f "$tmp"
```

Expected output file content:

```text
OK
```

If this fails, fix Codex authentication, the executable path, or the model name
before debugging KakaoTalk or the bot database.

## LaunchAgent Setup

Use `ktok bot install-daemon` for a persistent macOS LaunchAgent:

```bash
ktok bot install-daemon \
  --persona <persona> \
  --trigger-mode greeting \
  --model gpt-5.4-mini \
  --reasoning-effort low \
  --reply-timeout 12 \
  --loop-delay 0.5 \
  --poll-interval 0 \
  --label com.example.ktok.bot \
  --load
```

The generated LaunchAgent sets `HOME`, `USER`, `PATH`, and
`KTOK_NO_ACCESSIBILITY_PROMPT`. If `codex` is installed outside the generated
`PATH`, add `KTOK_CODEX_PATH` to the plist or install a stable symlink in a
directory on `PATH`.

Inspect or stop the service:

```bash
launchctl print gui/$(id -u)/com.example.ktok.bot
launchctl bootout gui/$(id -u) ~/Library/LaunchAgents/com.example.ktok.bot.plist
```

## Trigger Modes

| Mode | Meaning |
| --- | --- |
| `persona` | Persona decision function handles direct calls, greetings, empathy, questions, and configured vocabulary. |
| `mention` | Reply only to direct persona calls/mentions. |
| `greeting` | Reply only to direct calls/mentions and configured greetings. |
| `all` | Reply to every new inbound message, excluding self and sent-body echoes. |
| `off` | Detect only; never reply. |

Use `greeting` when a room should only answer lightweight greetings or direct
calls. Use `mention` when even greetings should be ignored unless the persona is
explicitly called.

## Validation Checklist

Run these before deciding the database or permissions are corrupt:

```bash
ktok status
ktok whoami --json
ktok persona validate --name <persona>
ktok channel monitor list
ktok read "<room-title>" --limit 5 --json --keep-window
```

Then verify bot logs:

```bash
tail -n 80 ~/.ktok/bot/logs/bot.out.log
tail -n 80 ~/.ktok/bot/logs/bot.err.log
```

Healthy bot startup looks like:

```json
{"event":"started","persona":"<persona>","room_count":"1","trigger_mode":"greeting"}
```

On a generated reply, `reply_ready` includes `source`:

```json
{"event":"reply_ready","source":"codex","reason":"direct-call","room":"<room-title>"}
```

If `source` is `fallback`, the bot detected a valid trigger but Codex generation
failed or returned `SKIP`/empty output.

## State and Database Checks

Bot seen/reply state lives in the active account database:

```text
~/.ktok/accounts/<alias>/history.sqlite
```

Useful diagnostics:

```bash
sqlite3 ~/.ktok/accounts/<alias>/history.sqlite \
  "select author,time_raw,body,first_seen_at from monitor_seen order by first_seen_at desc limit 20;"

sqlite3 ~/.ktok/accounts/<alias>/history.sqlite \
  "select status,error,substr(reply_body,1,120),sent_at from monitor_replies order by sent_at desc limit 20;"
```

Do not commit this database or paste private rows into public issues.

## Troubleshooting

### Bot detects messages but sends fallback

Check Codex first:

- `command -v codex`
- `KTOK_CODEX_PATH` if a non-standard path is needed
- Codex smoke test output
- model name and `--reasoning-effort`
- `reply_ready.source` in bot logs

### LaunchAgent exits after replacing the binary

macOS Accessibility permission is tied to the executable identity. Rebuilding
and copying a new binary can change the code hash, causing TCC to require manual
approval again. Re-enable the installed `ktok` binary in:

```text
System Settings > Privacy & Security > Accessibility
```

Then restart the LaunchAgent.

### `read_failed` or `noMessageRows`

Try:

```bash
ktok cache clear
ktok read "<room-title>" --trace-ax --keep-window
```

If trace shows the wrong input field or wrong window, inspect the target window:

```bash
ktok inspect --window <index> --show-frame --row-summary
```

### The bot ignores a message

Check the skip reason in JSONL logs:

- `self` / `sent-body`: self echo protection.
- `not-greeting-or-mention`: message did not match the selected trigger mode.
- no event: message was part of the initial baseline or already recorded in
  `monitor_seen`.

## Privacy Rules for Agents

- Never commit `~/.ktok`, persona configs, exported `.tgz` archives, logs,
  SQLite databases, `.env`, Keychain material, screenshots, or real room names.
- Use placeholders like `<alias>`, `<room-title>`, and `<persona>` in docs.
- When reporting diagnostics, summarize state and error classes rather than
  copying private message bodies.
