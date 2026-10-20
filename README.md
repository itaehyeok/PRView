# PRayer 🙏

> **이사했습니다** — PRayer 는 0.6.0 부터 이름을 **PRView** 로 바꾸고 [terry-yes/PRView](https://github.com/terry-yes/PRView) 에서 배포합니다.
> 이미 쓰고 있다면 앱에 뜨는 업데이트로 0.6.0 을 받으면 되고, 그 뒤 업데이트는 새 저장소에서 옵니다.
> 새로 설치할 때는 [새 저장소](https://github.com/terry-yes/PRView)의 설치 명령을 쓰세요. 아래 옛 명령도 새 저장소에서 받아 설치합니다.

팀 GitHub PR 을 한눈에 보고, **내 맥에 설치된 Claude Code** 로 리뷰 초안을 만들고,
내가 확인한 것만 GitHub 리뷰로 올리는 macOS 앱입니다.

이 저장소에는 **배포본만** 있습니다 — [릴리스](https://github.com/itaehyeok/PRayer/releases/latest)의 앱 zip 과 설치 스크립트.

## 설치 · 업데이트

터미널에 한 줄이면 `gh` 확인, 앱 내려받기, 설치까지 합니다. 업데이트도 같은 명령입니다.

```bash
curl -fsSL https://raw.githubusercontent.com/itaehyeok/PRayer/main/Scripts/setup.sh | bash
```

설치한 뒤에는 앱이 새 버전을 알려 줍니다.

- **0.4.0 이상** — 새 버전이 나오면 창 위에 안내가 뜹니다 → `앱에서 업데이트`
- **0.3.x** — 앱을 껐다 켠 뒤 툴바 `상태` → `앱에서 업데이트`

## 필요한 것

- macOS 14 이상, Apple Silicon
- [Claude Code](https://code.claude.com) 설치·로그인 — `claude auth login`
- [GitHub CLI](https://cli.github.com) 로그인 — `gh auth login`

앱은 토큰을 따로 저장하지 않고 이 맥의 `gh`·`claude` 로그인을 그대로 씁니다.
리뷰 초안은 이 맥에서만 만들어지고, 직접 게시 버튼을 눌러야 GitHub 에 올라갑니다.
