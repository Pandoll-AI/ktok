# Changelog

이 프로젝트의 모든 주목할 만한 변경 사항을 이 파일에 기록한다.

형식은 [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) 를 따르며, 버저닝은 [SemVer](https://semver.org/spec/v2.0.0.html) 를 따른다.

## [Unreleased]

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
