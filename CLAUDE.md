# PRView — Claude Code 용 안내

팀 GitHub PR 을 모아 보고, 이 맥에 설치된 Claude Code 로 리뷰 초안을 만들고,
사용자가 확인한 것만 GitHub 에 올리는 macOS 앱.

이 문서는 **이 저장소에서 일하는 에이전트를 위한 것**이다. 사람용 안내는 `README.md`.

## 공개 저장소다 — 올리는 모든 것이 공개된다

소스·커밋 메시지·테스트·주석·README 가 전부 누구나 보는 곳(`itaehyeok/PRView`)에 올라간다(2026-10-30 소스 공개).

- **실제 레포·PR·사람에서 가져온 것을 넣지 마라.** 레포 이름, PR 번호, GitHub 아이디·이름, 리뷰에 나온 코드
  식별자·파일 경로·기능 설명, 실측 리뷰 문장을 테스트 픽스처·주석·커밋 메시지에 옮기지 않는다. 실측에서 배운 것은
  가짜 소재로 다시 쓴다 — 레포는 `acme/sample-ios`, 사람은 Alex·Jamie·Sam·Riley, PR 은 #128·#131 처럼.
  주석에 "실측" 을 남길 때도 무엇을 쟀는지(숫자)만 쓰고 어느 레포·PR 인지는 쓰지 않는다.
- **커밋 작성자는 noreply 메일이어야 한다.** 새 클론·워크트리에서 먼저:
  `git config user.email 123340718+itaehyeok@users.noreply.github.com` · `git config user.name itaehyeok`
- **push 전 검사를 켠다**: `git config core.hooksPath Scripts/git-hooks`. `pre-push` 가 올라갈 커밋마다 작성자 메일,
  이 저장소와 뿌리가 같은지, 이 맥의 PRView 데이터에 등록된 레포·사람 이름이 메시지·변경에 들었는지 본다.
  걸리면 고쳐서 다시 커밋한다 — 검사를 끄고 올리지 마라. 한 번 올라간 커밋은 지워도 주소로 계속 열린다.
- 이 저장소와 뿌리가 다른 이력(예전 비공개 저장소의 클론)을 여기에 push 하지 마라.

## 처음 받았다면 — 사용자를 이 순서로 도와라

```bash
bash Scripts/doctor.sh      # 빠진 것과 고치는 명령을 알려 준다. 항상 여기서 시작
bash Scripts/install.sh     # 빌드 + ~/Applications/PRayer.app 설치
open ~/Applications/PRayer.app
```

`doctor.sh` 가 빨간불을 내면 그 항목만 해결하면 된다. 자주 걸리는 것:

- **Xcode 가 필요하다.** Command Line Tools 로는 안 된다 — `xcodebuild` 가 CLT 에 없고,
  SwiftUI·`@Observable` 매크로 확장이 Xcode 안의 `swift-plugin-server` 를 쓴다.
- **서명**: 알림을 받으려면 실제 Apple Development 인증서가 필요하다(ad-hoc 서명은 macOS 가
  알림을 거부한다). 팀 ID 는 `Scripts/gen.sh` 가 인증서의 OU 에서 자동으로 찾는다.
  인증서가 없으면 Xcode → Settings → Accounts 에서 Apple ID 로그인(무료 계정도 된다).
  자동 감지가 안 맞으면 `echo 'PRAYER_TEAM_ID=ABCDE12345' > Local.env` (커밋되지 않는다).
- **계정 연동은 사용자 몫이다.** 앱은 토큰을 저장하지 않고 이 맥의 `gh auth login` 과
  `claude` 로그인을 그대로 빌려 쓴다. 볼 레포는 앱 설정에서 각자 고른다(기본값 없음).

## 명령

```bash
bash Scripts/doctor.sh            # 준비 상태 점검
bash Scripts/gen.sh               # project.yml → PRayer.xcodeproj
bash Scripts/build.sh             # 빌드
bash Scripts/test.sh              # 단위 테스트 (현재 1031개)
bash Scripts/install.sh           # 빌드 + 설치 (개발용, 이 맥에서만 열린다)
bash Scripts/install.sh "머지 버튼"         # 곁가지 워크트리: "PRView - 머지 버튼" 작업본으로 설치(아래 "개발 빌드 이름")
bash Scripts/dev-name.sh <앱> "머지 버튼"   # 세션 확인용 사본에 같은 꼴의 이름 붙이기
bash Scripts/release.sh --beta            # 서명·공증 → 이 저장소에 시험판으로 다음 베타(0.5.0-beta.N, 번호는 자동)
bash Scripts/beta.sh                      # 가장 새 베타를 이 맥에 깐다(켜진 앱을 내리고 바꿔 끼움)
bash Scripts/release.sh 0.5.0 --promote   # 0.5.0 의 마지막 베타 zip 을 그대로 공개 0.5.0 으로(RELEASE_NOTES_FILE 필수)
bash Scripts/release.sh 0.6.0 --beta      # 공개한 뒤 새 목표의 첫 베타(목표 번호는 사용자가 정한다)
bash Scripts/setup.sh             # 남에게 주는 설치·업데이트 (빌드 없이 릴리스를 받는다)
bash Scripts/test.sh --integration        # 실제 gh 호출까지 (토큰 안 씀)
bash Scripts/test.sh --models             # 설치된 claude 에 별칭 → 모델을 묻는다 (토큰 안 씀)
bash Scripts/test.sh --review <번호>      # 실제 Claude 리뷰 1건 (토큰 씀)
PRAYER_EVAL_DIR=PRayer-eval-r1 bash Scripts/test.sh --review-batch <번호>,<번호> 4
                                          # 여러 건 동시 리뷰 + 문체 채점(토큰 많이 씀).
                                          # 프롬프트를 고친 뒤 결과를 재는 용도. 회차마다 폴더를 나눈다
bash Scripts/test.sh --relevance <번호>   # "이미 언급됨" 대조 1건
bash Scripts/test.sh --explain <번호>     # 코멘트 설명 1건
bash Scripts/readme-shots/shoot.sh        # 공개 README 화면 5장을 데모 데이터로 다시 찍는다(아래 "README 캡처")
```

`--integration` 아래의 실측 명령들은 **진짜 레포**가 있어야 돈다. 공개 저장소라 레포명을
소스에 박을 수 없으므로 각자 지정한다(커밋되지 않는다):

```bash
echo 'PRAYER_TEST_REPO=owner/name' >> Local.env
```

지정하지 않으면 가짜 기본값(`acme/sample-ios`)으로 조회해 `Could not resolve to a
Repository` 로 실패한다. 스크럽 이후 이 경로가 통째로 끊겨 있던 적이 있다.

스크립트는 반드시 `bash Scripts/...` 로 실행한다. `./Scripts/test.sh` 로 직접 실행하면
일부 환경에서 xcodebuild 가 테스트 번들을 로드하지 못해 실패한다(원인 미확인).

**README 캡처.** README 의 화면 5장(`docs/screenshots/` 의 list·overview·
review·review-clean·files)은 `bash Scripts/readme-shots/shoot.sh --out docs/screenshots`
한 번으로 다시 찍는다(`--out` 을 빼면 `build/readme-shots/shots/`, 이름을 주면 그 장만). 빌드 → 번들 ID·데이터
폴더를 바꾼 사본(ad-hoc 서명)을 데모 모드(`PRAYER_DEMO=1`, DEBUG 전용 `DemoData` — 가짜 레포 acme/sample-ios·
sample-sdk, 가짜 사람 Alex·Jamie·Sam·Riley)로 뒤에서 띄우고, `DebugLaunch` 로 창 틀 1720x1050pt·라이트 모드·
고를 PR·탭을 맞춰 창째(`screencapture -l`) 찍는다(Retina 에서 3440x2100). 찍은 직후 `border.swift` 가 창 모양을
따라 4px 반투명 회색 테두리를 두른다(3448x2108) — 흰 창이 GitHub 흰 바탕에 묻혀서 넣었다. 공개로 나가는 그림이라 진짜 레포·PR·
팀원 이름은 절대 넣지 않는다 — 화면이 바뀌어 보여 줄 것이 모자라면 `DemoData` 를 보탠다. 데모 모드에서는
GitHub·Claude 를 부르는 함수가 첫 줄의 `guard !DemoMode.isOn` 에서 멈춘다. 새 조회 함수를 더하면 그 가드도 단다
(빠지면 가짜 화면에 진짜 조회가 섞이거나 없는 경로 `/nonexistent/gh` 오류가 뜬다).

## 개발 빌드 이름 — `PRView - <작업>`

사용자는 세션 여럿을 동시에 돌려서 개발 빌드가 여럿 뜬다. **사용자 눈에 띄는 개발 빌드는 Dock·⌘Tab·앱 메뉴·
Finder 에 `PRView - <작업>` 으로 뜨게 한다** — 이름만 보고 어느 세션의 무슨 작업인지 가를 수 있게(2026-10-22
사용자 요청). 전에는 전부 "PRView" 나 "PRView 작업본" 으로 떠서 가를 수 없었다.

- **`<작업>` 은 이 워크트리에서 만드는 것의 핵심을 짧은 한국어로** 쓴다. 예: `머지 버튼`, `슬랙 드롭다운`,
  `좁은 리뷰 머리`. 브랜치 이름(`feat/merge-button`)을 그대로 쓰지 않는다. 10자 안팎 — 길면 Dock·⌘Tab 에서
  잘린다. `/` `:` `"` `\` 와 이모지는 못 쓴다(파일 이름이다).
- **작업본**: 곁가지 워크트리에서 `bash Scripts/install.sh "<작업>"` → `~/Applications/PRView - <작업>.app`.
  이름을 빼면 브랜치 끝 이름(`merge-button`)이 붙는다 — 돌기는 하지만 사용자가 읽기 어려우니 늘 준다.
  작업본 자리는 여전히 하나다(번들 ID `dev.itaehyeok.PRayer.work`, 데이터 `PRayer-work`). 다른 세션이 깔면
  그 세션 이름으로 바뀐다 — 그래서 이름이 지금 깔린 게 누구 것인지 알려 준다.
- **세션 전용 확인용 사본**(번들 ID·데이터 폴더를 바꿔 띄우는 것)도 띄우기 전에 같은 꼴의 이름을 붙인다:
  번들 ID·`PRayerDataDirectory` 를 먼저 고치고 `bash Scripts/dev-name.sh <사본.app> "<작업>"`. 스크립트가
  파일 이름·`CFBundleName`·`CFBundleDisplayName`·`InfoPlist.strings` 넷을 같은 값으로 맞추고 ad-hoc 재서명·
  LaunchServices 등록까지 하고, 바뀐 경로를 마지막 줄에 찍는다. 넷 중 하나라도 다르면 Finder·Dock 은 파일
  이름을, 앱 메뉴·⌘Tab 은 원래 이름 "PRView" 를 보인다(실측). `PRayer-check-<세션>` 같은 표식만 붙이지 않는다.
- **스스로 화면을 찍어 확인하는 사본은 `open -n -g` 로 띄운다**(`-g` 없이 띄우면 사용자 화면 맨 앞에 뜬다).
  데모 모드나 `PRAYER_DEBUG_*` 로 켠 사본은 창을 다른 앱 창 뒤(층 -1)에 스스로 깐다(`BackgroundCopy`) —
  `-g` 만으로는 맨 앞 앱 바로 아래에 놓여 다른 앱 창을 덮었다. 가려져도 `screencapture -l` 은 찍힌다. 창을
  `CGWindowList` 로 찾을 때 layer 0 만 거르면 못 찾는다(`winlist.swift` 처럼 -1 도 본다). 사용자가 Dock·⌘Tab
  으로 부르거나 `-g` 없이 열면 제 층으로 돌아온다. 창이 보이는 채로 재야 하는 성능 실측은 `PRAYER_DEBUG_KEEP_LAYER=1`.
- 띄웠다고 알릴 때는 그 이름을 그대로 말한다("Dock 의 `PRView - 머지 버튼`").
- 메인 체크아웃 설치(사용자가 쓰는 앱)·베타·배포본은 그대로 `PRView` 다. README 캡처 사본(`shoot.sh`)은
  사용자 눈에 띄지 않게 뒤에서 찍고 바로 지우므로 해당하지 않는다.

## 구조

- `Sources/PRayerCore` — 정적 라이브러리. GitHub 조회·게시, Claude 실행, diff 파싱,
  초안 검증, 리뷰 큐, 저장소(JSON 파일)
- `Sources/PRayer` — SwiftUI 앱. 온보딩, PR 목록, 상세, AI 리뷰 탭, 게시 미리보기
- `Resources/*.md` + `*-schema.json` — Claude 프롬프트와 구조화 출력 스키마.
  프롬프트를 고치면 동작이 바뀐다. 스키마에 필드를 더할 때는 `additionalProperties:false` 를 기억할 것
- **설정 공유**(`SettingsTransfer`) — 설정을 항목 단위로 파일에 담고, 받는 쪽이 지금 값과 견줘 고른 것만
  들인다. `Settings` 에 칸을 더하면 공유할 값인지 정하고, 공유한다면 담기(`payload`)·검사(`sanitized`)·
  목록(`sections`, 제목·설명)·적용(`apply`)에 같이 넣는다. 그 맥에서만 맞는 값(실행 파일 경로·온보딩 상태)은
  담지 않고, 경로는 `~` 로 담는다. 목록 값은 합치기만 한다(받은 파일에 없다고 지우지 않는다)
- `Tests/PRayerCoreTests` — Core 단위 테스트. UI 는 테스트하지 않는다.
  `ReviewStyleCheck` 는 모델 출력이 사용자가 정한 문체를 지켰는지 재는 판정기다
  (✗ 는 위반, △ 는 사람이 읽을 것). `--review-batch` 와 저장된 초안 채점이 이걸 쓴다
- **모델 목록은 코드에 박지 않는다.** 계열 별칭(`opus`·`fable`·`sonnet`·`haiku`)만 두고
  `--model` 에 그대로 넘긴다. 각 별칭이 지금 무슨 모델인지는 앱이 CLI 에 `/model` 로 묻는다
  (`ModelProbe` — CLI 안에서 처리되는 명령이라 토큰 0). CLI 경로·버전이 바뀔 때만 다시 묻는다.
  같은 응답의 "Available:" 별칭 중 **같은 이름의 계열 모델로 풀리는 것**은 새 계열로 더하고(`best`·`default`
  는 다른 계열을 가리켜 빠진다), effort 단계는 `claude --help` 의 `--effort` 설명에서 읽는다. 계열이 새 버전으로
  넘어가면 앞 버전은 '과거 버전 고르기' 에 남는다(`remembered-models.json`). 새 모델이 나와도 손댈 곳이 없다.
  **가격은 두지 않는다** — 앱 어디에도 비용을 보이지 않는다(사용자 결정). 원장의 `costUSD` 는 남기기만 한다.
- **리뷰 엔진은 Claude Code·Codex 둘**(`ReviewEngineKind`, 2026-10-29). 엔진은 따로 저장하지 않고 모델 값이 말한다 —
  Codex 모델은 `codex:` 앞말(`codex:sol` 계열 · `codex:gpt-5.6-sol` 고정). Codex 모델·effort 도 앱에 박지 않는다:
  `codex app-server` 의 `model/list`(토큰 0)로 받고(`CodexCatalog`), 계열은 목록의 가장 새 `gpt-<버전>-<계열>` 로 푼다.
  목록은 서버가 CLI 버전에 맞춰 걸러 줘 CLI 를 안 올려도 바뀌므로 12시간마다 다시 묻는다. 리뷰 모델 메뉴 하나에
  Claude Code·Codex 구역을 둔다(시안 A, 사용자 결정). 둘 중 하나만 붙여도 되고 나머지는 설정 › 연결에서 붙인다.

## 함정 (전부 실제로 겪은 것)

- **GUI 앱에서 CLI 를 찾을 때 로그인 셸(`zsh -lc`)만 쓰면 `~/.zshrc` 를 안 읽는다.** nvm·예전
  로컬 설치의 alias·PATH 추가는 대개 거기 있어서, 팀원마다 "누구는 되고 누구는 설치 안 됨" 으로
  갈렸다. 셸에 물을 땐 `ExecutableLocator`(로그인·대화형 `-l -i`, 표준 입력은 비움)를 쓴다.
  CLI 가 아예 없는 사람(데스크톱 앱만 씀)도 있으니 없는 경로로 로그인 창을 열지 말고 설치로 안내한다.
- **새 모델이 안 보이면 앱이 아니라 CLI 가 낡은 것이다.** 앱이 부르는 `~/.local/bin/claude` 는
  Claude 데스크톱 앱이 올리는 CLI 와 따로라 뒤처질 수 있다(2026-09-29 실측: 2.1.258 vs 2.1.281 —
  `opus` 가 한쪽은 Opus 5, 다른 쪽은 Opus 5.5). `claude update` 후 앱으로 돌아오면 목록이 바뀐다.
- **모델 확인에 `/model` 말고 다른 입력을 쓰지 마라.** 일반 문장은 API 로 가서 앱을 켤 때마다
  토큰을 쓴다. `/model` 이 API 로 넘어가게 바뀌면 `spentTokens` 로 잡혀 그 버전에서는 다시 묻지 않는다.
- **Codex(`CodexRunner`, 실측 0.149.0)** — `codex app-server` 는 답하기 전에 표준 입력이 닫히면 답 없이 끝난다(답을 받을
  때까지 열어 둔다). `--disable` 에 CLI 가 모르는 기능 이름을 넘기면 "Unknown feature flag" 로 멈춘다 — `codex features list`
  에 있는 것만 넘긴다. `-s read-only` 는 디스크 읽기를 막지 않아, 도구가 필요 없는 호출은 `shell_tool`·`unified_exec` 를
  끈다(이 둘이면 셸이 막힌다. `code_mode_host` 까지 끄면 오류 이벤트만 는다). `--output-schema` 는 OpenAI 엄격 스키마라
  `StrictSchema` 로 바꿔 넘긴다 — 스키마에 필드를 더하면 `CodexTests` 의 스키마 검사가 같이 본다.
- **실측 리뷰(`--review`)는 PR 의 diff 를 모델로 보낸다.** 레포는 `PRAYER_TEST_REPO`(환경변수 → Local.env)다.
  `Local.env` 를 읽으면서 환경변수를 덮던 버그가 있었다(지금은 고침) — 돌리기 전에 어느 레포인지 확인한다.
  모델을 바꿔 잴 때: `PRAYER_REVIEW_MODEL=codex:sol bash Scripts/test.sh --review <번호>`.

- **버전 규칙 — 베타는 다음 공개 번호 + 베타 번호다**(0.5.0-beta.1, 0.5.0-beta.2 … → 공개 0.5.0). 베타를 몇 번
  내도 공개 번호는 따라 오르지 않는다(예전엔 베타마다 0.4.12 … 0.4.31 로 올라 공개가 0.4.11 → 0.4.31 로 건너뛸
  참이었다). **베타 번호를 손으로 정하지 마라** — `release.sh --beta` 가 origin 의 태그를 보고 매기니 여러 작업이
  번호를 맞출 필요가 없다. 지금 목표는 project.yml 의 `MARKETING_VERSION` 이고, 목표를 바꾸는 건 사용자 결정이라
  열린 목표가 있는데 다른 번호를 주면 멈춘다(`PRAYER_RETARGET=1`). 앱 버전(`CFBundleShortVersionString`)에는
  `-beta.N` 을 붙이지 않는다 — 승격은 같은 zip 을 옮기고, 애플 규칙도 숫자 세 자리다. 베타 번호는 Info.plist 의
  `PRayerBetaNumber` 에 따로 박히고, 베타·정식 구분은 여전히 공개 저장소에 그 버전이 있는지로 한다.
- **커밋별로 보기(`DiffCommits`·`CommitGraph`, 0.6.1 베타 15 부터)** — 변경 파일 탭 맨 위 한 줄의 버튼. 켜면 그 아래 PR 커밋
  그래프 표가 펼쳐지고 브랜치의 첫 커밋이 골라진다(맨 위 "PR 전체 변경" 행 = 끈 화면). 시험판 0.7.0 베타 1 의 네 번째 "커밋" 탭은 뺐다.
  GitHub 의 PR 커밋 목록은 250개에서 끊긴다. 앞에서(`first`) 받으면 오래된 250개만 와서 head 가 빠진다 —
  뒤에서(`last`·`before`) 받는다(실측: 커밋 849개 PR). 목록에 base 쪽 커밋은 없어서, 첫 부모가 PR 밖이면 맨 아래
  "분기점" 한 줄로 모으고, base 를 받아온 머지의 두 번째 부모는 레인을 열지 않는다(열면 끝나지 않는 선이 생긴다).
  머지 커밋 diff 는 GitHub 이 첫 부모 기준으로 준다(`commits/{머지}` == `compare/첫부모...머지`) — base 를 받아온
  머지면 받아온 변경이라 누를 때만 받는다. 여러 커밋 범위는 compare 라 사이에 그런 머지가 있으면 받아온 변경이 섞인다.
  화면 확인은 `PRAYER_DEMO=1` + `PRAYER_DEBUG_DETAIL_TAB=diff` + `PRAYER_DEBUG_DIFF_BY_COMMIT=1`(`DemoData.branchCommits`), 리뷰한 지점·선택은
  `PRAYER_DEBUG_COMMITS_REVIEWED`·`PRAYER_DEBUG_COMMITS_SELECT`(DebugLaunch).
- **리뷰 제외 규칙** — 잠금 파일 32종은 앱이 늘 뺀다(`LockFiles`). 그 밖의 규칙은 설정 › 대상 제외 칸에 사람이 적고,
  치는 동안 레포 파일 기준 자동완성이 뜬다(`ExclusionCatalog`, 2026-10-06 사용자 결정 — 베타 6 에서 칸을 없앴다가 되살림).
  후보는 `Glob` 이 읽는 꼴 그대로(`*.plist`·`*.xcassets/*`·`Pods/*`·`Package.resolved`, 특수 글자는 escape)이고,
  최근 PR 에서 자주 바뀐 것이 위로 온다. 재료는 탭을 열 때 받는다 — 기본 브랜치 트리(`git/trees/HEAD?recursive=1`,
  레포당 1.8초)와 최근 PR 50개의 바뀐 파일(GraphQL 한 번, 3초·비용 1). 후보 숫자는 `Glob` 으로 잰 수와 같아야 한다(테스트가 묶는다).
- **전체 리뷰 클론 = PR 스냅샷**(`ReviewClone`, 2026-10-06 사용자 결정). 레포마다 앱 데이터 폴더의
  `review-clones/<owner>/<name>` 에 가벼운 클론(`--filter=blob:none --no-checkout`)을 앱이 받는다 — 사용자가 클론
  폴더를 고르지 않는다(설정의 경로 칸·설정 공유의 클론 경로는 없앴다). 예전 버전에서 연결한 클론
  (`deepReviewRepoPaths`)은 그대로 쓰고, 끊거나 폴더가 사라지면 스냅샷으로 넘어간다. 처음 받기 전에는 확인 창을
  띄운다(`SnapshotCloneConfirm`). 받은 것은 자동으로 지우지 않는다(설정의 "지우기"로만). 실측(큰 레포):
  처음 클론 13초·65MB + 리뷰할 커밋의 파일 14~17초, 다음 PR 3~7초.
  - 인증은 gh 로: 클론 때 `-c credential.helper= -c credential.helper=!'<gh>' auth git-credential`, 그리고 클론
    안에도 같은 값을 적어 리뷰마다의 fetch 가 gh 로 붙는다(앞의 빈 값이 osxkeychain 같은 전역 도우미를 끊는다).
  - git 은 표준 오류가 터미널이 아니면 **진행을 안 찍는다** — 반드시 `--progress`. ProcessRunner 는 출력을 파일로
    받으므로 그 파일 끝을 0.3초마다 다시 읽는다(`GitProgressRunner`).
  - 체크아웃이 빠진 파일을 알아서 받게 두면 그동안 진행을 찍을 자리가 없다. `rev-list --missing=print` 로 빠진
    객체를 먼저 받고(`WorktreeManager.missingObjects`), 워크트리는 `add --no-checkout` 뒤 `checkout --progress`.
  - 받다 만 클론이 완성본처럼 보이지 않게 `<name>.cloning` 에 받고 끝에 이름을 바꾼다 — git 은 `.git` 을 맨 처음 만든다.
- **슬랙 리뷰 요청은 claude.ai Slack 커넥터로 보낸다**(`SlackConnector`). 앱은 슬랙 토큰을 받지 않고, 이 맥의
  `claude` 에 붙은 커넥터를 `claude -p` 로 빌린다 — MCP 도구는 모델만 부를 수 있어 호출마다 haiku 가 한 번 돈다(10초쯤).
  실측(CLI 2.1.284)으로 정한 것: `--safe-mode`·`--strict-mcp-config` 는 커넥터까지 끈다(못 쓴다). `-p` 는 claude.ai
  커넥터를 기다려 주지 않아(첫 턴에 `pending`) `MCP_CONNECTION_NONBLOCKING=false` 가 필요하고, 그러면 붙은 커넥터 전부의
  도구가 실려 20만 토큰을 넘으므로 `--settings` 의 `allowedMcpServers` 에 **서버 주소**(`https://mcp.slack.com/*`)로
  Slack 만 남긴다(서버 이름으로는 안 걸린다). 쓸 도구 하나만 `--allowedTools`, 나머지 Slack 도구는 `--disallowedTools`.
  모델이 글을 옮겨 적으므로 `PreToolUse` 훅(`SlackSendGuard`, `plutil`+`cmp`)이 앱이 만든 글·받는 곳과 바이트 단위로
  같을 때만, 한 번만 통과시킨다. 그래서 **보낼 글에 백슬래시 이스케이프(`\[`)를 넣지 않는다** — haiku 가 옮겨 적다
  떼어 훅이 막는다(2026-10-23 실측 2/2, 대괄호 제목 PR 이 전부 안 보내졌다). 고친 글에 섞인 링크 글자의 대괄호는 짝이
  맞으면 그대로, 안 맞는 것만 전각으로(`SlackTemplate.linkLabel`). 결과(채널 ID·메시지 주소)는 모델 답이 아니라 도구 결과 글에서
  읽는다. 커넥터로 보낸 글 끝에는 슬랙이 "Claude 를 사용하여 보냄" 을 붙인다(뺄 수 없다). 시험은 받는 곳 "나에게(DM)" 로 한다.
- **슬랙 글 형식은 고정이다**(2026-10-23 사용자 결정, `SlackTemplate.message`) — PR 주소 한 줄씩 + 맨 끝 "리뷰 부탁드립니다",
  링크 미리보기 켬. 팀 채널에서 사람들이 손으로 올리는 꼴 그대로다. 그 전의 칩 틀 편집(글 틀·PR 한 줄·포맷 화면·설정의 "메시지
  포맷")은 사람마다 글이 달라져서 뺐다 — 틀 고치기를 다시 넣지 않는다. 요청 창에서 이번 글만 손으로 고치는 것은 남겼다.
- **`Resources` 를 project.yml 에 넣는 방법**: 타깃 최상위 `resources:` 키는 xcodegen 에 없다.
  그렇게 쓰면 조용히 무시돼 `Contents/Resources` 가 통째로 빠지고 **모든 리뷰가 실패한다.**
  `- path: Resources` + `buildPhase: resources` 형태를 유지할 것.
- **파일을 새로 만들면 프로젝트를 다시 생성해야 한다.** `build.sh`·`test.sh` 가 파일 목록
  해시를 비교해 자동으로 해 주지만, 스탬프의 주인은 `gen.sh` 하나다. 수동으로
  `xcodegen` 을 직접 부르지 말 것 — 스탬프가 어긋나 이미 지운 파일을 참조하게 된다.
- **리뷰가 도는 중에 `Resources/review.md` 를 고치지 마라.** 엔진이 프롬프트를 파일 경로로 넘겨
  리뷰마다 실행 시점에 읽는다. 배치 도중에 고치면 앞뒤 리뷰가 서로 다른 프롬프트로 돈다.
- **프롬프트의 예시가 곧 지시다.** 나쁜 예를 글자 그대로 적으면 그 말을 오히려 심는다(실측:
  ✗ 로 막은 문장을 모델이 거의 그대로 냈다). 새 예시는 실제 PR 과 다른 소재로 쓴다 — 같은 소재면
  다음 채점에서 베껴 통과한다. 규칙 하나를 고치면 다른 데서 새 꼴이 나오니 매번 다시 잰다.
- **`AppInfo.markerPrefix` 는 `"prdeck"` 이다. 바꾸지 마라.** 이미 GitHub 에 올라간 리뷰
  코멘트에 `<!-- prdeck:v1:… -->` 가 박혀 있고, "이건 우리가 올린 글" 판정이 이걸 본다.
  바꾸면 예전에 올린 리뷰가 남이 쓴 새 코멘트로 잡힌다(테스트가 이 계약을 지킨다).
- **화면 이름 `PRView` 는 `Resources/en.lproj/InfoPlist.strings` 에 있다.** 앱 메뉴·Dock·⌘Tab·
  Finder 가 여기서 읽는다. project.yml 의 `INFOPLIST_KEY_CFBundleDisplayName` 은 **파일 이름
  (`PRayer`)과 같아야 한다** — 다르면 Finder 가 현지화 이름을 버리고 파일 이름을 보인다(실측).
  그래서 파일은 `PRayer.app` 인 채로 Finder·Dock 에는 PRView 가 뜬다.
  `INFOPLIST_KEY_CFBundleName`·`INFOPLIST_KEY_LSHasLocalizedDisplayName` 은 조용히 무시돼서
  `Config/PRayer-Info.plist` 로 넣는다. 파일·번들·실행 파일 이름에는 이모지를 넣지 않는다(경로다).
  앱 안의 문구는 `AppInfo.displayName` 을 쓴다.
- **보이는 이름만 PRView 다(2026-10-20 PRayer 에서 바꿈). 속 이름은 PRayer 그대로 둔다** — 번들 ID
  `dev.itaehyeok.PRayer`, 파일·실행 파일 `PRayer.app`, 데이터 폴더 `PRayer`(`AppInfo.name`), 모듈·타깃 이름. 깔린 앱의 업데이트는 zip 안의 `PRayer.app` 을 찾고 번들 ID 가 같아야
  바꿔 끼운다 — 하나라도 바꾸면 깔린 앱이 새 버전을 못 받는다. 속 이름까지 바꾸려면 옛 이름으로 한 번 더 내는
  다리 버전과 `LegacyMigration` 확장(데이터 폴더·UserDefaults)이 먼저다.
- **소스·베타·배포본은 이 저장소 하나(`itaehyeok/PRView`)에 있다**(2026-10-30 소스 공개 — 그 전엔 비공개 소스
  저장소 + 배포 전용 공개 저장소였다). 앱(`UpdateCheck.repo`)과 setup.sh 가 여기에 새 버전을 묻는다. zip 이름은
  `PRView-<버전>.zip`(`UpdateCheck.assetName`, setup.sh `ZIP_PREFIX`, release.sh `PUBLIC_ZIP_PREFIX` 가 같아야 한다),
  안은 `PRayer.app`. 베타는 같은 저장소의 시험판이다 — 앱 업데이트·setup.sh 는 시험판을 고르지 않는다.
  0.6.0~0.6.3 앱은 `terry-yes/PRView` 에 묻고 asset 주소가 정확히 그 저장소 경로인지 검사한다 — 저장소를 옮기거나
  이름을 바꾸면 주소가 바뀌어 업데이트가 끊긴다. 그래서 release.sh 가 공개할 때 그쪽에도 같은 zip 을 올린다
  (`BRIDGE_REPO`, 다리 — 그 저장소 주인 계정 토큰). 0.5.x 이하 앱은 옛 `itaehyeok/PRayer` 를 보는데, 그 저장소가 이 저장소로
  이름이 바뀌어 asset 주소가 달라져 업데이트가 끊겼다(사용자가 감수 — setup.sh 로 다시 깔면 된다).
- **이름 옆 한 줄 설명 `PR Review Manager` 는 `AppInfo.subtitle`.** 정보 창(About)·온보딩 첫 화면·
  상태 팝오버에만 붙인다. 창 제목은 이름만(설명을 붙였다가 사용자가 "별로다" 해서 뺐다, 2026-10-20).
  앱 메뉴·Dock·Finder 이름(InfoPlist.strings)에는 넣지 않는다 — 길어서 잘리고,
  Finder 이름은 파일 이름과 같아야 한다. 저장소 설명과 다리 저장소의 README 는 release.sh 가 안 건드리므로 손으로 맞춘다.
- **`LegacyMigration` 의 옛 이름 목록을 지우지 마라.** 아직 새 앱을 켜지 않은 맥의 데이터 폴더·
  로그·UserDefaults 를 옮기는 데 쓴다. 이전은 앱 `init()` **맨 앞에서** 한 번 한다 — 예전처럼
  `AppPaths.support` 안에서 하면 경로만 계산하는 테스트도 폴더를 옮기고, 옛 앱이 떠 있으면 그
  앱의 데이터 폴더가 발밑에서 사라진다. 새 폴더가 먼저 생겨 있어도(로그·테스트가 만든 빈 껍데기)
  설정 파일이 없으면 안으로 옮겨 담는다.
- **`~/Applications` 에서 실행해야 알림이 온다.** DerivedData 경로에서 직접 띄우면
  알림 등록이 안 된다.
- **받은 zip 을 다운로드 폴더에서 바로 열면 macOS 가 앱을 읽기 전용 임시 위치에서 실행한다**
  (App Translocation). 그 옆에는 새 버전을 놓을 수 없어 팀원 업데이트가 막혔다(2026-10-01).
  켤 때 "응용 프로그램 폴더로 옮길까요?"(`AppMover`)를 묻고, 안 옮긴 채 업데이트하면 응용 프로그램
  폴더로 옮겨 깐다(`UpdateInstallTarget.plan`). 원래 앱은 **새 자리에서, 기록해 둔 버전으로 켜졌을
  때만** 치운다 — 교체가 안 됐는데 지우면 쓸 앱이 없어진다. 개발 빌드(DEBUG)에서는 묻지 않는다.
  실측법(v0.4.10 에서 끝까지 확인): **공증된** 빌드에 `xattr -w com.apple.quarantine "00c1;<16진 시각>;Safari;"`
  를 붙여 `open` 하면 Gatekeeper 확인 창 없이 격리 실행된다(00c1 = 열기를 허락한 딱지, 01c1 = Finder 로 옮긴
  딱지는 격리 대상이 아니다 — `SecTranslocateURLShouldRunTranslocated` 로 확인). 옮기기 창은
  `defaults write dev.itaehyeok.PRayer moveToApplicationsAnswer -string move` 로 넘기고 끝나면 지운다.
  같은 번들 ID 가 떠 있으면 `open` 이 그 앱을 앞으로 가져올 뿐이라, 다른 PRayer(작업본 포함)는 먼저 꺼야 한다.
- **App Sandbox 는 꺼져 있어야 한다** — `claude`·`gh` 를 실행해야 하기 때문.
- **`@Environment` 를 읽는 뷰를 다른 뷰의 계산 프로퍼티에서 손으로 만들지 마라.**
  SwiftUI 가 환경을 심어 주지 않아 읽는 순간 죽는다(실측 크래시).
- **행 뷰에서 모델 데이터를 `@State` 로 복사하지 마라.** ForEach 식별자가 같으면
  SwiftUI 가 뷰를 재사용해 `onAppear` 가 다시 불리지 않고, 옛 내용이 남는다.
- **한글을 `gh` 인자(`-f key=값`)로 넘기지 마라.** Foundation `Process` 가 인자를 NFD(자모)로 바꿔 넘겨, 한글 검색어가
  GitHub 에서 0건이 된다(2026-10-29 실측: 같은 한글 검색어가 터미널 gh 328건 · 앱 0건). 글을 실어 보내는 호출은 본문을 표준 입력
  (`--input -`)으로 넘긴다 — GraphQL 은 `GitHubClient.graphQLRequest` 가 영문이 아닌 변수가 있으면 알아서 그렇게 한다.
- **기간 없는 PR 검색은 한 요청 25건까지.** 오래된 PR(코멘트·커밋이 많다)이 섞이면 목록 필드로 50건을 받을 때 GitHub 이
  11초 만에 502 로 끊는다(25건 9초 · 15건 5초). 목록 검색칸의 전체 PR 검색(`AppModel+Search`)은 25건씩 두 번 받는다.

## 원칙

- 초안은 **로컬에만** 저장한다. 사용자가 "게시" 를 누를 때만 GitHub 에 올라간다.
  **자동 게시 경로를 만들지 마라.**
- Claude 프로세스에 도구를 주지 않는다(`--tools ""`). 전체 리뷰에서만 읽기 전용
  `Read`/`Grep`/`Glob` 을 연다. 자식 환경에서 GitHub 토큰을 제거한다.
- **본 리뷰만 대화를 남긴다**(`persistSession`, 2026-10-06 사용자 결정). 리뷰 맨 아래 "Claude 에서 이어서
  대화하기" 가 `claude --resume <ID>` 를 복사하게 해, 사용자가 리뷰한 그 대화를 터미널·Paseo 등에서 이어 간다.
  실측(CLI 2.1.284): 대화를 만든 폴더가 아니어도 ID 로 열리고(그래서 명령에 `cd` 가 없다 — 워크트리가 정리돼도
  된다), 리뷰 때의 시스템 프롬프트가 따라와 이어 간 대화도 리뷰 문체의 글로 답한다(JSON 아님). 설명·대조·
  재확인·모델 확인은 `--no-session-persistence` 그대로 둔다 — 남기면 사용자의 `--resume` 목록이 앱이 부른
  짧은 대화로 덮인다. ID 는 CLI 결과 JSON 에서 읽은 바깥 값이라 UUID 로 검사한 뒤에만 명령에 넣는다(`ClaudeSession`).
- 앱은 비밀번호·토큰을 입력받지 않는다. 슬랙도 마찬가지다 — claude.ai 커넥터를 빌린다(위 함정).
- 슬랙 글도 **사용자가 "보내기" 를 누를 때만** 간다. 디버그 훅(`DebugLaunch`)도 창을 띄우고 검색까지만 한다.
- 주석은 한국어로, **왜 그렇게 했는지**를 적는다. 무엇을 하는지는 코드가 말한다.
- **모델 출력(`ReviewRecord.output`)은 고치지 않는다.** 사용자가 리뷰 본문에서 고친 글(요약·잘된 점·우려사항
  제목·질문)은 `textEdits`(`ReviewTextEdits`)에 따로 두고, 게시 본문·"요약과 함께 Approve"·인라인으로 옮기기가
  `effectiveSummary`·`text(for:)` 로 읽는다. 질문 키가 문장의 해시라 원문을 바꾸면 정리 표시 같은 항목 상태를 잃고,
  "Claude 원문으로" 되돌릴 자리도 남아야 한다. 고치기는 "수정" 버튼으로만 연다(글자 클릭 편집은 코드 링크와 겹친다).
- 모델이 만든 결과를 화면에 그릴 때는 근거 없는 단정을 만들지 않는다.
  근거를 못 찾으면 "못 찾았다" 고 말하게 한다.
