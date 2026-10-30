#!/bin/bash
# 빌드해서 ~/Applications 에 설치한다. 알림은 여기서 실행할 때만 정상 동작한다.
# 쓰는 법: bash Scripts/install.sh ["작업 이름"]
#   곁가지 워크트리에서는 "PRView - <작업 이름>" 으로 깔린다(빼면 브랜치 끝 이름). 메인에서는 무시한다.
set -uo pipefail
# 물리 경로로 정규화해서 이동한다. `cd "$(dirname "$0")/.."` 로 두면 cwd 가
# `.../PRayer/Scripts/..` 형태가 되고, 그 경로로 만든 .xctestrun 을 xctest 가 해석하지 못해
# "Failed to create a bundle instance" 로 실패한다.
cd "$(cd "$(dirname "$0")/.." && pwd -P)"
# 곁가지 워크트리에서 설치하면 쓰고 있는 앱이 작업 중인 빌드로 바뀐다.
# 그래서 이름을 나눠 설치한다 — 둘을 나란히 두고 비교할 수도 있다.
# 메인 워크트리(= .git 이 디렉터리인 곳)에서만 원래 이름을 쓴다.
APP_NAME="PRayer"
# 작업본의 번들 ID. 진짜 앱과 갈라 두려고 아래에서 Info.plist 를 이 값으로 바꾼다.
WORK_BUNDLE_ID="dev.itaehyeok.PRayer.work"
# 이름을 바꾸기 전 앱. 남겨 두면 Launchpad 에 옛 이름이 계속 뜨고, 둘을 같이 켜면 같은 데이터를
# 서로 덮어쓴다. 데이터 폴더·설정은 새 앱이 처음 켤 때 스스로 옮긴다.
LEGACY_APP_NAME="PRMap"
IS_WORK=0
if [ -f .git ]; then
  IS_WORK=1
  # 세션 여럿이 번갈아 작업본을 깔아서, Dock·⌘Tab 이름만 보고도 지금 깔린 게 어느 작업인지 알아야 한다
  # (2026-10-22 사용자 요청 — 전에는 모두 "PRView 작업본" 이라 가를 수 없었다). 이름은 dev-name.sh 가 붙인다.
  LABEL="${1:-}"
  if [ -z "$LABEL" ]; then
    BRANCH="$(git branch --show-current)"
    LABEL="${BRANCH##*/}"
    [ -n "$LABEL" ] || LABEL="$(basename "$PWD")"
  fi
  # 빌드 전에 거른다 — dev-name.sh 도 같은 글자를 막지만 빌드가 끝난 뒤에야 알게 된다.
  case "$LABEL" in
    */* | *:* | *\"* | *\\*)
      echo "❌ 작업 이름에 / : \" \\ 는 쓸 수 없습니다: $LABEL" >&2
      exit 1
      ;;
  esac
  APP_NAME="PRView - $LABEL"
  LEGACY_APP_NAME="PRMap (작업본)"
  echo "ℹ️  곁가지 워크트리라 '$APP_NAME' 으로 설치합니다(쓰고 있는 앱은 그대로 둡니다)."
elif [ -n "${1:-}" ]; then
  echo "ℹ️  메인 체크아웃은 쓰고 있는 앱을 까는 곳이라 작업 이름('$1')을 붙이지 않습니다."
fi

./Scripts/build.sh || exit 1
mkdir -p "$HOME/Applications"
# 실행 중이면 교체 전에 내린다. 이름이 다르면 그쪽만 내린다.
if [ "$IS_WORK" = 0 ]; then
  pkill -f "$APP_NAME.app/Contents/MacOS/PRayer" 2>/dev/null && sleep 1
else
  # 작업본은 경로가 아니라 번들 ID 로 찾아 정상 종료한다. 경로로는 안 잡힌다 — 실행 중인 앱의 경로에는
  # "작업본" 이 한글 풀어쓴 꼴(NFD)로 들어 있어 이 스크립트의 글자(NFC)와 바이트가 다르고, 괄호는 pkill
  # 정규식의 묶음으로 읽힌다(실측). 못 내리면 번들만 바뀌고 open 이 떠 있던 옛 앱을 앞으로 가져와 옛 코드가 계속 돈다.
  running_work() {
    [ "$(osascript -l JavaScript -e "ObjC.import('AppKit'); \$.NSRunningApplication.runningApplicationsWithBundleIdentifier('$WORK_BUNDLE_ID').count" 2>/dev/null)" != "0" ]
  }
  if running_work; then
    echo "   떠 있는 작업본을 내립니다"
    osascript -l JavaScript -e "ObjC.import('AppKit');
      var apps = \$.NSRunningApplication.runningApplicationsWithBundleIdentifier('$WORK_BUNDLE_ID');
      for (var i = 0; i < apps.count; i++) { apps.objectAtIndex(i).terminate; }" >/dev/null 2>&1
    for _ in $(seq 1 100); do running_work || break; sleep 0.3; done
    if running_work; then
      # 30초가 지나도 떠 있으면 종료 확인 창(돌고 있는 리뷰)에서 멈춘 것이다. 사람이 고르게 둔다.
      echo "❌ 작업본이 꺼지지 않았습니다. 앱에 뜬 창을 확인하거나 직접 끈 뒤 다시 실행하세요." >&2
      exit 1
    fi
  fi
fi
pkill -f "$LEGACY_APP_NAME.app/Contents/MacOS/PRMap" 2>/dev/null && sleep 1
rm -rf "$HOME/Applications/$LEGACY_APP_NAME.app"
if [ "$IS_WORK" = 1 ]; then
  # 작업본 자리는 여전히 하나다(번들 ID 하나). 작업마다 파일 이름이 달라졌으니 전에 깔린 작업본은 이름이 아니라
  # 번들 ID 로 찾아 치운다 — 남기면 같은 번들 ID 앱이 여럿 생겨 open·알림이 엉뚱한 쪽으로 간다.
  # 이름을 붙이기 전 작업본("PRayer (작업본).app")도 같은 번들 ID 라 여기서 함께 치워진다.
  for OLD in "$HOME/Applications"/*.app; do
    [ "$(/usr/libexec/PlistBuddy -c 'Print :CFBundleIdentifier' "$OLD/Contents/Info.plist" 2>/dev/null)" = "$WORK_BUNDLE_ID" ] \
      && rm -rf "$OLD"
  done
fi
rm -rf "$HOME/Applications/$APP_NAME.app"
cp -R build/Build/Products/Debug/PRayer.app "$HOME/Applications/$APP_NAME.app"
if [ "$IS_WORK" = 1 ]; then
  # 작업본은 데이터 폴더와 번들 ID 를 갈라 둔다. 그러지 않으면 실제 초안·설정을
  # 같이 쓰게 되고, 두 앱을 동시에 켜면 같은 JSON 을 서로 덮어쓴다.
  PLIST="$HOME/Applications/$APP_NAME.app/Contents/Info.plist"
  /usr/libexec/PlistBuddy -c "Add :PRayerDataDirectory string PRayer-work" "$PLIST" >/dev/null 2>&1 \
    || /usr/libexec/PlistBuddy -c "Set :PRayerDataDirectory PRayer-work" "$PLIST"
  /usr/libexec/PlistBuddy -c "Set :CFBundleIdentifier $WORK_BUNDLE_ID" "$PLIST"
  # 보이는 이름 네 군데를 "PRView - <작업 이름>" 으로 맞추고 다시 서명한다(Info.plist 를 고치면 서명이 깨진다).
  bash Scripts/dev-name.sh "$HOME/Applications/$APP_NAME.app" "$LABEL" >/dev/null \
    && echo "   데이터 폴더: ~/Library/Application Support/PRayer-work (실제 데이터와 분리)" \
    || echo "   ⚠️  이름 붙이기·재서명 실패 — 작업본이 실행되지 않을 수 있습니다."
fi
echo "✅ 설치: $HOME/Applications/$APP_NAME.app"
echo "   첫 실행 때 알림 권한을 '허용' 하세요. (open \"$HOME/Applications/$APP_NAME.app\")"
