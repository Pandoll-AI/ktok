# ktok 리팩토 노트

줄 번호는 변경 전 소스 기준이다. 적용 여부는 각 항목 끝에 적었다.

## 1. 핫패스 호출 그래프

### `ktok channel daemon` 1사이클

`ChannelDaemonCommand.run` (`Commands/ChannelCommand.swift`)

1. `ChannelPollOnceCommand.run`
2. `AccessibilityPermission.ensureGranted`
3. `ChannelStore.init` → `migrate()` (sqlite `CREATE IF NOT EXISTS`) → `monitoredChats()`
4. 방마다 `chatIDsForTitle` 후 `ChatWindowResolver.resolve`
   - `requireUsableWindow` → `KakaoTalkApp.focusedWindow` / `mainWindow` / `windows` / `ensureMainWindow`
   - `findMatchingChatWindow`
   - `openVisibleExactChatRow` → `ChatListScanner.scan` → `resolveChatListContainer`
   - 실패 시 `activateChatroomsTab` 후 같은 행 탐색을 한 번 더
   - 그래도 실패하면 `openChatViaSearch`
5. `KakaoTalkTranscriptReader.readSnapshot` → 내부에서 새 `MessageContextResolver.resolve` → `collectTranscriptRows` / `extractMessages`
6. `ChannelStore.insertSnapshot`
7. 루프 밖 `ChannelStore().status()` 로 **연결을 다시 열고** `migrate()` 를 다시 실행한 뒤 `Thread.sleep(nextIntervalSeconds)`

한 사이클의 AX 앱·resolver·reader 는 `poll.run()` 이 매번 새로 만든다. 카카오톡 재시작(PID 변경)을 따라가므로 이 재생성은 유지한다.

### `ktok read`

`ReadCommand.run`

1. `AccessibilityPermission.ensureGranted`
2. `KakaoTalkApp` → `ChatWindowResolver.resolve` (위와 같은 창 해석)
3. `KakaoTalkTranscriptReader.readSnapshot` → `MessageContextResolver.resolve`
4. `recordEvents == true` 이면 `KtokWorkspaceStore.recordReadSnapshot`
   - `resolveScope` 가 계정을 한 번 읽고, chat id 가 없으면 `rooms.json` 을 한 번 읽는다
   - 메시지마다 `appendEvent` (JSONL append 잠금은 유지)
5. `--json` 이면 `printMessagesAsJSON`

### `ktok send`

`SendCommand.run`

1. `--dry-run` 이면 AX 없이 종료
2. `prepareCacheIfNeeded` → `AXPathCacheStore` (기본은 메모리 캐시)
3. `KakaoTalkApp` → `--chat-id` 면 `ChatIdentityRegistryStore.shared.record` (`rooms.json` 1회)
4. `ChatWindowResolver.resolve`
5. `sendMessageToWindow` → 입력 필드 해석 → `MessageSender.sendFocusFree`
   - 입력 일치 확인 → Enter 후 비워짐 확인 → 실패 시 포그라운드 폴백
6. `closeWindowsIfNeeded`

`SendCommand.resolveMessageInputField` 는 포커스 창과 대상 창이 같은 AX 원소면 트리를 한 번만 걷는다.

### `ktok chats`

`ChatsCommand.run`

1. `AccessibilityPermission.ensureGranted` → `KakaoTalkApp`
2. `chatListWindow` 또는 `ensureMainWindow`
3. `AccountProfileDetector.detectCurrentProfile` 성공 시 `LoginAccountState.save`, 실패 시 Cmd+2 와 `Thread.sleep(0.25)` 후 스캔
4. `ChatListScanner.scan` 또는 `scanAll`
5. `ChatIdentityRegistryStore.shared.assignChatIDs` → `rooms.json` 읽기·원자적 쓰기
6. JSON 또는 텍스트 출력

### `ktok bot run` (다음 핫패스)

`BotRunCommand.run` (`Commands/BotCommand.swift`)

1. `ChannelStore` 1회, `Persona.load` 1회, `BotRoomSelector.selectRooms` / `verifyTitleMapsToChatID` (Accessibility 이전)
2. `MonitorStateStore.open` → `KtokPaths.activeDatabasePath` (여기서 레거시 마이그레이션)
3. 루프: `processRoom` → `verifyTitleMapsToChatID` → `ChatWindowResolver.resolve` (창을 유지) → `readSnapshot` → 새 메시지에만 `contextResolver.resolve` 로 입력을 다시 찾아 `MessageSender.sendFocusFree`

## 2. 중복·낭비 후보

### 적용

- `KtokPaths.migrateLegacyStorageIfNeeded` (`Storage/KtokPaths.swift:173`, 호출 `108`·`116`·`124`, `LoginAccountState.read:321`, `ChatIdentityRegistry.defaultURL:317`). `ensureWorkspace` 와 `copyIfNeeded` 가 호출마다 `fileExists` 를 반복한다. 계정 alias 가 바뀌기 전에는 본문을 건너뛴다. alias 가 없어 방 복사를 못 한 경우에는 계정 파일이 생긴 뒤 한 번 더 돌린다. 디렉터리 생성은 alias 가 바뀔 때 유지한다.
- `LoginAccountState.readWithoutMigration` (`Login/LoginEnvironment.swift:325`). `ChatIdentityRecord.init` 이 레코드마다 `ChatAccountContext.active()` → `read()` 를 호출해 `current-account.json` 을 다시 디코드한다. `ktok login` 상태 출력도 같은 파일을 세 번 읽는다 (`Commands/LoginCommand.swift:196-203`). 경로별로 프로세스 메모리에 두고, `save` / `clear` / 마이그레이션 시작 때 무효화한다.
- `ChannelDaemonCommand` 가 사이클마다 `ChannelStore` 를 두 번 연다 (`poll.run` 내부와 `status()`). 프로세스당 연결 하나, `migrate()` SQL 은 기동 시 한 번.
- `MessageContextResolver.resolveMessageInputField` (`KakaoTalk/MessageContextResolver.swift:74-82`). 포커스 창과 채팅 창이 같은 AX 원소여도 `collectMessageInputCandidates` 를 두 번 호출한다. `SendCommand` 는 이미 `CFEqual` 이면 한 번만 걷는다. 같은 가드를 읽기 경로에 넣는다. 원소가 다르면 두 번 유지.
- `ChatListScanner.resolveChatListContainer` (`KakaoTalk/ChatListScanner.swift:197-200`). 캐시 미스마다 table / outline / list 를 `maxNodes: 220` 으로 세 번 BFS 한다. 기존 `UIElement.findAll(roles:roleLimits:maxNodes:)` 한 번으로 역할별 첫 원소를 고르고, 우선순위(table → outline → list)는 그대로 둔다.
- 미사용 심볼. 저장소 전체(swift·sh·md 본문)에서 정의 외 참조가 없다. CHANGELOG 의 과거 문장은 이력으로 남긴다.
  - `WatchCommand.findOverlapCount` (`Commands/WatchCommand.swift:558`) — `findOverlap` 만 사용
  - `ChatSettingsNavigator.findPressable` (`:787`), `findSettingsMarker` (`:945`) — 설정 창 판별은 `containsChatroomSettingsMarker`
  - `MonitorCommand.runLegacy` 와 그 아래 private 본문 (`Commands/MonitorCommand.swift:69-512`). `MonitorStateStore` 는 `BotCommand` 가 쓴다
  - `ChatWindowResolver.windowContainsLikelyChatInput` (`:872`) 와 이것만 부르던 `isLikelyMessageInputElement` · `isLikelySearchField`
  - `ChatListScanner.snapshots(from:)` (`:235`) — 호출 없음
  - `SyncRunRecord` (`Storage/Models.swift:66`)
  - `KtokPaths.activeAccountDir` (`:103`)
  - `ChatRepository.findByDisplayName` (`Storage/Repositories.swift:42`)
  - `AXActionRunner.pressCommandA` (`Accessibility/AXActionRunner.swift:241`)
  - `SavePanelDriver.pressSaveButtonViaAX` (`Download/SavePanelDriver.swift:118`) 와 전용 `findEnclosingWindow`
  - `KakaoTalkApp.printHierarchy` (`:288`) 와 전용 `printElement`
  - `UIElement.systemWide` (`Accessibility/UIElement.swift:35`). 메시징 타임아웃은 `configureMessagingTimeoutOnce` 가 `AXUIElementCreateSystemWide` 를 직접 호출한다

### 보류

- `Thread.sleep` 79곳. 핫패스에서 sleep 직후 **같은 조건**을 이미 폴링하는 곳은 없다. `waitUntil` / `focusWithVerification` 안의 sleep 은 그 폴링 간격이다. Cmd+2·탭 전환·스크롤·raise 뒤의 고정 sleep 은 다음이 단발 AX 읽기라서, 줄이면 요소를 놓칠 수 있다. 이 세션에서는 카카오톡 UI 를 재지 못하므로 값을 바꾸지 않는다.
- `ChatWindowResolver.resolve` 의 보이는 행 스캔 2회 (`:97` 과 탭 전환 후 `:110`). 두 번째는 탭이 바뀐 뒤라 트리가 다르다.
- `KakaoTalkTranscriptReader.collectTranscriptRows` 의 direct children + `findAll` + 부족할 때의 row BFS. 앞 단계가 충분해 보여도 중첩 행이 다를 수 있다.
- `collectMessageInputCandidates` 의 role BFS 와 editable BFS. 합치면 `limit` 이 반으로 줄어 후보 집합이 바뀐다.
- `ChatIdentityRegistryStore.shared` 는 호출마다 새 인스턴스라 `rooms.json` 을 다시 읽는다. 한 명령 안에서는 보통 1회다. 진짜 싱글톤으로 바꾸면 오래 떠 있는 `mcp-server` 가 다른 프로세스가 갱신한 방 목록을 못 본다.
- `AXPathCacheStore` 는 이미 `static let shared` 와 `cachedDocument` 가 있다. 파일 읽기는 프로세스당 1회(무효화·fingerprint 변경 제외). 추가 캐시 없음.
- `chat-id-map.json` 은 `channel refresh-chats` 가 TTL 확인으로 1회 읽는다. daemon 사이클은 sqlite 만 본다.
- persona JSON 은 `bot run` 시작 시 `Persona.load` 1회. 루프마다 다시 읽지 않는다.
- `read` 가 만든 transcript context 를 bot 전송이 다시 `resolve` 하는 것. 두 resolver 는 `AXPathCacheStore.shared` 를 쓴다. 캐시 히트면 트리를 다시 걷지 않고, 미스일 때만 중복이다. 스냅샷에 입력 원소를 실어 나르면 전송 검증 경로가 바뀐다.
- daemon 이 사이클마다 `KakaoTalkApp` 을 새로 만드는 것. PID 가 바뀌면 옛 AX 앱 원소는 죽는다.

## 3. 지우지 않는 것

- `ChannelRefreshChatsCommand.LegacyRoomsFile` (`ChannelCommand.swift:28-155`). AX 스캔이 chat id 를 하나도 못 줄 때의 `rooms.json` 폴백이다.
- `KtokPaths` 레거시 복사 자체(`legacy-migration.json`, Application Support db, `~/.ktok/chat-registry.json`, 옛 ax 캐시). 횟수만 줄인다.
- `inspect`, `dump-chat-ui`, `cache`. 진단 커맨드다.
- `ktok monitor` 의 플래그, `validate()`, fail-closed `run()` 메시지와 종료 동작. 죽은 `runLegacy` 본문만 제거한다.
- `ktok bot` 방 선택 우선순위와 `--chat` / `--chat-id` / `--all-monitored` 상호배타.
- `MessageSender.sendFocusFree` 의 입력 일치 → Enter 후 비워짐 → 포그라운드 폴백.
- `read` / `watch` 의 이벤트 기록과 `--no-record-events`.
- JSONL append 잠금·atomic write (`docs/DEV_GUIDE.md`).
- Keychain 과 로그 스크럽.

## 4. 검증

코드 커밋은 `740cf1a` dead code, `9a4a9d5` paths, `8d863c5` resolver, `6d49970` channel daemon. 이 절과 CHANGELOG는 그 다음 커밋이다.

`swift build -c release`는 각 코드 커밋 전에 통과했다. 경고는 기존 두 종류뿐이다. `LoginCommand.swift`의 `String?` → `Any` 암시 변환, `SecretStore.swift:85`의 `SecKeychainOpen` deprecation. 새로 늘어난 경고는 없다. 마지막 코드 빌드 꼬리: `Build complete! (21.79 sec)`.

`KTOK_BIN=.build/release/ktok bash scripts/test-bot-room-selector.sh`는 카카오톡 없이 통과했다. `passed=20 failed=0`. `ktok monitor is inactive` 검사를 포함한다.

속도는 실측하지 않았다. 줄인 것은 호출 횟수다.

- `migrateLegacyStorageIfNeeded`의 `ensureWorkspace`와 `fileExists`는 같은 홈·alias에서 매 호출에서 프로세스당 1회로 준다. alias가 없으면 그 상태를 기억하고, 계정 파일이 생긴 뒤 본문을 다시 실행한다.
- `current-account.json` 디코드는 같은 경로의 반복 `read` / `readWithoutMigration`에서 무효화 전까지 1회다.
- daemon 사이클의 `ChannelStore` open과 `migrate()` SQL은 사이클당 2회에서 프로세스당 1회다. `poll-once`는 호출마다 1회다.
- 채팅 목록 컨테이너 캐시 미스의 role BFS는 3회에서 1회다.
- `read` 입력 후보 탐색은 포커스 창과 대상 창이 `CFEqual`일 때 2회에서 1회다. 원소가 다르면 2회다.

실측은 카카오톡이 떠 있는 맥에서 `time ktok channel daemon --json --max-loops 1`, `time ktok chats --json`, `time ktok read --json`을 리팩토 전후 바이너리로 비교하면 된다. 이 세션에서는 AX를 조작하지 않아 재지 않았다.

보류는 2절과 같다. 다른 프로세스가 `current-account.json`을 바꿔도 이 프로세스의 계정 캐시는 `save`, `clear`, 마이그레이션 본문이 돌기 전까지 유지된다. 한 번 실행되는 CLI는 프로세스가 끝나며 캐시가 사라지고, 오래 떠 있는 `channel daemon`, `bot run`, `mcp-server`는 계정 전환 뒤 재시작이 필요하다.

마이그레이션 가드 키는 홈 경로와 alias다. 같은 프로세스에서 `KTOK_HOME`이 바뀌면 본문을 다시 실행한다.
