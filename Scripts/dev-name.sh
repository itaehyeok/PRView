#!/bin/bash
# 개발 빌드(곁가지 작업본·세션 확인용 사본)의 보이는 이름을 "PRView - <작업 이름>" 으로 바꾼다.
# 여러 세션이 빌드를 띄우면 Dock·⌘Tab·앱 메뉴에 전부 "PRView" 로 떠서 어느 게 어느 작업인지
# 사용자가 못 가른다(2026-10-22 사용자 요청).
#
# 쓰는 법: bash Scripts/dev-name.sh <앱 경로> <작업 이름>
#   파일 이름까지 바꾸고, 바뀐 앱 경로를 마지막 줄에 찍는다.
#   번들 ID·데이터 폴더는 건드리지 않는다 — 부르는 쪽이 먼저 바꾸고, 재서명은 여기서 끝에 한 번 한다.
set -uo pipefail
APP="${1:-}"
LABEL="${2:-}"
if [ ! -d "$APP" ] || [ -z "$LABEL" ]; then
  echo "쓰는 법: bash Scripts/dev-name.sh <앱 경로> <작업 이름>" >&2
  exit 1
fi
# 작업 이름은 파일 이름이자 .strings 따옴표 안의 값이다. 경로를 가르는 글자와 따옴표는 받지 않는다.
case "$LABEL" in
  */* | *:* | *\"* | *\\*)
    echo "❌ 작업 이름에 / : \" \\ 는 쓸 수 없습니다: $LABEL" >&2
    exit 1
    ;;
esac
NAME="PRView - $LABEL"
APP="${APP%/}"
DEST="$(dirname "$APP")/$NAME.app"

# 네 군데(파일 이름·CFBundleName·CFBundleDisplayName·InfoPlist.strings)가 모두 같아야 한다.
# Info.plist 의 CFBundleDisplayName 이 파일 이름과 다르면 Finder·Dock 이 현지화 이름을 버리고
# 파일 이름을 보이고, InfoPlist.strings 를 그대로 두면 앱 메뉴·⌘Tab 에 원래 이름 "PRView" 가 뜬다(실측).
# 같은 파일인지는 문자열이 아니라 -ef 로 본다. 한글 경로는 NFC·NFD 가 섞여 글자가 달라도 같은 파일일 수
# 있는데, 다르다고 보고 지우면 옮길 앱 자체가 지워진다.
if ! [ "$APP" -ef "$DEST" ]; then
  rm -rf "$DEST"
  mv "$APP" "$DEST" || exit 1
fi
PLIST="$DEST/Contents/Info.plist"
plutil -replace CFBundleName -string "$NAME" "$PLIST" || exit 1
plutil -replace CFBundleDisplayName -string "$NAME" "$PLIST" || exit 1
# .strings 는 OpenStep 형식이라 plutil 로 고쳐 쓸 수 없다 — 통째로 다시 쓴다(UTF-8 이어도 읽는다).
write_strings() {
  printf '/* dev-name.sh 가 붙인 개발 빌드 이름. */\nCFBundleName = "%s";\nCFBundleDisplayName = "%s";\n' \
    "$NAME" "$NAME" >"$1"
}
STRINGS_FOUND=0
for STRINGS in "$DEST"/Contents/Resources/*.lproj/InfoPlist.strings; do
  [ -f "$STRINGS" ] || continue
  STRINGS_FOUND=1
  write_strings "$STRINGS"
done
if [ "$STRINGS_FOUND" = 0 ]; then
  mkdir -p "$DEST/Contents/Resources/en.lproj"
  write_strings "$DEST/Contents/Resources/en.lproj/InfoPlist.strings"
fi
# 번들 안을 고쳤으니 서명을 다시 한다(고치면 서명이 깨져 실행이 막힌다).
codesign --force --deep --sign - "$DEST" >/dev/null 2>&1 || {
  echo "❌ 재서명 실패: $DEST" >&2
  exit 1
}
# LaunchServices 가 옛 이름을 기억하고 있으면 Dock·Finder 에 한동안 옛 이름이 남는다.
/System/Library/Frameworks/CoreServices.framework/Frameworks/LaunchServices.framework/Support/lsregister -f "$DEST" \
  >/dev/null 2>&1 || true
echo "$DEST"
