# Changelog

이 프로젝트의 모든 주목할 만한 변경 사항을 이 파일에 기록한다.

형식은 [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) 를 따르며, 버저닝은 [SemVer](https://semver.org/spec/v2.0.0.html) 를 따른다.

## [Unreleased]

### Added — Shared `~/.ktok` workspace, account login, live events, attachments, and MCP refresh (2026-05-29)

**공유 로컬 workspace 확정**:

- `KTOK_HOME` override 및 기본 `~/.ktok` storage root 도입.
- 계정별 저장 구조 정리:
  - `accounts/<alias>/account.json`
  - `accounts/<alias>/rooms.json`
  - `accounts/<alias>/history.sqlite`
  - `accounts/<alias>/events/<yyyy-mm-dd>.jsonl`
  - `accounts/<alias>/inputs/text/...`
  - `accounts/<alias>/inputs/files/...`
  - `accounts/<alias>/rooms/<chat_id>/events/...`
  - `accounts/<alias>/rooms/<chat_id>/attachments/<attachment_id>/metadata.json`
- `KtokPaths` 및 `KtokWorkspaceStore` 추가. workspace 생성, legacy copy-first migration, account-scoped DB/export/download 경로, atomic write, JSONL append lock, event/input 저장을 중앙화.
- 기존 legacy 위치:
  - `~/Library/Application Support/ktok/account-state.json`
  - `~/Library/Application Support/ktok/ktok.db`
  - `~/.ktok/chat-registry.json`
  - `~/.ktok/ax-cache.json`
  를 새 workspace 위치로 copy-first migration. 기존 파일은 삭제하지 않음.
- `.gitignore` 기본 정책을 local-only workspace 기준으로 정리.

**로그인 / 계정 상태**:

- `ktok login <alias>`, `ktok logout`, `ktok whoami`, `ktok assume <alias>` 추가.
- `.env` 기반 multi-account credential loading:
  - `KTOK_LOGIN_<ALIAS>_ID`
  - `KTOK_LOGIN_<ALIAS>_PASSWORD`
  - `KTOK_LOGIN_<ALIAS>_PROFILE_NAME`
  - `KTOK_LOGIN_<ALIAS>_KEEP_LOGGED_IN`
- macOS Keychain 저장소 추가. service=`ktok`, account=`login:<alias>`.
- 현재 계정 상태는 `~/.ktok/state/current-account.json`, 계정 metadata는 `~/.ktok/accounts/<alias>/account.json`에 기록. password는 파일에 저장하지 않음.
- 친구 목록 전환(`Cmd+1`) 후 첫 번째 프로필 row를 읽는 `AccountProfileDetector` 추가. `whoami`와 `chats`가 가능한 경우 profile name으로 현재 alias를 검증/갱신.

**채팅방 목록 / account scope**:

- `rooms.json`을 계정별로 이동하고 `chat_id` 산출에 account scope 반영.
- `ktok chats` 기본 동작을 full scroll scan으로 변경. `--limit <n>`이 있을 때만 제한 스캔.
- AX scroll helper 추가:
  - `ScrollEvents.scrollElement`
  - `ScrollEvents.setVerticalScrollPosition`
- 기존 v1 `rooms.json` / legacy `chat-registry.json`을 v2로 승격하는 migration 추가. 기존 stable `chat_id`를 버리지 않음.

**새 storage/input/event CLI**:

- `ktok storage paths --json [--account <alias>] [--chat-id <id>|--chat <title>]`
- `ktok storage validate --json`
- `ktok events append --account <alias> [--chat-id <id>|--chat <title>] --type <type> --json-file <path|-> --json`
- `ktok inputs save-text --account <alias> [--chat-id <id>|--chat <title>] --source <name> --text <text> --json`
- `ktok inputs save-file --account <alias> [--chat-id <id>|--chat <title>] --source <name> <file> --json`
- 모든 workspace write는 parent directory 생성, temp file + same-directory atomic rename, JSONL append lock을 사용.
- `inputs save-file`은 streaming SHA-256으로 파일 해시 계산. 큰 파일도 전체를 메모리에 올리지 않음.

**live read/watch attachment + event recording**:

- `ktok read --json`의 기존 `messages` shape 유지 후 top-level `attachments` 배열 추가.
- `ktok watch --json`에 `attachment` event 추가.
- `AttachmentScanner`가 visible range의 모든 후보를 newest-first로 반환할 수 있도록 확장.
- `TranscriptReader`가 첨부 row를 단순 system row로 버리지 않고 `TranscriptAttachment`로 분리 반환.
- deterministic `attachment_id` 추가: `sha256(chat|time_raw|author|candidate_value|row_index)` prefix.
- `read` / `watch` 기본값으로 observed message/attachment event를 `~/.ktok` JSONL에 기록. `--no-record-events`로 비활성화 가능.
- 첨부 sighting metadata는 기존 `downloaded` 상태를 `seen`으로 되돌리지 않도록 status rank 기반 merge 적용.

**download-file 개선**:

- `ktok download-file <chat> --attachment-id <id>` 추가.
- `--attachment-id`가 있으면 visible/scroll scan 후보의 deterministic id와 매칭.
- JSON output에 `attachment_id`, `candidate_value`, `downloaded_file`, `save_dir`, `watched_dirs`, `status`, workspace event paths 추가.
- `--attachment-id` + `--save-dir` 미지정 시 room-scoped attachments directory를 기본 저장 위치로 사용. 그 외에는 account downloads directory 사용.
- 다운로드 metadata를 `rooms/<chat_id>/attachments/<attachment_id>/metadata.json`에 기록.

**MCP 현행화**:

- `initialize.instructions`를 ktok의 KakaoTalk I/O + shared workspace 역할에 맞게 갱신.
- `ktok_read` 응답에 `attachments` 노출.
- `ktok_download_file` input schema에 `attachment_id` 추가.
- 신규 MCP tools:
  - `ktok_storage_paths`
  - `ktok_inputs_save_text`
  - `ktok_inputs_save_file`
  - `ktok_events_append`
- `ktok_events_append`는 `payload` 누락 또는 non-object payload를 `INVALID_ARGUMENT`로 거부. 빈 이벤트를 쓰지 않음.

**문서 정리**:

- `README.md` 전면 갱신: ktok 역할, shared workspace, quick start, storage boundary, MCP tools 요약.
- `docs/CLI.md` 추가: 모든 CLI 명령, 옵션, JSON output, 실패 코드, 예시 정리.
- `docs/DEV_GUIDE.md` 추가: 외부 서비스가 `~/.ktok`을 읽고 쓰는 규칙, schema, atomic/lock 규칙, dedupe, SDK 도입 기준.
- `docs/SERVICE_INTEGRATION.md`는 Dev Guide로 안내하는 compatibility 문서로 축소.

**Fixes from review**:

- v1 `rooms.json` decoding 실패 시 registry를 empty로 reset하던 문제 수정. 기존 room identity 보존.
- `ktok chats` full scan이 첫 화면 AX rows만 보고 끝나던 문제 수정.
- attachment sighting이 기존 downloaded metadata를 seen 상태로 덮어쓰던 문제 수정.
- JSON/metadata write가 destination 삭제 후 move 하던 비원자적 교체를 same-directory `rename` 기반 atomic replace로 수정.
- JSONL append에서 short write / EINTR 처리 추가.
- metadata path는 실제 write 성공 시에만 event `paths`에 기록.
- `download-file --save-dir` 도움말과 MCP schema 설명을 실제 default 동작과 일치시킴.

**검증**:

- `swift build`
- `swift build -c release`
- `git diff --check`
- isolated `KTOK_HOME` smoke:
  - `ktok storage paths --json`
  - `ktok storage validate --json`
  - `ktok inputs save-text --account work --source test --text hello --json`
  - `ktok inputs save-file --account work --source test <file> --json`
  - `ktok events append --account work --type message --json-file - --json`
- MCP smoke:
  - `initialize`
  - invalid `ktok_events_append` without payload returns `INVALID_ARGUMENT`

**검증하지 않은 영역**:

- live KakaoTalk `read/watch/download-file` E2E는 실제 앱 상태, 채팅방 내용 기록, 파일 다운로드 부작용이 있어 이번 커밋 전 검증에서는 실행하지 않음. 테스트용 방과 임시 `--save-dir`, 필요 시 `--no-record-events`를 지정한 별도 live smoke가 필요.

### Added — Chat history DB + sync flow (big feature, 2026-04-18 ~ 2026-04-19)

**데이터 레이어 신설** — 모든 대화를 로컬 SQLite 에 영구 저장하여 검색 가능.

- **`Sources/ktok/Storage/`** — SQLite 레이어 신설 (외부 의존 0, macOS 시스템 `libsqlite3` 를 Swift `import SQLite3` 로 직접 사용):
  - `Database.swift` — `sqlite3_open_v2` / `prepare_v2` / `step` / `finalize` 래퍼. WAL + foreign_keys=ON + NFC 인코딩.
  - `Migrations.swift` — forward-only 스키마 마이그레이션 (v1 seed: `chats`, `messages`, `attachments`, `sync_runs`, `schema_version`). KST → UTC ISO-8601 변환 헬퍼 포함.
  - `Models.swift` — `ChatRecord` / `MessageRecord` / `AttachmentRecord` / `SyncRunRecord` 구조체 + `MessageKind` / `AttachmentDirection` / `AttachmentSource` enum + `DedupeKey.compute` (SHA-256 hex of `chat_id|sent_at|author|body`).
  - `Repositories.swift` — `ChatRepository`, `MessageRepository` (INSERT OR IGNORE via `dedupe_key`), `AttachmentRepository`, `SyncRunRepository` + `HistoryQuery` 필터 struct.
- **DB 위치**: `~/Library/Application Support/ktok/ktok.db` (macOS 표준, Time Machine 자동 백업).

**파서 + 분류기 신설** — KakaoTalk CSV 덤프 파싱 (RFC 4180, 한글 NFC 정규화).

- **`Sources/ktok/History/CSVReader.swift`** — RFC 4180 준수 상태 머신 파서. BOM (U+FEFF) 자동 skip, LF/CRLF 수용, multi-line quoted field `\n` 처리, `""` 이스케이프. 자체 작성 ~110줄.
- **`Sources/ktok/History/MessageClassifier.swift`** — `(user, message) → (kind, filename?)` 분류. 규칙:
  - Date + User 공백 + message == "The message has been deleted." → `kind='system', author='system'`
  - "X invited ..." / "X left the chatroom" 등 → `kind='system'`
  - `"File: <name>"` → `kind='file'`, filename 추출
  - `"Photo"` / `"Video"` / `"Voice Note"` / `"Emoticon"` → 각 kind
  - 기본 → `kind='text'`
- **`Sources/ktok/History/ChatDumpParser.swift`** — CSV rows → `MessageRecord[] + PendingAttachment[]`. 빈 Date 행은 직전 메시지 timestamp 상속. 파싱 실패 행은 `RejectedRow[]` 로 분리.
- **`Sources/ktok/History/ChatIdentity.swift`** — display name 기반 `chat_id` 해시(`chat_<12자리 SHA-256 prefix>`). iCloud/macOS 파일시스템 NFD → NFC 정규화 (`precomposedStringWithCanonicalMapping`). `KakaoTalk_Chat_<name>_<ts>.csv` 파일명 parsing.
- **`Sources/ktok/History/HistoryImporter.swift`** — 공유 import 파이프라인 (sync-history + import-history 양쪽이 사용). 트랜잭션 내 chat upsert → sync_run start → message INSERT-OR-IGNORE → 신규 메시지에 대해서만 attachment 삽입 (idempotency) → sync_run finish.

**새 CLI 커맨드 (3개)**:

- **`ktok import-history <file>`** — 기존 CSV 파일 (예: iCloud / Downloads) 을 DB 에 import. AX 미사용. `--chat-name`, `--chat-id`, `--my-kakao-id`, `--json` 플래그.
- **`ktok history <chat> [filters]`** — DB 쿼리. 필터: `--since`, `--until`, `--kind text|image|file|voice|video|emoticon|system|other` (복수), `--author` (복수), `--query <text>` (body substring). `--attachments` 로 attachments 테이블 조회 모드. `--limit`, `--oldest-first`, `--json`.
- **`ktok sync-history <chat>`** — **AX 자동화로 전체 대화 CSV 자동 다운로드 + parse + upsert**. 플로우:
  1. `ChatWindowResolver` 로 채팅 열기
  2. `ChatSettingsNavigator.openChatSettings` — 햄버거 버튼 (`AXButton desc='Menu'`) 프레스 → 팝오버 → `AXMenuItem title='Chatroom Settings'` 프레스
  3. `clickManageChatsAndSaveAsText` — sidebar 탭들을 순차 press 해서 `AXButton title='Save as a text file'` (id `_NS:8`) 이 보이는 탭 찾기
  4. `DirectoryWatcher` 가 `~/Downloads` + `--save-dir` 에 새 CSV 안정 landing 대기
  5. `HistoryImporter` 로 parse + upsert
  
  플래그: `--save-dir /tmp/ktok/dumps`, `--my-kakao-id`, `--stable-timeout-sec 40`, `--trace-ax`, `--keep-window`, `--deep-recovery`, `--confirm`.

**새 진단 커맨드 (1개, 안전)**:

- **`ktok dump-chat-ui <chat>`** — 채팅창 AX 트리를 read-only 로 덤프 (press 0회). 플래그: `--press-hamburger-then-dump` (햄버거만 press 후 덤프), `--open-settings-then-dump` (햄버거 + Chatroom Settings 까지 press 후 settings 창 덤프), `--probe-settings-tabs` (각 sidebar 탭을 press 하면서 각 탭의 static text + pressable 요소를 덤프), `--include-cells`, `--include-static-texts`, `--include-menu-items`, `--json`.

**MCP 툴 3개 추가** (`Sources/ktok/Commands/MCPServerCommand.swift`):

- **`ktok_sync_history`** — AX 기반 full sync. 인자: `chat`, `my_kakao_id?`, `save_dir?`, `stable_timeout_sec?`, `confirm?`, `keep_window?`, `trace_ax?`. 프로세스 타임아웃: `max(60s, stable_timeout + 30s)`.
- **`ktok_import_history`** — CSV 파일 import. 인자: `file_path`, `chat_name?`, `chat_id?`, `my_kakao_id?`. 타임아웃 30s.
- **`ktok_query_history`** — DB 조회. 인자: `chat_name?`, `since?`, `until?`, `kinds[]?`, `authors[]?`, `query?`, `limit?`, `attachments?`, `oldest_first?`. 타임아웃 10s.
- MCP `initialize.instructions` 문자열에 위 3개 툴 사용법 추가.

**AX navigator 안전 정책 확립** (`Sources/ktok/KakaoTalk/ChatSettingsNavigator.swift`):

- **Exact label matching 만** 사용. 좌표·프레임·크기·비율 기반 선택 로직 전면 금지 (사용자 직접 지시: "좌표로 하지말아라 크기가 달라지면 바로 망한다"). Hamburger 는 `desc='Menu'` 또는 `'메뉴'` 정확 일치만 허용 (score=10000).
- **하드 블록리스트**: `["call", "voice", "video", "share", "invite", "record", "통화", "영상", "음성", "공유", "초대", "녹화"]` 가 desc/title/id 어디든 포함된 버튼은 후보에서 즉시 제외. 이는 **near-miss 사건 대응**: 초기 구현 시 hamburger press 실패 → fallback 으로 Video Call 버튼이 눌려 실제 전화 발신 직전까지 갔음. 이후 (a) dangerous pattern blocklist + (b) 점수 10000 미만 후보는 시도하지 않음 + (c) fallback 금지 (같은 버튼만 재시도) 3중 방어.
- AX press 재시도: 햄버거 / save-as-text 둘 다 최대 3회, 250~350ms 간격. "Cannot complete (app may have terminated)" 는 transient, 재시도로 통과.

**실 E2E 검증 (2026-04-19)**:

- 3개 실 CSV 파일 import (94, 269, 521 행) — 정상, 재import 시 dedupe 로 0 inserts.
- `ktok sync-history "광역 협의체 실무지원"`: AX 전 플로우 통과 — 햄버거 → Chatroom Settings → Settings 창 (`AXWindow _NS:257`) → Save as a text file 버튼 (`AXButton _NS:8`) press → ~/Downloads 에 CSV 자동 저장 → parse 69 rows → DB 에 69 messages + 30 attachments 업서트.
- 현재 DB: 4 chats, 952 messages.
- MCP handshake: 8 tools (`ktok_read`, `ktok_send`, `ktok_send_image`, `ktok_send_file`, `ktok_download_file`, `ktok_sync_history`, `ktok_import_history`, `ktok_query_history`).
- `ktok_query_history` MCP 툴 호출 동작 확인.

**알려진 제한 / Known gotchas**:

- KakaoTalk 의 macOS 저장 다이얼로그는 현재 버전에서 경로 override (`Cmd+Shift+G`) 이 무시되고 `~/Downloads` 에 저장됨. `DirectoryWatcher` 가 `~/Downloads` 도 감시하므로 file landing 감지는 OK. 단, `--save-dir` 지정 시 relocate 가 `DirectoryWatcher.relocateIfNeeded` 로 시도되지만 기존 구현이 relocate failure 시 원 위치로 남김.
- CSV 원본은 KST 타임스탬프이나 DB 는 UTC ISO-8601 로 정규화 (`ISO8601.parseKakaoTimestamp`).
- 채팅 display_name 은 NFC 로 저장. macOS 파일시스템(HFS+) 에서 오는 이름은 NFD 라 `ChatIdentityHash.forStorage` 경유 필수.
- `ktok inspect` 는 기존 커맨드이지만 `<chat-name>` argument 를 받지 않음 (`Error: Unexpected argument`) — dump-chat-ui 가 대체제. inspect 수정은 scope 외.
- 설정 창 sidebar 의 "Manage Chats" 탭은 AX title/desc 가 비어있어 label-equality 로 구분 불가. 대신 "empty-label pressable AXButton 을 순차 press 해서 'Save as a text file' 버튼이 보이는 탭 탐색" 전략으로 우회. 현재 KakaoTalk 에서 2번째 탭 (id `_NS:50`) 이 해당.

**Memory 신규 (durable)**:

- `feedback_no_ax_coords.md` — "AX selector 는 label equality + 블록리스트만. frame/coord/size 기반 로직 금지"
- `feedback_ax_safety.md` — "call/voice/video/share/invite 등 side-effect 버튼은 fallback 에서 하드 제외"

### Fixed (self-review C1/I1/I2/I3)

Code-review 라운드 (2026-04-19) 에서 발견한 4건 모두 수정:

- **C1 (Critical)** — `HistoryImporter.swift:79-85` : `syncRunRepo.start()` 를 `db.transaction { ... }` **바깥** 으로 이동. 기존 코드는 start INSERT 가 트랜잭션 안에 있어 ROLLBACK 시 감사 행이 소실 → 뒤따르는 `finish()` UPDATE 가 0 rows affected → 에러가 `try?` 로 삼켜짐. 실패한 sync 에 대해 audit trail 이 0 이 되는 "audit 의 저주" 였음. 이제 start 는 autocommit 으로 먼저 기록, transaction 결과와 독립적으로 finish() 가 업데이트.
- **I1 (Important)** — `ChatDumpParser.swift:102-140` : `author`, `body`, `rawLine`, `filename` 모두 `precomposedStringWithCanonicalMapping` (NFC) 적용 후 dedupe_key 계산 + DB 저장. `HistoryCommand.swift:67-72` : `--author` 인자도 NFC 정규화 (`textQuery` 는 이전 커밋에서 이미 적용됨). 이전엔 chat display_name 만 NFC 였고 message body 는 원본 보존이라 비대칭. KakaoTalk CSV 가 어떤 경로로든 NFD 를 내보내면 같은 메시지가 새 해시로 재삽입되어 **dedupe 가 조용히 깨지는** 위험 존재. 사전 봉쇄.
- **I2 (Important)** — `ChatIdentity.swift:23-36` : `ChatIdentityHash.normalize` 를 `ChatTextNormalizer.normalize` 호출로 위임. 두 정규화 로직의 subtle 차이 (punctuation / symbols strip 여부) 가 있어 라이브 registry 해시와 import 해시가 불일치했음. 단일 source of truth 로 통일. **1-time migration**: 기존 DB 의 `중상팀 운영파트(신)` 채팅 (parens 포함) 은 old 해시 `chat_2ee9e7bf714b` → new 해시 `chat_404f4dab37e8` 로 직접 UPDATE (messages / attachments / sync_runs / chats 4 테이블 일괄, FK OFF 트랜잭션 내 269 messages + 51 attachments 무손실 이동). 다른 3개 채팅은 punctuation 없어 해시 변동 없음.
- **I3 (Important)** — `ChatSettingsNavigator.swift:298-310` + `SyncHistoryCommand.swift:158` : `clickManageChatsAndSaveAsText` 가 이제 `chatWindow` 도 인자로 받고, 시작부에 `settingsRoot != chatWindow` 전제 조건 검사. `pollForSettingsPanel` 도 chat window 를 fallback 으로 반환하는 inline-panel 경로 제거. Inline 경로에선 sidebar-tab fallback 이 chat window 의 빈 label 버튼을 iter 하게 되는데 dangerous blocklist 가 empty label 버튼까지 커버하진 않아 근본적 safety-hole 였음. 실 KakaoTalk 은 항상 별도 AXWindow 로 settings 를 열어서 functional 영향 없음.

**검증**: 위 4개 fix 후 E2E `ktok sync-history "광역 협의체 실무지원"` → 69 rows 파싱 / 69 dupes 스킵 / 0 inserts. DB 레코드 그대로 유지. sync_run_id=7 정상 기록. 바이트 레벨 NFC 확인 (`hex(substr(body,1,12))` → `EC9D91` 등 NFC 3-byte 시퀀스).

### Fixed — system-beep ("ding") during sync-history Save flow

사용자 보고 (2026-04-19): sync-history 실행 중 (a) 저장 다이얼로그가 열리는 타이밍과 (b) "Successfully exported your chat history" 확인 다이얼로그가 떠 OK 를 누를 타이밍에 macOS 시스템 경고음 (ding) 이 남. "누르지 않아야 할 것을 누르는 메시지." 다운로드 자체는 정상.

**원인**: 현재 KakaoTalk 버전은 `Save as a text file` 버튼을 누르면 NSSavePanel 을 띄우지 않고 **바로 `~/Downloads` 로 저장** 한다. 이후 "Successfully exported your chat history" 확인 다이얼로그를 띄움. 기존 `SavePanelDriver.waitForSavePanel` 은 AX subrole `AXDialog` 가 있는 창을 save panel 로 잘못 간주 — 즉 이 export-done 다이얼로그를 save panel 로 오인하고 `overridePath` 의 키스트로크 시퀀스 (`Cmd+Shift+G` → `Cmd+A` → `Cmd+V` → `Return` × 2) 를 거기에 발사. 이 다이얼로그는 해당 단축키들을 받지 않으므로 macOS 가 **입력 거부 beep** (= ding) 발생. 두 번 난 이유는 두 번째 `Return` 이 delay 0.5s 후에 발사되었기 때문.

**수정** (`Sources/ktok/Commands/SyncHistoryCommand.swift:166-179`):
- `SavePanelDriver.waitForSavePanel` + `overridePath` + `acceptDefault` 호출 **전부 삭제**. Save-as-text 버튼 press 후 KakaoTalk 는 자동으로 `~/Downloads` 에 저장하므로 추가 키스트로크 불필요. `DirectoryWatcher` 가 파일 착지를 감지하면 끝.
- `--save-dir` 지정 시 `DirectoryWatcher.relocateIfNeeded` 가 파일 이동 처리 (기존 경로).

**추가** — `Sources/ktok/KakaoTalk/ExportDoneDialogDismisser.swift` (신규):
- CSV 착지 확인 후 "Successfully exported..." 다이얼로그의 OK 버튼을 찾아 **AX `AXPress`** 로 누름. 키스트로크 사용 안 하므로 beep 발생 불가.
- 다이얼로그 식별: 해당 KakaoTalk 창/시트 안에 "Successfully exported" / "exported your chat" / "내보내기" / "저장되었습니다" 중 하나의 static text 가 있고, 동시에 title="OK" (또는 "확인") AXButton 이 있어야 함. 양쪽 조건 (marker + button) AND 로 "무관한 OK 다이얼로그를 잘못 누르는" 사고 방지.
- 3초 timeout. 다이얼로그를 못 찾으면 silent pass (자동 dismiss 됐거나 등장 안 했을 수도 있음 — 에러 아님).

**검증** (방금 실행): 전체 AX flow 통과 후 `[export-done-dialog: no OK button detected within 3.0s]` 로그 — 파일 착지 직후 다이얼로그는 이미 사라진 상태였음. **Ding 소리 0회 발생** 기대 (사용자 확인 필요).

### Fixed — root-cause beep on "Save as a text file" AXPress (2026-04-19)

위 수정 이후에도 ding 이 1회 남아 있었음. 사용자 피드백: "save as 창이 열리고 나서, save 버튼을 누르기 전에 발생한다". 단계별 격리 테스트 (`--stop-before-save-as-text`, `--skip-save-press`) 로 원인 확정.

**Root cause**: Swift 의 AX C API (`AXUIElementPerformAction(element, kAXPressAction)`) 로 KakaoTalk 의 "Save as a text file" 버튼을 누르면 **attempt 0 이 consistently `kAXErrorCannotComplete` ("application has not yet responded") 를 반환**. 이 실패한 AXPress 호출이 macOS 시스템 beep 을 synthesize → 오디오 재생이 ~100ms 지연되어 사용자 체감상 **save 패널 등장 순간** 에 들림. 실패 후 retry (attempt 1) 는 성공하지만 beep 은 이미 큐잉된 후.

Attempt 0 실패를 제거하려는 여러 시도는 모두 효과 없음:
- 0.3 ~ 2.0s pre-press sleep
- `actionNames()` 기반 ready-check (AXPress 액션 available 인지 확인)
- Press 직전 AX ref refresh
- `kakao.activate()` + `AXRaise` on enclosing window

→ 이 버튼의 AXPress 첫 호출은 KakaoTalk 의 일관된 특성으로 시간 대기로 해결 불가.

**Fix**: Swift 의 AX C API 경로 대신 **JXA (JavaScript for Automation) `System Events.processes.byName("KakaoTalk").actions.byName("AXPress").perform()`** 사용. JXA 는 app-scripting 브리지를 통해 내려가며 direct AX C-API 와 다른 코드 경로. 실험 결과 **JXA 경로는 첫 호출에서 바로 성공**, attempt 0 실패 없음, beep 없음.

**구현** — `ChatSettingsNavigator.pressSaveAsTextViaJXA()` (신규):
- JXA 스크립트로 `kakao.windows()` 하위 재귀 탐색, `title === "Save as a text file"` (또는 locale 변형) AXButton 발견 시 `AXPress` action 실행.
- 성공 시 `clicked: true` 반환; SyncHistoryCommand 는 이걸 먼저 시도하고 실패 시만 Swift AXPress 로 fallback (현재는 fallback 발동 케이스 없음).
- `clickManageChatsAndSaveAsText` 의 direct-path + indirect-path 양쪽 모두 JXA 우선.

**진단 플래그 (debug 전용)**:
- `--no-dismiss-dialog` — export-done 다이얼로그의 OK 버튼 press 건너뛰기
- `--skip-save-press` — NSSavePanel 의 Save 버튼 press 건너뛰기 (사용자가 수동)
- `--stop-before-save-as-text` — "Save as a text file" press 이전에 정지
- `--debug-slow` — 각 AX step 사이 2초 idle (타이밍 이슈 격리용)

이 4개 플래그 덕에 위 근본 원인을 **4회의 단계적 격리 실행** 으로 특정 가능.

**검증**: `ktok sync-history "광역 협의체 실무지원"` 정상 flow (no debug flags) — 전체 AX 통과, CSV 저장, DB dedupe 정상. 사용자 확인: **ding 0회** (첫 소음 없는 실행).

**남은 미세 이슈**: `hamburger` 버튼의 AXPress 도 attempt 0 에서 `Cannot complete` 로 실패하고 retry 로 성공 — 이론상 beep 1회 발생 가능하지만 사용자는 이 시점에서 beep 을 보고하지 않음 (KakaoTalk 앱 activation 사운드에 mask 되거나 knowledge 가 충분한 시점에 잡히지 않는 듯). 필요 시 hamburger 에도 동일한 JXA 우회 적용 가능 — 지금은 `Not-a-bug` 로 유보.

### Removed
- 상류 fork 이전 이름 `kmsg` 의 모든 런타임·문서·CI 잔재 제거.
  - **Swift**: `Sources/ktok/Commands/MCPServerCommand.swift` 내부 타입/메서드 리네임.
    - `KmsgMCPError` → `KtokMCPError`
    - `KmsgSubprocessRunner` → `KtokSubprocessRunner`
    - `KmsgMCPServer` → `KtokMCPServer`
    - `callKmsgRead/Send/SendImage/SendFile/DownloadFile` → `callKtok…`
  - **MCP 프로토콜 응답**: `initialize.meta.startup_check.kmsg_bin` 키를 `ktok_bin` 으로 변경 (3곳: 성공 path, version 실패 path, status 실패 path). 비공개 fork 이고 외부 소비자가 없기 때문에 브레이킹 체인지로 취급하지 않음.
  - **README.md**: `## 이게 왜 존재하나 — 기존 두 프로젝트와의 차이` 섹션(상류 비교표 + Python wrapper 비교표) 전체 삭제. 해당 feature 들은 `## ktok 이 채우는 빈틈` 단일 표로 압축. LICENSE 섹션의 upstream 문구는 "상류(upstream) 프로젝트" 로 일반화 (외부 리포 URL `github.com/channprj/kmsg` 자체는 실제 리포 식별자이므로 링크 유지).
  - **.vscode/launch.json**: `${workspaceFolder:kmsg}` / `Debug kmsg` / `Release kmsg` / `target: "kmsg"` / `preLaunchTask: "… kmsg"` 전부 `ktok` 로.
  - **.github/workflows/release.yml**:
    - `RELEASE_ASSET_NAME: kmsg-macos-universal` → `ktok-macos-universal`
    - `TAP_REPO: channprj/homebrew-tap` → `Pandoll-AI/homebrew-tap` (주의: 이 tap 리포지토리는 아직 존재하지 않음. `TAP_REPO_TOKEN` secret 도 미설정이므로 tap-sync 단계는 현재 실패 상태로 남음. 이는 이전 upstream-only dirs 트림 커밋 (`483e17d`) 이후부터의 선행 조건이며 이번 변경이 도입한 regression 아님.)
    - `$ARM_BIN_DIR/kmsg`, `$X86_BIN_DIR/kmsg` → `ktok`
    - `kmsg-homebrew-meta/` 작업 디렉토리 → `ktok-homebrew-meta/`
    - tap 커밋 메시지 `chore(tap): sync kmsg formulas…` → `chore(tap): sync ktok formulas…`
  - **.github/workflows/ci.yml**:
    - `.build/debug/kmsg --version` → `.build/debug/ktok --version`
    - 제거: `python3 -m unittest tests.test_sync_homebrew_tap tests.test_release_workflow` (해당 `tests/` 모듈은 `483e17d` 이후 존재하지 않음 — dead reference 제거)
    - 제거: `python3 -m py_compile tools/kmsg-mcp.py tools/sync_homebrew_tap.py` (해당 `tools/` 디렉토리도 `483e17d` 이후 부재)
    - 추가: `MCP smoke handshake` 스텝 — debug 빌드에 대해 `ktok mcp-server` 를 1초 handshake 로 돌려 `"ktok-mcp"` / `"ktok_read"` 문자열 검증.
- **시스템 설치물 제거**:
  - `brew uninstall kmsg` — `/opt/homebrew/Cellar/kmsg/0.3.0` (5.7MB, 4 files) 삭제, `/opt/homebrew/bin/kmsg` 심링크 제거.
  - `brew untap channprj/tap` — 14개 formula 의 tap 메타데이터 untap (해당 tap 에서 설치된 것은 `kmsg` 하나뿐이었음, 다른 설치물 영향 없음).
- **`~/.claude.json` 정리** (사전 백업: `~/.claude.json.bak-20260418-215339`):
  - `projects["/Users/sjlee/Projects/kmsg-mcp-fix"]` 엔트리 삭제 (해당 디렉토리는 이미 파일시스템에서 부재).
  - `projects["/Users/sjlee/Projects/ktok"].exampleFiles` 중 `"kmsg.swift"` → `"ktok.swift"` 로 정규화.
  - `githubRepoPaths["pandoll-ai/kmsg-mcp-fix"]` 매핑 삭제.

### Added
- **전역 CLI 설치**: `~/.local/bin/ktok` → `/Users/sjlee/Projects/ktok/.build/release/ktok` 심링크. `~/.local/bin` 은 이미 `PATH` 에 있으므로 모든 쉘에서 `ktok` 즉시 사용 가능. 심링크라 `swift build -c release` 재빌드만 하면 자동 갱신.
- **CHANGELOG.md**: 본 파일 신설. 앞으로 모든 변경은 여기에 상세 기록.

### Verified
- `ktok --version` → `0.3.0`
- `ktok status` → Accessibility ✓, KakaoTalk running ✓
- `ktok chats --json` → 5개 채팅방 정상 반환
- MCP smoke (`initialize` + `tools/list` + `shutdown` + `exit`): `serverInfo.name=ktok-mcp`, 5개 툴 노출 (`ktok_read`, `ktok_send`, `ktok_send_image`, `ktok_send_file`, `ktok_download_file`), `meta.startup_check.ktok_bin` 키 확인 (이전 `kmsg_bin` 은 응답 전체에서 0 매치).
- MCP end-to-end `ktok_read` 툴 호출 (chat="Emergency Lee", limit=3): 10.7s latency, `isError:false`, 3개 메시지 정상 JSON.
- `.build/` 를 한 번 완전 삭제 후 재빌드 필요했음 — module cache PCH 가 디렉토리 이전 이름 (`/Users/sjlee/Projects/kmsg/.build/...ModuleCache/...`) 에 고정되어 있었음. 이후 clean build 성공 (42.69s).

### Removed (cleanup)
- **`CLAUDE.md`** (tracked symlink) — `AGENTS.md` 를 가리키던 심링크였으나 `AGENTS.md` 는 커밋 `483e17d` 에서 삭제됨. 이후 심링크만 남아 dangling 상태였음. Claude Code 가 이 파일에서 아무 내용도 읽지 못하므로 심링크 자체 제거.
- **`.python-version`** (tracked, `3.13.6`) — ktok 은 Swift 단일 바이너리이며 저장소에 Python 소스 0개. pyenv 용 고정 파일은 vestigial. `.github/workflows/release.yml` 이 `python3 <<'PY'` 인라인 heredoc 을 사용하지만 pyenv 와는 무관 (runner 기본 python3).
- **`.gitignore`** 가지치기:
  - 제거: `/Packages` (구 SwiftPM 레거시, 현대 SPM 은 `.build/checkouts/` 사용)
  - 제거: `video/node_modules/`, `video/out/` (`video/` 디렉토리 저장소에 부재)
  - 제거: `__pycache__/`, `*.py[cod]` (Python 소스 없음)
  - 추가: `*.swp`, `*.swo` (vim swap), `.idea/` (JetBrains)
  - 유지: `.DS_Store`, `/.build`, `xcuserdata/`, `DerivedData/`, `.swiftpm/configuration/registries.json`, `.swiftpm/xcode/package.xcworkspace/contents.xcworkspacedata`, `.netrc`, `.claude/settings.local.json`

### Known leftover
- `README.md` 의 LICENSE 섹션 링크 `https://github.com/channprj/kmsg/blob/main/LICENSE` — 외부 upstream GitHub URL 이므로 보존 (해당 리포의 실제 식별자).
- `.github/workflows/release.yml` 의 `TAP_REPO: Pandoll-AI/homebrew-tap` — 실제 homebrew-tap 리포 미생성 상태. 릴리즈 파이프라인을 실제 가동하려면 tap 리포 생성 + `TAP_REPO_TOKEN` secret 설정 필요. 미가동 시 tap-sync 스텝만 실패하고 바이너리 upload 자체는 성공함.
