# Changelog

이 프로젝트의 모든 주목할 만한 변경 사항을 이 파일에 기록한다.

형식은 [Keep a Changelog](https://keepachangelog.com/en/1.1.0/) 를 따르며, 버저닝은 [SemVer](https://semver.org/spec/v2.0.0.html) 를 따른다.

## [Unreleased]

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
