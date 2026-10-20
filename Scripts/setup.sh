#!/bin/bash
# PRView 설치·업데이트. 같은 명령으로 둘 다 된다.
#
#   curl -fsSL https://raw.githubusercontent.com/terry-yes/PRView/main/Scripts/setup.sh | bash
#
# 하는 일
#   1. gh · claude 가 있는지 보고, 없으면 깔아 준다(brew)
#   2. 최신 릴리스를 받아 ~/Applications/PRayer.app 에 놓는다
#   3. 로그인이 안 돼 있으면 그 명령을 알려 준다
#
# 이미 깔려 있으면 버전만 견줘서 새 것일 때만 바꾼다.
set -uo pipefail

# 0.6.0 부터 배포처(2026-10-20 이사). 옛 저장소 itaehyeok/PRayer 에도 이 스크립트를 올려 두므로
# 옛 한 줄 명령으로 실행해도 여기서 받는다.
REPO="terry-yes/PRView"
# 화면에 보이는 이름. 앱 파일 이름은 PRayer.app 그대로다 — 깔린 앱의 업데이트가 그 이름을 찾는다.
NAME="PRView"
ZIP_PREFIX="PRView"
APP="$HOME/Applications/PRayer.app"
# 이름을 바꾸기 전 앱. 남겨 두면 Launchpad·Spotlight 에 옛 이름이 계속 뜨고, 둘을 같이 켜면
# 같은 데이터를 서로 덮어쓴다. 데이터 폴더·설정은 새 앱이 처음 켤 때 스스로 옮긴다.
LEGACY_APP="$HOME/Applications/PRMap.app"
LEGACY_PROCESS="PRMap.app/Contents/MacOS/PRMap"
TMP="$(mktemp -d -t prayer-setup)"
trap 'rm -rf "$TMP"' EXIT

ok()   { printf '  \033[32m✓\033[0m %s\n' "$1"; }
warn() { printf '  \033[33m!\033[0m %s\n' "$1"; }
bad()  { printf '  \033[31m✗\033[0m %s\n' "$1"; }
step() { printf '\n\033[1m%s\033[0m\n' "$1"; }

[ "$(uname -s)" = "Darwin" ] || { bad "macOS 전용입니다."; exit 1; }

# ─────────────────────────────────────────────── 1. 딸린 것
step "1/3  필요한 것 확인"

have() { command -v "$1" >/dev/null 2>&1; }

BREW="$(command -v brew || true)"
install_with_brew() {
  if [ -z "$BREW" ]; then
    bad "$1 이 없고 Homebrew 도 없습니다."
    echo "      먼저 Homebrew 를 깔고 다시 실행하세요: https://brew.sh"
    return 1
  fi
  echo "      brew install $1"
  "$BREW" install "$1" >/dev/null 2>&1 || { bad "$1 설치 실패 — 터미널에서 직접 해 보세요: brew install $1"; return 1; }
  return 0
}

MISSING=0
if have gh; then ok "gh $(gh --version | head -1 | awk '{print $3}')"
else warn "gh 없음 — 깝니다"; install_with_brew gh && ok "gh 설치됨" || MISSING=1; fi

# claude 는 Anthropic 배포라 brew 공식 포뮬러가 아니다. 안내만 한다.
if have claude; then ok "claude $(claude --version 2>/dev/null | head -1)"
else
  bad "claude 없음"
  echo "      $NAME 는 이 맥의 Claude Code 로 리뷰 초안을 만듭니다. 먼저 까세요:"
  echo "      https://claude.com/claude-code"
  MISSING=1
fi
[ "$MISSING" = 0 ] || { echo; bad "빠진 것을 채우고 다시 실행하세요."; exit 1; }

# ─────────────────────────────────────────────── 2. 앱
step "2/3  $NAME 받기"

# 최신 버전은 API 가 아니라 github.com 의 "최신 릴리스" 이동 주소에서 읽는다. 로그인 없는 API 는
# IP 하나에 시간당 60번이라, 회사처럼 여럿이 한 IP 를 쓰면 금방 막힌다(실측: 403 rate limit exceeded).
LATEST_PAGE="$(curl -fsSLI -o /dev/null -w '%{url_effective}' "https://github.com/$REPO/releases/latest" 2>/dev/null)" \
  || { bad "릴리스 정보를 받지 못했습니다."; exit 1; }
# 릴리스가 하나도 없으면 태그 페이지가 아니라 릴리스 목록으로 간다.
TAG="${LATEST_PAGE##*/releases/tag/}"
case "$TAG" in
  v[0-9]*) ;;
  *) bad "받을 릴리스를 찾지 못했습니다. 릴리스가 올라와 있나요?"; exit 1 ;;
esac
LATEST="${TAG#v}"
# 배포 스크립트(release.sh)가 PRView-<버전>.zip 이름으로 올린다(안에는 PRayer.app).
URL="https://github.com/$REPO/releases/download/$TAG/$ZIP_PREFIX-$LATEST.zip"

CURRENT=""
[ -d "$APP" ] && CURRENT="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null || true)"
# 새 이름으로는 처음이어도 옛 이름으로 깔려 있었다면 업데이트로 보여 준다.
[ -z "$CURRENT" ] && [ -d "$LEGACY_APP" ] \
  && CURRENT="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$LEGACY_APP/Contents/Info.plist" 2>/dev/null || true)"

if [ "$CURRENT" = "$LATEST" ] && [ -d "$APP" ]; then
  ok "이미 최신입니다 (v$LATEST)"
  step "3/3  로그인 확인"
else
  [ -n "$CURRENT" ] && echo "      v$CURRENT → v$LATEST" || echo "      v$LATEST 처음 설치"
  # curl 로 받은 파일에는 격리 딱지(com.apple.quarantine)가 붙지 않는다.
  # 그래서 공증 전이어도 Gatekeeper 가 막지 않는다(브라우저로 받으면 막힌다).
  curl -fsSL "$URL" -o "$TMP/PRayer.zip" || { bad "내려받기 실패"; exit 1; }
  ditto -x -k "$TMP/PRayer.zip" "$TMP/unpacked" || { bad "압축 풀기 실패"; exit 1; }
  [ -d "$TMP/unpacked/PRayer.app" ] || { bad "zip 안에 PRayer.app 이 없습니다."; exit 1; }

  # 실행 중이면 내린다. 안 내리고 바꾸면 돌던 앱이 이상하게 죽는다.
  # 옛 이름 앱도 내린다 — 떠 있는 채로 새 앱이 데이터 폴더를 옮기면 그 앱의 발밑이 사라진다.
  pkill -f "PRayer.app/Contents/MacOS/PRayer" 2>/dev/null && sleep 1
  pkill -f "$LEGACY_PROCESS" 2>/dev/null && sleep 1
  mkdir -p "$HOME/Applications"
  rm -rf "$APP"
  cp -R "$TMP/unpacked/PRayer.app" "$APP" || { bad "설치 실패"; exit 1; }
  ok "설치: $APP"

  if codesign --verify --deep --strict "$APP" >/dev/null 2>&1; then
    ok "서명 확인"
  else
    warn "서명 확인 실패 — 열리지 않으면 우클릭 → 열기 로 한 번 허용하세요."
  fi

  step "3/3  로그인 확인"
fi

if [ -d "$LEGACY_APP" ]; then
  pkill -f "$LEGACY_PROCESS" 2>/dev/null && sleep 1
  rm -rf "$LEGACY_APP"
  ok "이전 이름으로 깔린 앱을 정리했습니다 (Dock 에 고정해 둔 옛 아이콘은 빼고 새 앱을 고정하세요)"
fi

# ─────────────────────────────────────────────── 3. 로그인
NEED_LOGIN=0
if gh auth status >/dev/null 2>&1; then
  ok "GitHub: $(gh auth status 2>&1 | sed -n 's/.*account \([^ ]*\).*/\1/p' | head -1)"
else
  warn "GitHub 로그인이 필요합니다:  gh auth login"
  echo "      회사 GitHub 이면:        gh auth login --hostname github.회사.com"
  NEED_LOGIN=1
fi

# claude 로그인 여부는 조회 명령이 대화형이라 여기서 확정하지 않는다. 앱이 켤 때 확인해 준다.
echo "      Claude 로그인이 안 돼 있으면 앱이 알려 줍니다 (claude auth login)"

echo
if [ "$NEED_LOGIN" = 0 ]; then
  echo "🎉 준비 끝. 앱을 엽니다."
  open "$APP"
else
  echo "위 로그인을 마친 뒤 앱을 여세요:  open \"$APP\""
fi
echo
echo "다음에 업데이트할 때도 같은 명령을 그대로 쓰면 됩니다."
