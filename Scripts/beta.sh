#!/bin/bash
# 저장소에 시험판으로 올린 베타를 이 맥에 깐다. 다른 베타로 되돌릴 때도 쓴다.
#
#   bash Scripts/beta.sh                  # 가장 새 베타
#   bash Scripts/beta.sh 0.5.0-beta.2     # 그 베타 (되돌리기: 앞 베타 이름을 준다)
#   bash Scripts/beta.sh 0.5.0            # 0.5.0 의 마지막 베타
#
# 베타는 `release.sh --beta` 로 올리고(번호 0.5.0-beta.N 은 그 스크립트가 매긴다), 써 보고 괜찮으면
# `release.sh 0.5.0 --promote` 로 같은 zip 을 정식 0.5.0 으로 올린다. 시험판이라 앱 업데이트·setup.sh 로는
# 다른 사람에게 가지 않는다. 정식 릴리스는 여기서 받지 않는다(그건 setup.sh).
set -uo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd -P)"

SOURCE_REPO="itaehyeok/PRView"
BUNDLE_ID="dev.itaehyeok.PRayer"
[ -f Local.env ] && . ./Local.env

# 주인 계정 토큰으로 묻는다(공개 저장소라 없어도 읽히지만, 로그인 없는 API 는 한도가 금방 찬다).
# gh 활성 계정은 바꾸지 않는다 — 켜 둔 앱이 그 계정으로 보던 PR 을 읽는다.
if [ -z "${GH_TOKEN:-}" ]; then
  GH_TOKEN="$(gh auth token --hostname github.com --user "${SOURCE_REPO%%/*}" 2>/dev/null || true)"
  export GH_TOKEN
fi

WANT="${1:-}"
if [ -n "$WANT" ] && ! printf '%s' "$WANT" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-beta\.[0-9]+)?$'; then
  echo "❌ 0.5.0-beta.2 나 0.5.0 처럼 주세요: $WANT" >&2
  exit 1
fi
# 받을 베타 이름(태그에서 v 를 뗀 것). 버전, 그다음 베타 번호로 줄 세운다 —
# 문자열로 견주면 beta.10 이 beta.9 보다 앞에 선다.
LABEL="$(gh release list -R "$SOURCE_REPO" --limit 50 --json tagName,isDraft \
    -q '.[] | select(.isDraft | not) | .tagName' 2>/dev/null \
  | python3 -c 'import re,sys
want = sys.argv[1]
rows = []
for line in sys.stdin:
    m = re.fullmatch(r"v(\d+)\.(\d+)\.(\d+)(?:-beta\.(\d+))?", line.strip())
    if not m:
        continue
    x, y, z, n = m.groups()
    if n is None:
        continue  # 정식 릴리스 — 베타만 받는다
    label = line.strip()[1:]
    if want and want != label and want != f"{x}.{y}.{z}":
        continue
    rows.append(((int(x), int(y), int(z), 1 if n is None else 0, int(n or 0)), label))
print(max(rows)[1] if rows else "")' "$WANT")"
[ -n "$LABEL" ] || { echo "❌ $SOURCE_REPO 에서 받을 베타를 찾지 못했습니다${WANT:+ ($WANT)}." >&2; exit 1; }

# 앱 → "0.5.0-beta.3" (번호가 없으면 "0.4.31"). 베타끼리는 앱 버전이 같아서 번호까지 봐야 같은 앱인지 안다.
label_of() {
  local version number
  version="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$1/Contents/Info.plist" 2>/dev/null || true)"
  number="$(/usr/libexec/PlistBuddy -c 'Print PRayerBetaNumber' "$1/Contents/Info.plist" 2>/dev/null || true)"
  [ -n "$version" ] || return 0
  if [ -n "$number" ]; then printf '%s-beta.%s' "$version" "$number"; else printf '%s' "$version"; fi
}
# "0.5.0-beta.3" → "v0.5.0 베타 3"
pretty() {
  case "$1" in
    *-beta.*) printf 'v%s 베타 %s' "${1%-beta.*}" "${1##*-beta.}" ;;
    "") printf '없음' ;;
    *) printf 'v%s' "$1" ;;
  esac
}

# 깔 자리 — 켜져 있는 앱의 자리, 없으면 /Applications → ~/Applications 순으로 있는 곳.
TARGET=""
for candidate in /Applications/PRayer.app "$HOME/Applications/PRayer.app"; do
  if pgrep -f "^$candidate/Contents/MacOS/PRayer" >/dev/null; then TARGET="$candidate"; break; fi
done
if [ -z "$TARGET" ]; then
  for candidate in /Applications/PRayer.app "$HOME/Applications/PRayer.app"; do
    [ -d "$candidate" ] && { TARGET="$candidate"; break; }
  done
fi
TARGET="${TARGET:-/Applications/PRayer.app}"
[ -w "$(dirname "$TARGET")" ] || { echo "❌ $(dirname "$TARGET") 에 쓸 수 없습니다." >&2; exit 1; }

CURRENT="$([ -d "$TARGET" ] && label_of "$TARGET")"
if [ "$CURRENT" = "$LABEL" ] && [ "${FORCE:-}" != "1" ]; then
  echo "✅ 이미 $(pretty "$LABEL") 입니다 ($TARGET). 다시 깔려면 FORCE=1 을 붙이세요."
  exit 0
fi
echo "📦 $(pretty "$CURRENT") → $(pretty "$LABEL")  ($TARGET)"

TMP="$(mktemp -d -t prayer-beta)"
trap 'rm -rf "$TMP"' EXIT
gh release download "v$LABEL" -R "$SOURCE_REPO" -p "PRayer-$LABEL.zip" -D "$TMP" >/dev/null \
  || { echo "❌ v$LABEL 을 받지 못했습니다." >&2; exit 1; }
ditto -x -k "$TMP/PRayer-$LABEL.zip" "$TMP/unpacked" || { echo "❌ 압축 풀기 실패" >&2; exit 1; }
NEW="$TMP/unpacked/PRayer.app"
[ -d "$NEW" ] || { echo "❌ zip 안에 PRayer.app 이 없습니다." >&2; exit 1; }

# 앱 안 업데이트와 같은 검사 — 같은 앱인가, 그 버전인가, 서명이 멀쩡하고 같은 팀인가.
plist() { /usr/libexec/PlistBuddy -c "Print $1" "$NEW/Contents/Info.plist" 2>/dev/null; }
[ "$(plist CFBundleIdentifier)" = "$BUNDLE_ID" ] || { echo "❌ 다른 앱입니다: $(plist CFBundleIdentifier)" >&2; exit 1; }
[ "$(label_of "$NEW")" = "$LABEL" ] || { echo "❌ 버전이 다릅니다: 기대 $(pretty "$LABEL") · 실제 $(pretty "$(label_of "$NEW")")" >&2; exit 1; }
codesign --verify --deep --strict "$NEW" 2>/dev/null || { echo "❌ 서명이 깨져 있습니다." >&2; exit 1; }
NEW_TEAM="$(codesign -dvvv "$NEW" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
EXPECT_TEAM="${PRAYER_TEAM_ID:-$(codesign -dvvv "$TARGET" 2>&1 | sed -n 's/^TeamIdentifier=//p')}"
if [ -z "$NEW_TEAM" ] || [ "$NEW_TEAM" != "$EXPECT_TEAM" ]; then
  echo "❌ 서명 팀이 다릅니다: ${NEW_TEAM:-없음} (기대 ${EXPECT_TEAM:-없음})" >&2
  exit 1
fi
echo "   검사 통과 — 팀 $NEW_TEAM · $(spctl -a -vv -t exec "$NEW" 2>&1 | sed -n 's/^source=//p')"

# 켜져 있으면 내린다. ⌘Q 와 같은 정상 종료를 먼저 보낸다 — 앱은 종료할 때 아직 디스크에 안 쓴
# 초안을 쓰는데(AppModel.teardown), kill 로 내리면 그걸 건너뛴다. 리뷰가 돌고 있으면 앱이 종료를
# 확인하는 창을 띄우므로 기다린다. 돌던 리뷰는 스풀에 남아 다시 켜면 결과를 가져온다.
running() { pgrep -f "^$TARGET/Contents/MacOS/PRayer" >/dev/null; }
wait_exit() {
  local tries="$1"
  for _ in $(seq 1 "$tries"); do running || return 0; sleep 0.3; done
  ! running
}
if running; then
  echo "   켜져 있는 앱을 내립니다"
  osascript -l JavaScript -e "ObjC.import('AppKit');
    var apps = \$.NSRunningApplication.runningApplicationsWithBundleIdentifier('$BUNDLE_ID');
    for (var i = 0; i < apps.count; i++) { apps.objectAtIndex(i).terminate; }" >/dev/null 2>&1 &
  if ! wait_exit 100; then
    # 30초가 지나도 떠 있으면 종료 확인 창에서 멈춘 것이다. 사람이 고르게 둔다.
    echo "❌ 앱이 꺼지지 않았습니다. 앱에 뜬 창을 확인하거나 직접 끈 뒤 다시 실행하세요." >&2
    exit 1
  fi
fi

# 옛 앱은 새 앱이 열릴 때까지 옆에 둔다. 새 앱이 안 열리면 그것으로 되돌린다.
BACKUP="${TARGET%.app}.previous.app"
rm -rf "$BACKUP"
if [ -d "$TARGET" ]; then
  mv "$TARGET" "$BACKUP" || { echo "❌ 기존 앱을 옮기지 못했습니다." >&2; exit 1; }
fi
if ! ditto "$NEW" "$TARGET"; then
  rm -rf "$TARGET"
  [ -d "$BACKUP" ] && mv "$BACKUP" "$TARGET"
  echo "❌ 설치 실패 — 원래 앱으로 되돌렸습니다." >&2
  exit 1
fi
if ! open "$TARGET"; then
  rm -rf "$TARGET"
  [ -d "$BACKUP" ] && mv "$BACKUP" "$TARGET" && open "$TARGET"
  echo "❌ 새 앱이 열리지 않아 원래 앱으로 되돌렸습니다." >&2
  exit 1
fi
rm -rf "$BACKUP"
echo "✅ $(pretty "$LABEL") 설치 — $TARGET"
[ -n "$CURRENT" ] && echo "   되돌리기: bash Scripts/beta.sh $CURRENT"
