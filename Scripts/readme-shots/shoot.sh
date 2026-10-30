#!/bin/bash
# README 의 화면 5장(docs/screenshots)을 데모 데이터로 다시 찍는다.
#
#   bash Scripts/readme-shots/shoot.sh                    # 빌드 → 앱 사본 → 5장 → build/readme-shots/shots/
#   bash Scripts/readme-shots/shoot.sh --out docs/screenshots
#   bash Scripts/readme-shots/shoot.sh review files       # 몇 장만 (list·overview·review·review-clean·files)
#   bash Scripts/readme-shots/shoot.sh --no-build         # 지금 빌드(build/…/Debug/PRayer.app)를 그대로 쓴다
#   APPEARANCE=dark … / SIZE=1440x900 …                   # 다크 모드로 / 다른 창 크기(pt)로
#
# 데모 데이터는 DEBUG 빌드에만 있다(Sources/PRayer/Support/DemoData.swift, PRAYER_DEMO=1).
# 앱은 번들 ID·데이터 폴더를 바꾼 사본을 ad-hoc 서명해 뒤에서(open -g) 띄운다 — 켜 둔 PRView·실제 초안과
# 섞이지 않고, 치던 글자를 가로채지 않는다. 창째 캡처(screencapture -l)라 가려져 있어도 되지만
# 이 셸을 띄운 앱에 화면 기록 권한이 있어야 한다. 끝나면 사본의 데이터 폴더·설정을 지운다.
set -uo pipefail
cd "$(cd "$(dirname "$0")/../.." && pwd -P)"

WORK="$PWD/build/readme-shots"
OUT="$WORK/shots"
BUILD=1
NAMES=()
while [ $# -gt 0 ]; do
  case "$1" in
    --out) OUT="${2:?--out 뒤에 폴더가 필요합니다}"; shift 2 ;;
    --no-build) BUILD=0; shift ;;
    -h|--help) sed -n '2,13p' "$0"; exit 0 ;;
    -*) echo "모르는 옵션: $1" >&2; exit 2 ;;
    *) NAMES+=("$1"); shift ;;
  esac
done

# 창 틀 크기(pt, 제목 막대 포함). Retina 화면에서 3440x2100 PNG — 지금 README 그림과 같다.
SIZE="${SIZE:-1720x1050}"
APPEARANCE="${APPEARANCE:-light}"
BUNDLE_ID="dev.itaehyeok.PRayer.readmeshots"
DATA_DIR="PRayer-readmeshots"
APP="$WORK/PRView-shots.app"
WINLIST="$WORK/winlist"
BORDER="$WORK/border"

# 이름 | 고를 PR | 탭 | 그 장만 더 기다릴 초 | 그 장에만 줄 환경 변수
# files 는 AI 리뷰 탭에서 첫 코드 코멘트를 따라 변경 파일 탭으로 넘어간 모양이다(PRDetailView.runDebugFollow, 2초 뒤).
SHOTS=(
  "list|acme/sample-ios#131|overview|0|"
  "overview|acme/sample-ios#128|overview|0|"
  "review|acme/sample-ios#128|review|0|"
  "review-clean|acme/sample-ios#133|review|0|"
  "files|acme/sample-ios#128|review|3|PRAYER_DEBUG_FOLLOW=0"
)
if [ ${#NAMES[@]} -gt 0 ]; then
  for n in "${NAMES[@]}"; do
    printf '%s\n' "${SHOTS[@]}" | grep -q "^$n|" || { echo "모르는 이름: $n (list·overview·review·review-clean·files)" >&2; exit 2; }
  done
fi

# MARK: 빌드·사본

if [ "$BUILD" = 1 ]; then
  bash Scripts/build.sh || exit 1
fi
SRC="build/Build/Products/Debug/PRayer.app"
[ -d "$SRC" ] || { echo "❌ $SRC 가 없습니다 — --no-build 를 빼고 다시" >&2; exit 1; }
mkdir -p "$WORK" "$OUT"
rm -rf "$APP"
ditto "$SRC" "$APP"
plutil -replace CFBundleIdentifier -string "$BUNDLE_ID" "$APP/Contents/Info.plist"
plutil -replace PRayerDataDirectory -string "$DATA_DIR" "$APP/Contents/Info.plist"
codesign --force --deep -s - "$APP" 2>/dev/null || { echo "❌ 사본 재서명 실패" >&2; exit 1; }
if [ ! -x "$WINLIST" ] || [ Scripts/readme-shots/winlist.swift -nt "$WINLIST" ]; then
  swiftc -O -o "$WINLIST" Scripts/readme-shots/winlist.swift || exit 1
fi
if [ ! -x "$BORDER" ] || [ Scripts/readme-shots/border.swift -nt "$BORDER" ]; then
  swiftc -O -o "$BORDER" Scripts/readme-shots/border.swift || exit 1
fi

# MARK: 띄우기·찍기

# 사본만 끈다. 확인 창이 떠 있으면 정상 종료가 안 먹어서 끝까지 안 내려가면 kill -9.
stop_copy() {
  local pid
  pid="$("$WINLIST" "$BUNDLE_ID" | cut -d' ' -f1)" || return 0
  [ -n "$pid" ] || return 0
  kill "$pid" 2>/dev/null
  for _ in $(seq 25); do kill -0 "$pid" 2>/dev/null || return 0; sleep 0.2; done
  kill -9 "$pid" 2>/dev/null; sleep 0.5
}

cleanup() {
  stop_copy
  # 사본이 남긴 것만 지운다(번들 ID·데이터 폴더 이름이 이 스크립트 전용).
  rm -rf "$HOME/Library/Application Support/$DATA_DIR" \
         "$HOME/Library/Saved Application State/$BUNDLE_ID.savedState" \
         "$HOME/Library/Caches/$BUNDLE_ID" "$HOME/Library/HTTPStorages/$BUNDLE_ID"
  defaults delete "$BUNDLE_ID" >/dev/null 2>&1
  /System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -u "$APP" 2>/dev/null
}
trap cleanup EXIT

want_w="${SIZE%x*}"; want_h="${SIZE#*x}"
failed=0
for row in "${SHOTS[@]}"; do
  IFS='|' read -r name pr tab extra_wait extra_env <<<"$row"
  if [ ${#NAMES[@]} -gt 0 ] && ! printf '%s\n' "${NAMES[@]}" | grep -qx "$name"; then continue; fi
  stop_copy
  envs=(--env PRAYER_DEMO=1 --env "PRAYER_DEBUG_WINDOW_SIZE=$SIZE" --env "PRAYER_DEBUG_APPEARANCE=$APPEARANCE"
        --env "PRAYER_DEBUG_SELECT_PR=$pr" --env "PRAYER_DEBUG_DETAIL_TAB=$tab")
  [ -n "$extra_env" ] && envs+=(--env "$extra_env")
  open -n -g "${envs[@]}" "$APP"

  # 창이 뜨기를(최대 30초), 그다음 원하는 크기가 되기를(뜬 지 1초 뒤 DebugLaunch 가 맞춘다, 최대 5초) 기다린다.
  win=0; w=0; h=0
  for _ in $(seq 60); do
    read -r _ win w h < <("$WINLIST" "$BUNDLE_ID" || echo "0 0 0 0")
    [ "$win" != 0 ] && break
    sleep 0.5
  done
  for _ in $(seq 10); do
    [ "$win" = 0 ] || { [ "$w" = "$want_w" ] && [ "$h" = "$want_h" ]; } && break
    sleep 0.5
    read -r _ win w h < <("$WINLIST" "$BUNDLE_ID" || echo "0 0 0 0")
  done
  if [ "$win" = 0 ]; then
    echo "❌ $name: 창이 뜨지 않았습니다"; failed=1; continue
  fi
  [ "$w" = "$want_w" ] && [ "$h" = "$want_h" ] || echo "⚠️  $name: 창이 ${w}x${h} 입니다(원한 크기 $SIZE)"
  # 크기를 맞춘 4초 뒤에 PR 을 고른다(DebugLaunchModifier). 목록·본문이 다 그려질 때까지 조금 더.
  sleep $((6 + extra_wait))
  # 찍은 뒤 창 모양을 따라 얇은 회색 테두리를 두른다 — 흰 창이 GitHub 흰 바탕에 묻히지 않게(border.swift).
  if screencapture -x -o -l"$win" "$OUT/$name.png" && "$BORDER" "$OUT/$name.png"; then
    px="$(sips -g pixelWidth -g pixelHeight "$OUT/$name.png" | awk '/pixel/{print $2}' | paste -sd x -)"
    echo "📸 $name.png  $px"
  else
    echo "❌ $name: 캡처 실패 — 이 셸을 띄운 앱에 화면 기록 권한이 있는지 확인"; failed=1
  fi
done

echo "→ $OUT"
exit "$failed"
