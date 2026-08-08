# Backlog

## Reactivate the legacy monitor after the DB reader migration

- **Status:** inactive by design
- **Current behavior:** `ktok monitor` fails closed before opening KakaoTalk or sending anything.
- **Reason:** the legacy monitor reads the transcript through macOS Accessibility APIs and was too slow for the intended use.
- **Prerequisite:** replace the `kakaotalk-db` Python/SQLCipher reader with a Swift-native implementation.
- **Reactivation scope:** restore incremental per-room reads, `logId`-equivalent watermarks, reply decision flow, dry-run/JSON diagnostics, restart recovery, and safe send-room verification.
- **Acceptance conditions:** no backlog replay, no duplicate replies, no room-ID/title mismatch, correct recovery after KakaoTalk or Mac restart, and project-native tests covering empty/media/reply/system messages.
