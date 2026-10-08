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

- `KtokPaths.migrateLegacyStorageIfNeeded` (`Storage/KtokPaths.swift:173`, 호출 `108`·`116`·`124`, `LoginAccountState.read:321`, `ChatIdentityRegistry.defaultURL:317`). `ensureWorkspace` 와 `copyIfNeeded` 가 호출마다 `fileExists` 를 반복한다. 같은 홈·alias·계정 파일 stamp(mtime, size, inode, 파일 없음 포함)에서는 본문을 건너뛴다. stamp가 바뀌거나 alias가 생기면 본문을 다시 실행한다. `save` / `clear` 는 가드를 리셋한다.
- `LoginAccountState.readWithoutMigration` (`Login/LoginEnvironment.swift:325`). `ChatIdentityRecord.init` 이 레코드마다 `ChatAccountContext.active()` → `read()` 를 호출해 `current-account.json` 을 다시 디코드한다. `ktok login` 상태 출력도 같은 파일을 세 번 읽는다 (`Commands/LoginCommand.swift:196-203`). 경로와 파일 stamp가 같으면 디코드를 생략한다. 읽기마다 stat 1회. 다른 프로세스의 login, logout, config import는 다음 읽기에서 보인다. `save` / `clear` / 마이그레이션 시작에서도 캐시를 비운다.
- `ChannelDaemonCommand` 가 사이클마다 `ChannelStore` 를 두 번 연다 (`poll.run` 내부와 `status()`). open 직전에 찍은 존재 여부와 inode가 같은 동안 연결 하나를 재사용한다. WAL 체크포인트의 mtime·size 변화로는 다시 열지 않는다. poll은 sqlite `DatabaseError`일 때만 버리고, AX 실패는 연결을 유지한다. `status()` 실패는 한 번 재오픈하고, 그것도 실패하면 종료한다. AX 권한이 없으면 sqlite를 열지 않고 안내 후 sleep한다. `poll-once` 는 AX 권한 확인 뒤에 sqlite를 연다. `KtokFileStamp.capture`는 symlink 대상을 읽고, 계정 캐시는 대상의 mtime·size·inode를 비교한다.
- `MessageContextResolver.resolveMessageInputField` (`KakaoTalk/MessageContextResolver.swift:74-82`). 포커스 창과 채팅 창이 같은 AX 원소여도 `collectMessageInputCandidates` 를 두 번 호출한다. 같은 원소이고 포커스 창 탐색이 실제로 돌았을 때만 두 번째 트리를 생략한다. title/frame 읽기가 실패하면 대상 창을 그대로 탐색한다.
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

코드 커밋은 `740cf1a` dead code, `9a4a9d5` paths, `8d863c5` resolver, `6d49970` channel daemon이다. 리뷰 반영은 `b6348c5` read, `ae1ac28` account stat, `699cec9` daemon reopen, `7bb5c30` poll-once 권한 순서, `ff75e9b` gate reset. 이 절과 CHANGELOG는 그 다음 커밋이다.

`swift build -c release`는 각 코드 커밋 전에 통과했다. 경고는 기존 두 종류뿐이다. `LoginCommand.swift`의 `String?` → `Any` 암시 변환, `SecretStore.swift:85`의 `SecKeychainOpen` deprecation. 새로 늘어난 경고는 없다. 마지막 코드 빌드 꼬리: `Build complete! (20.46 sec)`.

`KTOK_BIN=.build/release/ktok bash scripts/test-bot-room-selector.sh`는 리뷰 반영 뒤 카카오톡 없이 다시 통과했다. `passed=20 failed=0`. `ktok monitor is inactive` 검사를 포함한다.

속도는 실측하지 않았다. 줄인 것은 호출 횟수다.

- `migrateLegacyStorageIfNeeded`의 `ensureWorkspace`와 `fileExists`는 같은 홈·alias·계정 파일 stamp에서 프로세스당 1회다. 파일이 생기거나 stamp가 바뀌면 본문을 다시 실행한다. `save` / `clear`는 가드를 리셋한다.
- `current-account.json` 디코드는 stamp가 같은 동안 1회다. 읽기마다 stat 1회. 외부 login, logout, import는 다음 읽기에서 반영된다.
- daemon의 `ChannelStore` open과 `migrate()` SQL은 open 직전 존재 여부·inode가 같은 동안 프로세스당 1회다. poll의 sqlite `DatabaseError`나 `status()` 실패면 다시 연다. AX 실패는 연결을 유지한다. AX 권한이 없으면 sqlite를 열지 않고 sleep한다. `poll-once`는 호출마다 1회이고, AX 권한이 없으면 sqlite를 열지 않는다.
- 채팅 목록 컨테이너 캐시 미스의 role BFS는 3회에서 1회다.
- `read` 입력 후보 탐색은 포커스 창과 대상 창이 `CFEqual`이고 포커스 창 탐색이 돌았을 때 2회에서 1회다. title/frame 비교가 실패하면 대상 창을 탐색해 후보가 비지 않는다.

실측은 카카오톡이 떠 있는 맥에서 `time ktok channel daemon --json --max-loops 1`, `time ktok chats --json`, `time ktok read --json`을 리팩토 전후 바이너리로 비교하면 된다. 이 세션에서는 AX를 조작하지 않아 재지 않았다.

보류는 2절과 같다. 오래 떠 있는 `channel daemon`, `bot run`, `mcp-server`도 계정 파일 stamp가 바뀌면 다음 읽기에서 새 alias를 본다. 재시작은 필요 없다. `KTOK_HOME`이 바뀌면 마이그레이션 본문을 다시 실행한다.

## 5. 영문 시각 라벨 (2026-10-08)

`ChatTextNormalizer.isTimeLikeValue`는 `10:00`, `N일`, `어제`에 더해 영문 UI 채팅 목록의 시각 라벨을 시각으로 본다. `2025년 3월 5일 수요일`, `3월 5일`, `2025년 3월 5일`, `Wednesday, October 8, 2026`, `October 8, 2026`, `3/5`, `24. 3. 5.`도 포함한다. 요일은 있어도 되고 없어도 된다. `차명일`처럼 숫자 없이 `일`로 끝나는 이름은 제목이다. 실제 방 이름이 이 패턴과 정확히 일치하는 경우는 드물다고 가정한다. `Today`나 `월요일`이라는 방도 제목으로 잡히지 않는다.

## 6. 채팅 행 캐시 쓰기 (2026-10-08)

이미지 행과 일반 행의 child index가 달라 `chatRowTitle`이 행마다 stale이 됐다. 스캔은 그 슬롯을 읽지 않고, 캐시 미스 때와 같은 BFS로 시각·카운트가 아닌 첫 정적 텍스트를 고른다. warmup도 그 슬롯을 쓰지 않는다. 슬롯 이름은 예전 캐시 파일을 디코드하려고 남아 있다. `chatRowPreview`가 고르는 원소는 그대로다. 미리보기 슬롯의 파일 쓰기는 스캔이 끝날 때 한 번이고, 경로가 같으면 쓰지 않는다.

## 7. 채팅방 폴더 칩 (2026-10-08)

Unread는 비어 있지 않을 수 있다. 안 읽은 방이 있으면 그 행만 보인다(실측 1행). 칩은 AXPress가 없고, 선택 상태도 AX 속성이 없다. 0행만 보는 조건은 대상 방이 그 부분집합 밖에 있을 때 놓친다. 그 상태에서 검색은 같은 이름 후보를 둘 내고 거절했다. All에서는 같은 방이 보이는 행으로 열렸다.

`ChatWindowResolver.resolve`의 보이는 행 탐색은 대상 제목이 없고(0행 포함) `Chatroom folder` 줄이 있으면 `All folder`를 한 번 누른 뒤 같은 탐색을 한 번 더 한다. 그 다음이 검색이다. 같은 제목이 둘 이상이면 대상이 있는 것이므로 누르지 않는다. 부모 `AXGroup`의 frame 중심(없으면 텍스트 frame 중심)을 HID로 누른다.

`chats` 전체·limit과 `channel refresh-chats`는 폴더 줄이 있으면 스캔 전에 한 번 누른다. 이미 All이면 행 원소가 그대로라 대기는 0.6초에서 끝난다. 0행일 때만 다시 스캔하던 분기는 이 선행 클릭으로 대체했다. refresh가 All 전에 비거나 부분집합만 읽으면 레거시 방 목록으로 떨어질 수 있어서다.

대기는 행이 생길 때까지가 아니다. 보이는 행 원소(최대 80)를 순서대로 `CFEqual`해 집합이 바뀌거나 0.6초다. trace는 `folder: ensured All folder (reason=...)`이다. reason은 `visible-row miss`, `chats pre-scan`, `channel refresh pre-scan`이다.

폴더 줄이 없으면 시도 횟수를 올리지 않는다. 친구 탭이 한 번의 기회를 소모하지 않게 하기 위해서다. 검색 필드가 없을 때의 보이는 행 스캔은 이 헬퍼를 호출하지 않는다.

클릭 전 `activate()`와 0.08초 대기는 `activateChatroomsTab`과 같다. 이어서 0.6초 안에 앞창이 아니면 클릭하지 않는다. 그때는 그 `resolve()`의 한 번을 쓴다. 같은 `resolve()` 안의 두 번째 보이는 행 탐색은 다시 누르지 않는다.

`resolve()`는 시작마다 시도 횟수를 리셋한다. bot·watch처럼 리졸버를 오래 들고 있는 프로세스도 다음 `resolve()`의 miss에서 다시 All을 누를 수 있다. `chats`와 `channel refresh-chats`는 헬퍼를 한 번만 부르므로 명령당 한 번이다.

앞창 확인 뒤에 메인 창 `AXMinimized`가 false인지 본다. false일 때만 그 채팅 목록 창에 `AXRaise`를 한다. 최소화된 창을 클릭하려고 꺼내지 않기 위해서다. Raise 액션이 없거나 실패해도 클릭 판단은 계속한다. 그 다음 칩 frame을 다시 읽는다. 채팅창이 칩 위에 있으면 올린 뒤에야 좌표가 칩을 가리킨다. 그 좌표의 시스템 히트 원소 부모 체인(최대 10단계)에 `Chatroom folder` AXList가 있을 때만 누른다. 하나라도 아니면 클릭하지 않고 trace를 남긴다. 클릭이 나가지 않으면 `ensureAllFolder`는 false이고, 호출부의 다음 경로는 이 함수가 바꾸지 않는다. 클릭 전 커서 위치는 `CGEvent(source: nil)?.location`이고, 클릭 뒤 mouseMoved로 되돌린다.

`send`, `send-image`, `send-file`, bot이 방을 열 때, 그리고 그 명령을 실행하는 MCP send는 `ensureAllFolderBeforeMatch`로 보이는 행 판정 전에 All을 한 번 누른다. read 계열은 대상이 없을 때만 누른다. 줄이 있는데 클릭이 나가지 않으면 그때 보이는 행으로 수취인을 고르지 않는다.

[ASSUMPTION] 클릭이 나간 뒤 행 원소 집합이 0.6초 안에 바뀌지 않으면 이미 All이었다고 보고 동명 판정을 진행한다. 검증: 운영 맥에서 All이 선택된 상태로 `ktok send`를 실행해, trace 대기 뒤 같은 방이 열리는지 본다.

## 8. 전체 스캔의 같은 행 (2026-10-08)

26행이 한 번에 노출되면 `stablePasses >= 3`이 같은 행의 제목·미리보기를 세 번 더 읽는다. 패스 시작에 행 원소를 순서대로 `CFEqual`하고, 같으면 첫·중간·마지막 제목을 세 번 읽는다. AX 원소가 그대로인데 제목만 바뀐 경우를 빼지 않기 위해서다. 원소와 그 제목이 같으면 추출하지 않는다. 이미 넣은 방의 키는 그대로다.

스크롤 위치는 값을 설정하고 0.18초 뒤에 읽는다. 설정 직후 값은 아직 움직이지 않은 숫자일 수 있다. 그 값이 설정 전과 같은 것이 2회 연속일 때만 종료한다. 값이 1.0이면 다음 패스를 한 번 더 수집하고 종료한다. 한 화면에 26방이 다 보이면 이 조건에서 수집 패스는 2 이내다. 스크롤바 속성이 없으면 기존 휠 폴백을 둔다. 휠로만 움직이는 긴 목록의 방 집합을 바꾸지 않기 위해서다.

## 9. 대화 행 수집 (2026-10-08)

컨테이너 직속 행이 있으면 행 BFS를 건너뛴다. 운영 맥 3개 방(3·57·87행)에서 BFS가 그 밖에서 새로 찾은 행은 0개였고, 57행 방에서 BFS는 1.7초였다. 컨테이너 행이 0개면 BFS를 돈다.

컨테이너 행이 있어도, 그 행들의 최대 maxY가 입력창 minY보다 120pt 넘게 위에 있으면 최신 행이 빠진 것으로 보고 BFS를 돈다. AX의 Y는 아래로 커진다. trace는 `rows: bfs skipped (container rows=N, bottom gap=Gpt)` 또는 `rows: bfs ran (reason=...)`이다. 프레임을 읽지 못하면 gap은 `unmeasured`이고, 행이 1개 이상이면 BFS는 건너뛴다.

`extractMessages`를 뒤에서 파싱하는 것은 보류한다. 시각과 날짜 기준은 앞 행에서 뒤로 전달된다. 저자가 확정된 곳에서 멈추면 이어지는 행의 `time_raw`와 `logicalTimestamp`가 바뀔 수 있다. 창 위의 날짜 구분 행이 날짜 기준을 만든다. 라이브 대화 없이 출력이 같다고 확인하지 못했다.
