# ktok — 카카오톡 macOS 자동화 CLI + MCP 서버 + 대화 DB

> 개인용 private fork. macOS Accessibility API 로 카카오톡 데스크톱을 조작하는 **단일 Swift 바이너리**. CLI + 내장 MCP 서버 + 영구 SQLite 대화 저장소가 모두 한 실행파일에 들어 있음.

---

## 무엇을 하는가

한 바이너리(`ktok`) 에 네 가지 역할이 합쳐져 있음:

1. **CLI** — `ktok send`, `ktok read`, `ktok send-file`, `ktok download-file`, `ktok watch`, `ktok chats`, `ktok sync-history`, `ktok history`, `ktok import-history`, `ktok dump-chat-ui` …
2. **내장 MCP 서버** — `ktok mcp-server` 서브커맨드 한 번으로 Claude Code 용 stdio MCP 서버가 기동. **8개 툴** 노출.
3. **영구 대화 DB** — `~/Library/Application Support/ktok/ktok.db` 의 SQLite 에 메시지 + 첨부파일 + sync 이력을 저장. KakaoTalk 의 "Save as a text file" export 를 AX 로 자동화해서 덤프한 뒤 파싱 · 업서트. SHA-256 dedupe 로 중복 없이 누적.
4. **저수준 자동화** — macOS Accessibility / Quartz CGEvent / NSPasteboard / AppleScript · JXA 를 직접 호출. 비공식 API 크롤링 없음.

지원 OS: **macOS 13+**. 카카오톡 데스크톱 앱 필수.

---

## ktok 이 채우는 빈틈

| 항목 | ktok |
|---|---|
| `send-file` (임의 파일 첨부 전송) | ✅ |
| `download-file` (첨부 다운로드 + 자동 스크롤 + Save 패널 driver) | ✅ |
| **`sync-history`** (전체 대화 자동 export + DB 적재) | ✅ |
| **`history`** (로컬 DB 검색 — 날짜 / kind / author / 본문 substring) | ✅ |
| MCP 프레이밍 | **auto-detect** (LSP Content-Length + newline-delimited) |
| Claude Code MCP 호환 | ✅ |
| 채팅 검색 시 탭 활성화 | ✅ (`chatrooms` 탭 강제 활성화) |
| `read` 툴 timeout | 20s / 40s (deep) |
| `initialize.meta.startup_check` | ✅ (`ktok_bin` 경로 + version) |
| 프로세스 모델 | 단일 Swift 바이너리. in-process CGEvent / NSPasteboard |
| 파일 전송 프로세스 hop | NSPasteboard `writeObjects` + `setPropertyList` 1회 |
| 대화 저장소 | SQLite 단일 파일 (`~/Library/Application Support/ktok/ktok.db`), WAL + foreign_keys |
| Dedupe | SHA-256(chat_id \| sent_at \| author \| body) — 재sync 0 inserts |
| NFC 정규화 | 채팅명 / author / body / 쿼리 모두 NFC 강제 (macOS 파일시스템 NFD → DB NFC 비대칭 제거) |
| AX safety | 위험 버튼 (call/voice/video/share/invite) 하드 블록리스트 + 정확 라벨 매칭 전용 |
| 의존성 | swift-argument-parser 1개. 외부 DB 바인딩 없음 (macOS libsqlite3 직접 호출) |

---

## 디렉토리 구조

```
Sources/
├── VersionGenTool/          # build-time: VERSION 파일 → Swift literal
└── ktok/
    ├── ktok.swift           # @main, 전체 서브커맨드 레지스트리 (15개)
    ├── Accessibility/       # AX API 래퍼
    │   ├── UIElement.swift        # AXUIElement 추상화 (findAll, press, attribute)
    │   ├── AXActionRunner.swift   # 재시도/검증/키 이벤트 (Cmd+V, Enter 등)
    │   ├── AXPathCache.swift      # 자주 쓰는 AX path 디스크 캐싱
    │   ├── AXConstants.swift
    │   ├── AXError+Extension.swift
    │   └── AccessibilityPermission.swift
    ├── KakaoTalk/           # 앱 인스턴스 + 채팅방 탐색 + 설정 네비게이션
    │   ├── KakaoTalkApp.swift          # 앱 launch / activate / 창 목록
    │   ├── ChatWindowResolver.swift    # 채팅방 찾고 검색창에 쿼리 투입
    │   ├── ChatListScanner.swift       # 채팅 목록 스캔 + ChatTextNormalizer
    │   ├── ChatIdentityRegistry.swift  # chat_id ↔ displayName 매핑 (라이브 AX)
    │   ├── ChatSettingsNavigator.swift # 햄버거 → Settings → Manage Chats → Save-as-text
    │   ├── TranscriptReader.swift      # 메시지 리더
    │   ├── MessageContextResolver.swift
    │   └── KakaoTalkWindowBounds.swift
    ├── Storage/             # SQLite 레이어 (외부 의존 0)
    │   ├── Database.swift          # sqlite3 C API 래퍼 (open/prepare/step, WAL)
    │   ├── Migrations.swift        # forward-only 스키마 + schema_version 테이블
    │   ├── Models.swift            # ChatRecord/MessageRecord/AttachmentRecord 등 + DedupeKey
    │   └── Repositories.swift      # CRUD + HistoryQuery 필터
    ├── History/             # CSV 파서 + dump 파이프라인
    │   ├── CSVReader.swift         # RFC 4180 state machine (BOM + multi-line quoted)
    │   ├── MessageClassifier.swift # kind 분류 (text/image/file/voice/system …)
    │   ├── ChatDumpParser.swift    # CSV rows → MessageRecord/PendingAttachment (NFC)
    │   ├── ChatIdentity.swift      # chat_id 해시 + 파일명 파싱
    │   └── HistoryImporter.swift   # 공유 import 파이프라인 (transaction + sync_runs)
    ├── Commands/            # 서브커맨드 하나당 파일 하나 (15개)
    │   ├── StatusCommand.swift, ChatsCommand.swift, InspectCommand.swift, CacheCommand.swift
    │   ├── SendCommand.swift, SendImageCommand.swift, SendFileCommand.swift
    │   ├── ReadCommand.swift, WatchCommand.swift
    │   ├── DownloadFileCommand.swift   # 첨부 다운로드 오케스트레이터
    │   ├── SyncHistoryCommand.swift    # AX 기반 전체 대화 export + DB 적재
    │   ├── ImportHistoryCommand.swift  # 기존 CSV 파일 → DB (AX 미사용)
    │   ├── HistoryCommand.swift        # DB 쿼리 / 필터
    │   ├── DumpChatUICommand.swift     # read-only AX 트리 덤프 (디버그)
    │   └── MCPServerCommand.swift      # 내장 MCP 서버 (JSON-RPC stdio, 8 툴)
    ├── Download/            # download-file 전용 헬퍼
    │   ├── AttachmentScanner.swift    # 배치 AppleScript 로 전 row 스캔
    │   ├── FileExtensionMatcher.swift # 60+ 확장자 regex + 저장 마커
    │   ├── SavePressor.swift          # row-index JXA 로 Save 버튼 press
    │   ├── DialogHandler.swift        # friend / expired dialog 분류
    │   ├── SavePanelDriver.swift      # Save 패널 대기 + AX/keystroke 헬퍼
    │   └── DirectoryWatcher.swift     # mtime/size stable wait + relocate
    └── System/              # macOS 프리미티브 (다른 레이어가 공유)
        ├── AppleScriptRunner.swift    # osascript / JXA + argv + timeout
        ├── PasteboardWriter.swift     # NSPasteboard + NSFilenamesPboardType
        ├── MouseEvents.swift          # CGEvent 이동 (scroll 라우팅용)
        └── ScrollEvents.swift         # CGEvent scrollWheelEvent2 (70%/55% 위치)
Plugins/
└── VersionGenPlugin/        # Package.swift 에서 `.plugins:[.plugin(...)]` 로 호출
```

### 레이어링

```
사용자 (CLI 또는 MCP 클라이언트)
            ↓
Commands/*.swift  (ParsableCommand)
            ↓
      ┌─────┴───────────────────────┐
  Download/                     History/ + Storage/
  (download-file 오케스트레이션)    (CSV 파서 + SQLite DB)
      └─────┬───────────────────────┘
            ↓
KakaoTalk/  (ChatWindowResolver → 창/탭/검색, ChatSettingsNavigator)
            ↓
Accessibility/  (UIElement, AXActionRunner — AX API 래퍼)
            ↓
System/  (NSPasteboard, CGEvent, osascript/JXA)
            ↓
macOS AX API / Quartz / AppKit / libsqlite3
```

---

## MCP 툴 표면

Claude Code 에서 노출되는 8개 툴 (`mcp__<server-key>__ktok_*`):

### 액션 / 실시간

| 툴 | 역할 | 주요 파라미터 |
|---|---|---|
| `ktok_read` | 채팅 최근 메시지 읽기 (JSON) | `chat`, `limit` |
| `ktok_send` | 텍스트 메시지 전송 | `chat`, `message`, `confirm` |
| `ktok_send_image` | 이미지 첨부 전송 | `chat`, `image_path`, `confirm` |
| `ktok_send_file` | 임의 파일 첨부 전송 (pdf/zip/hwp 등) | `chat`, `file_path`, `confirm` |
| `ktok_download_file` | 첨부 다운로드 (자동 스크롤 + Save 패널 driver) | `chat`, `filename?`, `save_dir`, `max_scroll`, `stable_timeout_sec` |

### 대화 DB / 히스토리

| 툴 | 역할 | 주요 파라미터 |
|---|---|---|
| `ktok_sync_history` | AX 자동으로 `Save as a text file` 실행 → CSV 파싱 → DB 업서트 | `chat`, `my_kakao_id?`, `save_dir?`, `stable_timeout_sec?`, `confirm` |
| `ktok_import_history` | 기존 CSV 파일을 DB 에 import (AX 미사용) | `file_path`, `chat_name?`, `chat_id?`, `my_kakao_id?` |
| `ktok_query_history` | DB 검색 (chat / 날짜 / kind / author / 본문) | `chat_name?`, `since?`, `until?`, `kinds[]?`, `authors[]?`, `query?`, `attachments?`, `oldest_first?`, `limit` |

공통 동작:
- `confirm=true` → MCP 레이어에서 `CONFIRMATION_REQUIRED` 로 **즉시 단락** (CLI subprocess 실행 안 함, latency 0ms).
- `trace_ax=true` → 응답 `meta.stderr_trace` 에 AX 동작 로그 포함. 디버깅 최강.
- `initialize` 응답의 `meta.startup_check` 에 ktok 바이너리 ready 상태 + `ktok_bin` 경로.

---

## 대화 DB 스키마 (v1)

`~/Library/Application Support/ktok/ktok.db` (SQLite, WAL, foreign_keys ON)

```sql
CREATE TABLE chats (
  chat_id         TEXT PRIMARY KEY,      -- chat_<12자리 SHA-256 prefix>
  display_name    TEXT NOT NULL,         -- NFC
  my_nickname     TEXT,                  -- 첨부 direction 판정용
  first_seen_at   TEXT NOT NULL,
  last_synced_at  TEXT
);

CREATE TABLE messages (
  id               INTEGER PRIMARY KEY AUTOINCREMENT,
  chat_id          TEXT NOT NULL REFERENCES chats(chat_id),
  sent_at          TEXT NOT NULL,         -- UTC ISO-8601
  author           TEXT NOT NULL,         -- NFC
  body             TEXT NOT NULL,         -- NFC, multi-line OK
  kind             TEXT NOT NULL,         -- text/image/file/voice/video/emoticon/system/other
  raw_line         TEXT,                  -- CSV 원본 라인 (추적용)
  dedupe_key       TEXT NOT NULL UNIQUE,  -- SHA-256(chat_id|sent_at|author|body)
  first_synced_at  TEXT NOT NULL
);

CREATE TABLE attachments (
  id           INTEGER PRIMARY KEY AUTOINCREMENT,
  chat_id      TEXT NOT NULL,
  message_id   INTEGER,                   -- 링크 가능 시
  direction    TEXT NOT NULL,             -- sent/received/unknown
  filename     TEXT,
  local_path   TEXT,                      -- 보낸 파일의 원본 경로, download-file 저장 위치 등
  sent_at      TEXT,
  size_bytes   INTEGER,
  sha256       TEXT,
  source       TEXT NOT NULL,             -- cli_send_file/cli_download_file/parsed_from_dump/manual
  recorded_at  TEXT NOT NULL
);

CREATE TABLE sync_runs (
  id                            INTEGER PRIMARY KEY AUTOINCREMENT,
  chat_id                       TEXT NOT NULL,
  started_at                    TEXT NOT NULL,
  finished_at                   TEXT,
  dump_file_path                TEXT,
  lines_parsed                  INTEGER,
  messages_inserted             INTEGER,
  messages_skipped_duplicates   INTEGER,
  attachments_inserted          INTEGER,
  error                         TEXT
);
```

**핵심 설계**:
- `dedupe_key` = SHA-256 hex of `chat_id|sent_at|author|body` → 같은 메시지 재import/sync 는 `INSERT OR IGNORE` 로 silent skip.
- 모든 텍스트는 **NFC 정규화 후 저장** — macOS 파일시스템(HFS+/APFS)이 NFD 로 내보내는 Korean 과 shell/SQL 의 NFC 사이 불일치 제거.
- `sync_runs` 는 트랜잭션 **바깥** 에서 INSERT (autocommit) — data transaction 이 rollback 돼도 감사 행은 살아남음.
- `message_id` 는 attachment 에서 optional — 첨부가 메시지와 1:1 매칭 안 되는 엣지 케이스 허용.

---

## 설치 & 빌드

```bash
git clone git@github.com:Pandoll-AI/ktok.git
cd ktok
swift build -c release
# binary: .build/release/ktok (약 3 MB, arm64)
# 선택: 전역 설치 (재빌드만으로 자동 갱신되는 심링크)
ln -sf "$(pwd)/.build/release/ktok" ~/.local/bin/ktok
```

### Accessibility 권한

macOS **시스템 설정 → 개인정보 보호 및 보안 → 손쉬운 사용** 에 사용 중인 터미널 / IDE 추가:
- Terminal.app, iTerm2, Warp, VS Code, Cursor 등 실제 ktok 을 실행할 앱
- Claude Code (Electron) 도 MCP 로 호출할 때 필요

`ktok status` 로 상태 확인.

---

## 사용법

### CLI — 실시간

```bash
ktok status                                      # AX 권한 + 카카오톡 실행 확인
ktok chats --json                                 # 채팅방 목록
ktok send "채팅방" "메시지"                         # 텍스트 전송
ktok send-image "채팅방" ~/Desktop/photo.png      # 이미지 전송
ktok send-file "채팅방" ~/Desktop/x.pdf           # 파일 전송
ktok download-file "채팅방" \
    --filename report --save-dir /tmp/out --json  # 첨부 다운로드
ktok read "채팅방" --limit 20 --json              # 최근 메시지
ktok watch "채팅방" --json                        # 실시간 스트림
ktok mcp-server                                   # stdio MCP 서버
```

### CLI — 대화 DB

```bash
# 전체 대화 자동 sync (AX → CSV export → parse → DB)
ktok sync-history "채팅방" --my-kakao-id "내아이디"

# 이미 갖고 있는 CSV 파일 import (AX 미사용, offline)
ktok import-history ~/Downloads/KakaoTalk_Chat_*.csv --my-kakao-id "내아이디"

# DB 쿼리
ktok history "채팅방" --kind file --since 2026-04-01
ktok history --query "회의" --author "홍길동" --limit 10 --json
ktok history --attachments --since 2026-04-10            # 첨부 테이블 조회

# 디버그 — AX 트리 read-only 덤프 (press 0회)
ktok dump-chat-ui "채팅방" --open-settings-then-dump --probe-settings-tabs
```

유지보수 / 디버그 커맨드:
```bash
ktok cache status        # AX path 캐시 상태 확인
ktok cache clear         # AX path 캐시 삭제 (search field 등 cached 포인터 리셋)
ktok inspect --depth 3   # KakaoTalk 앱 전체 AX 트리 덤프 (인자 없이, dump-chat-ui 이전 세대)
```

공통 플래그: `--json`, `--trace-ax`, `--keep-window`, `--deep-recovery`, `--no-cache`, `--refresh-cache`.

`sync-history` 전용 디버그 플래그 (AX 흐름 격리용):
- `--skip-save-press` — NSSavePanel 의 Save 버튼 안 누름 (사용자가 수동)
- `--stop-before-save-as-text` — "Save as a text file" press 이전에 정지
- `--no-dismiss-dialog` — export-done 다이얼로그 OK press 건너뛰기
- `--debug-slow` — 각 AX step 사이 2초 idle

### Claude Code MCP 설정

`~/.claude.json` 에 추가:

```json
{
  "mcpServers": {
    "ktok": {
      "type": "stdio",
      "command": "/absolute/path/to/ktok/.build/release/ktok",
      "args": ["mcp-server"]
    }
  }
}
```

재시작 후 `mcp__ktok__ktok_*` 8개 툴 사용 가능.

### 로컬 smoke handshake

MCP 서버가 정상 부팅하는지 (카카오톡 없이) 1초 안에 확인:

```bash
printf '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"smoke","version":"1"}}}\n{"jsonrpc":"2.0","id":2,"method":"tools/list"}\n{"jsonrpc":"2.0","id":3,"method":"shutdown"}\n{"jsonrpc":"2.0","method":"exit"}\n' \
  | .build/release/ktok mcp-server
```

기대 출력: `serverInfo.name: "ktok-mcp"`, `tools/list` 에 8개 `ktok_*` 툴.

---

## AX 안전 정책

AX 기반 자동화는 UI 레이블 / 포커스 / 타이밍 race 에 취약하다. ktok 은 다음 3중 방어를 **모든** AX 클릭 경로에 적용한다:

1. **라벨 정확 일치 (exact equality)** — `axDescription`/`title` 이 사전 정의된 allowlist 와 trim + case-insensitive 정확 매치될 때만 후보. 좌표·프레임·크기 기반 로직은 **금지** (UI 리사이즈 / 해상도 변경에 regression).
2. **위험 버튼 하드 블록리스트** — `call / voice / video / share / invite / record` (+ 한글 변형) 가 `axDescription`/`title`/`identifier` 어디든 포함되면 후보 리스트에서 **즉시 제외**. Fallback 경로에서도 예외 없음. 역사적 사례: 초기 구현 시 햄버거 press 실패 → 점수 2등 후보인 Video Call 버튼이 자동 눌려 실제 전화 발신 직전까지 갔음.
3. **No-fallback retry** — 타깃 버튼 press 실패 시 **다른 후보로 넘어가지 않는다**. 같은 버튼에 대해서만 재시도 (stale AX ref refresh + 짧은 sleep).

`feedback_no_ax_coords.md`, `feedback_ax_safety.md` (memory) 에 durable rule 로도 세이프가드.

---

## 알려진 제한 / TODO

- **친구 직접 전송**: 현재 resolver 는 검색 시 항상 `chatrooms` 탭을 활성화. 대화 이력 있는 친구는 OK, **한 번도 대화 안 한 친구** 는 `SEARCH_MISS` 가능. 필요 시 chatrooms 실패 → friends 탭 fallback 추가.
- **만료 파일 다이얼로그**: `DialogHandler` 의 `expired` 분기 코드는 Python 원본 그대로 이식됐으나, 2주 이상 된 카카오톡 첨부가 있어야 실런타임 검증 가능. 정적 코드 검토만 완료.
- **배치 AX 스캔**: 한 번의 osascript subprocess 로 50+ row 를 ~6s 에 수집. 네이티브 `AXUIElementCopyAttributeValues` 로 in-process 재구현 가능하지만 150+ LOC + 성능 리그레션 리스크가 있어 보류.
- **XCTest 미도입**: AX 동작이 환경 의존적 (카카오톡 UI 버전, 창 배치, 로그인 상태). 스모크는 handshake one-liner + `ktok sync-history` E2E + 실제 채팅방 대상 수동 테스트로 대체.
- **AX attempt-0 "Cannot complete" + system beep**: Swift AX C API (`AXUIElementPerformAction`) 가 KakaoTalk "Save as a text file" 버튼에 대해 첫 호출에서 `kAXErrorCannotComplete` 반환 → macOS 가 input-rejection beep 을 큐잉 (~100ms 지연 재생). Workaround: **JXA (`System Events .actions.byName("AXPress").perform()`) 우회** — `ChatSettingsNavigator.pressSaveAsTextViaJXA()` 참고. 동일 현상이 hamburger 버튼 press 에도 관찰되지만 사용자 체감 beep 이 없어 유보.
- **Save 패널 경로 override**: KakaoTalk 의 NSSavePanel 은 `Cmd+Shift+G` 를 무시하고 항상 `~/Downloads` 에 저장. `--save-dir` 은 DirectoryWatcher 의 post-landing **relocate** 로 처리.

---

## 라이선스 & 면책

**개인 사용 전용 private fork**. 카카오톡 이용약관 준수, 스팸 / 대량 발송 / 자동 도배 금지. 계정 제재는 사용자 본인 책임. 업무용/상용 배포 목적 아님.

상류(upstream) 프로젝트의 라이선스 조건은 [upstream LICENSE](https://github.com/channprj/kmsg/blob/main/LICENSE) 를 참조.
