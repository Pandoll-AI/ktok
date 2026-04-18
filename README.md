# ktok — 카카오톡 macOS 자동화 CLI + MCP 서버

> 개인용 private fork. macOS Accessibility API 로 카카오톡 데스크톱을 조작하는 **단일 Swift 바이너리** 에 CLI 와 MCP 서버가 함께 들어 있음.

---

## 무엇을 하는가

한 바이너리(`ktok`) 에 세 가지 역할이 합쳐져 있음:

1. **CLI** — `ktok send`, `ktok read`, `ktok send-file`, `ktok download-file`, `ktok watch`, `ktok chats` …
2. **내장 MCP 서버** — `ktok mcp-server` 서브커맨드 한 번으로 Claude Code 용 stdio MCP 서버가 기동. 5개 툴 노출.
3. **저수준 자동화** — macOS Accessibility / Quartz CGEvent / NSPasteboard / AppleScript·JXA 를 직접 호출. 비공식 API 크롤링 없음.

지원 OS: **macOS 13+**. 카카오톡 데스크톱 앱 필수.

---

## ktok 이 채우는 빈틈

| 항목 | ktok |
|---|---|
| `send-file` (임의 파일 첨부 전송) | ✅ |
| `download-file` (첨부 다운로드 + 자동 스크롤 + Save 패널 driver) | ✅ |
| MCP 프레이밍 | **auto-detect** (LSP Content-Length + newline-delimited) |
| Claude Code MCP 호환 | ✅ |
| 채팅 검색 시 탭 활성화 | ✅ (`chatrooms` 탭 강제 활성화) |
| `read` 툴 timeout | 20s / 40s (deep) |
| `initialize.meta.startup_check` | ✅ |
| 프로세스 모델 | 단일 Swift 바이너리. in-process CGEvent / NSPasteboard |
| 파일 전송 프로세스 hop | NSPasteboard `writeObjects` + `setPropertyList` 1회 |
| 의존성 | ktok binary 만 |
| argv 파라미터화 (injection 방지) | 사용자 입력 경로 **전면** (chat name, filename, save_dir) |
| 저장소 수 | 1개 |
| `send-file` / `download-file` 구현 | Swift ~1,300 줄 (타입 안전) |

---

## 디렉토리 구조

```
Sources/
├── VersionGenTool/          # build-time: VERSION 파일 → Swift literal
└── ktok/
    ├── ktok.swift           # @main, 전체 서브커맨드 레지스트리
    ├── Accessibility/       # AX API 래퍼
    │   ├── UIElement.swift        # AXUIElement 추상화 (findAll, press, attribute)
    │   ├── AXActionRunner.swift   # 재시도/검증/키 이벤트 (Cmd+V, Enter 등)
    │   ├── AXPathCache.swift      # 자주 쓰는 AX path 디스크 캐싱
    │   ├── AXConstants.swift
    │   ├── AXError+Extension.swift
    │   └── AccessibilityPermission.swift
    ├── KakaoTalk/           # 앱 인스턴스 + 채팅방 탐색
    │   ├── KakaoTalkApp.swift          # 앱 launch / activate / 창 목록
    │   ├── ChatWindowResolver.swift    # 채팅방 찾고 검색창에 쿼리 투입
    │   ├── ChatListScanner.swift       # 채팅 목록 스캔
    │   ├── ChatIdentityRegistry.swift  # chat_id ↔ displayName 매핑
    │   ├── TranscriptReader.swift      # 메시지 리더
    │   ├── MessageContextResolver.swift
    │   └── KakaoTalkWindowBounds.swift
    ├── Commands/            # 서브커맨드 하나당 파일 하나
    │   ├── StatusCommand.swift, ChatsCommand.swift, InspectCommand.swift
    │   ├── SendCommand.swift, SendImageCommand.swift, SendFileCommand.swift
    │   ├── ReadCommand.swift, WatchCommand.swift, CacheCommand.swift
    │   ├── DownloadFileCommand.swift   # 6-step 오케스트레이터
    │   └── MCPServerCommand.swift      # 내장 MCP 서버 (JSON-RPC stdio)
    ├── Download/            # download-file 전용 헬퍼
    │   ├── AttachmentScanner.swift    # 배치 AppleScript 로 전 row 스캔
    │   ├── FileExtensionMatcher.swift # 60+ 확장자 regex + 저장 마커
    │   ├── SavePressor.swift          # row-index JXA 로 Save 버튼 press
    │   ├── DialogHandler.swift        # friend / expired dialog 분류
    │   ├── SavePanelDriver.swift      # Save 패널 대기 + Cmd+Shift+G 경로 override
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
Download/  (6-step 오케스트레이션 — download-file 전용)
            ↓
KakaoTalk/  (ChatWindowResolver → 창/탭/검색)
            ↓
Accessibility/  (UIElement, AXActionRunner — AX API 래퍼)
            ↓
System/  (NSPasteboard, CGEvent, osascript/JXA)
            ↓
macOS AX API / Quartz / AppKit
```

---

## MCP 툴 표면

Claude Code 에서 노출되는 5개 툴 (`mcp__<server-key>__ktok_*`):

| 툴 | 역할 | 주요 파라미터 |
|---|---|---|
| `ktok_read` | 채팅 최근 메시지 읽기 (JSON) | `chat`, `limit` |
| `ktok_send` | 텍스트 메시지 전송 | `chat`, `message`, `confirm` |
| `ktok_send_image` | 이미지 첨부 전송 | `chat`, `image_path`, `confirm` |
| `ktok_send_file` | 임의 파일 첨부 전송 (pdf/zip/hwp 등) | `chat`, `file_path`, `confirm` |
| `ktok_download_file` | 첨부 다운로드 (자동 스크롤 + Save 패널 driver) | `chat`, `filename?`, `save_dir`, `max_scroll`, `stable_timeout_sec` |

공통 동작:
- `confirm=true` → MCP 레이어에서 `CONFIRMATION_REQUIRED` 로 **즉시 단락** (CLI subprocess 실행 안 함, latency 0ms).
- `trace_ax=true` → 응답 `meta.stderr_trace` 에 AX 동작 로그 포함. 디버깅 최강.
- `initialize` 응답의 `meta.startup_check` 에 ktok 바이너리 ready 상태.

---

## 설치 & 빌드

```bash
git clone git@github.com:Pandoll-AI/ktok.git
cd ktok
swift build -c release
# binary: .build/release/ktok (약 3 MB, arm64)
```

### Accessibility 권한

macOS **시스템 설정 → 개인정보 보호 및 보안 → 손쉬운 사용** 에 사용 중인 터미널 / IDE 추가:
- Terminal.app, iTerm2, Warp, VS Code, Cursor 등 실제 ktok 을 실행할 앱
- Claude Code (Electron) 도 MCP 로 호출할 때 필요

`.build/release/ktok status` 로 상태 확인.

---

## 사용법

### CLI

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

공통 플래그: `--json`, `--trace-ax`, `--keep-window`, `--deep-recovery`, `--no-cache`, `--refresh-cache`.

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

재시작 후 `mcp__ktok__ktok_*` 5개 툴 사용 가능.

### 로컬 smoke handshake

MCP 서버가 정상 부팅하는지 (카카오톡 없이) 1초 안에 확인:

```bash
printf '{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2024-11-05","capabilities":{},"clientInfo":{"name":"smoke","version":"1"}}}\n{"jsonrpc":"2.0","id":2,"method":"tools/list"}\n{"jsonrpc":"2.0","id":3,"method":"shutdown"}\n{"jsonrpc":"2.0","method":"exit"}\n' \
  | .build/release/ktok mcp-server
```

기대 출력: `serverInfo.name: "ktok-mcp"`, `tools/list` 에 5개 `ktok_*` 툴.

---

## 알려진 제한 / TODO

- **친구 직접 전송**: 현재 resolver 는 검색 시 항상 `chatrooms` 탭을 활성화한다. 대화 이력이 있는 친구는 chatrooms 탭 검색에서 잡히지만, **한 번도 대화 안 한 친구**는 `SEARCH_MISS` 가능. 필요 시 chatrooms 실패 → friends 탭 fallback 추가.
- **만료 파일 다이얼로그**: `DialogHandler` 의 `expired` 분기 코드는 Python 원본 그대로 이식됐으나, 2주 이상 된 카카오톡 첨부가 있어야 실런타임 검증 가능. 정적 코드 검토만 완료.
- **배치 AX 스캔**: 한 번의 osascript subprocess 로 50+ row 를 ~6s 에 수집. 네이티브 `AXUIElementCopyAttributeValues` 로 in-process 재구현 가능하지만 150+ LOC + 성능 리그레션 리스크가 있어 보류.
- **XCTest 미도입**: AX 동작이 환경 의존적 (카카오톡 UI 버전, 창 배치, 로그인 상태). 스모크는 위 handshake one-liner 와 실제 채팅방 대상 end-to-end 수동 테스트로 대체.

---

## 라이선스 & 면책

**개인 사용 전용 private fork**. 카카오톡 이용약관 준수, 스팸 / 대량 발송 / 자동 도배 금지. 계정 제재는 사용자 본인 책임. 업무용/상용 배포 목적 아님.

상류(upstream) 프로젝트의 라이선스 조건은 [upstream LICENSE](https://github.com/channprj/kmsg/blob/main/LICENSE) 를 참조.
