#!/bin/bash
# 배포본을 만들어 GitHub Release 로 올린다.
#
# 버전 규칙(사용자 결정, 2026-10-02) — 베타는 **다음에 공개할 번호 + 베타 번호**로 낸다.
#   0.5.0-beta.1 → 0.5.0-beta.2 → … 를 이 맥에서 써 보다가, 마지막 베타를 그대로 공개 0.5.0 으로 올린다.
# 베타를 몇 번 내든 공개 번호는 따라 오르지 않는다. 예전에는 베타마다 0.4.12 … 0.4.31 로 올라서 다음 공개가
# 0.4.11 → 0.4.31 로 건너뛰게 돼 있었다. 베타 번호는 이 스크립트가 태그를 보고 매기므로, 여러 작업이 번갈아
# 베타를 내도 번호를 서로 맞출 필요가 없다. 지금 목표 번호는 project.yml 의 MARKETING_VERSION 이다.
#
#   bash Scripts/release.sh --beta                # 1) 다음 베타 — 지금 목표의 다음 번호(0.5.0-beta.N)
#   bash Scripts/beta.sh                          #    이 맥에 깔기
#   RELEASE_NOTES_FILE=notes.md bash Scripts/release.sh 0.5.0 --promote
#                                                 # 2) 0.5.0 의 마지막 베타 zip 을 그대로 공개 저장소에
#                                                 #    (특정 베타를 올리려면 0.5.0-beta.2 처럼 준다)
#   bash Scripts/release.sh 0.6.0 --beta          # 공개한 뒤 새 목표의 첫 베타 — 목표 번호는 사용자가 정한다
#   RELEASE_NOTES_FILE=notes.md bash Scripts/release.sh 0.5.1
#                                                 # 베타 없이 바로 공개(급한 수정)
#   bash Scripts/release.sh --beta --dry-run      # 올리지 않고 만들기만
#
# 여기서 만든 zip 을 Scripts/setup.sh 와 앱 안 업데이트가 받아서 설치·업데이트한다.
#
# 소스·베타·배포본은 공개 저장소 하나(itaehyeok/PRView, origin)에 있다(2026-10-30 소스 공개). 앱과 setup.sh 가
# 여기에 새 버전을 묻는다. 0.6.0~0.6.3 앱은 terry-yes/PRView 에 묻기 때문에, 공개할 때 거기에도 같은 zip 을
# 올린다(다리, BRIDGE_REPO) — 깔린 앱이 그걸로 올라오면 다음부터 여기를 본다.
#
# 베타는 이 저장소의 시험판(pre-release)이다. 누구나 볼 수 있지만 앱 업데이트·setup.sh 는 시험판을 고르지 않는다.
# 공개로 올릴 때(--promote)는 다시 빌드하지 않고 써 본 zip 을 그대로 옮긴다 — 다시 빌드하면
# 써 본 것과 모두가 받는 것이 달라진다. 그래서 앱 버전(CFBundleShortVersionString)에는 "-beta.N" 을
# 붙이지 않는다(애플 규칙도 숫자 세 자리다). 베타 번호는 Info.plist 의 PRayerBetaNumber 에 따로 박고,
# 앱은 공개 저장소에 그 버전이 있는지로 베타·정식을 가른다(UpdateCheck.publishState).
#
# 서명에 대해 — 이 스크립트는 **Developer ID** 로 서명한다. 개발용(Apple Development)
# 인증서로 서명한 앱은 만든 맥에서만 열린다. 남에게 주려면 Developer ID 여야 한다.
# 공증(notarize)은 자격 증명이 있을 때만 한다. 없어도 setup.sh 로 설치하면 열린다
# (curl 로 받은 파일에는 격리 딱지가 붙지 않는다). 다만 브라우저로 zip 을 직접
# 받으면 격리 딱지가 붙어 공증 없이는 Gatekeeper 가 막는다.
set -uo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd -P)"

VERSION=""
MODE=""
DRY_RUN=0
for arg in "$@"; do
  case "$arg" in
    --beta|--promote)
      [ -z "$MODE" ] || { echo "❌ --beta 와 --promote 는 하나만 줍니다." >&2; exit 1; }
      MODE="$arg" ;;
    --dry-run) DRY_RUN=1 ;;
    -*) echo "❌ 모르는 옵션입니다: $arg  (--beta · --promote · --dry-run)" >&2; exit 1 ;;
    *)
      [ -z "$VERSION" ] || { echo "❌ 버전은 하나만 줍니다: $VERSION · $arg" >&2; exit 1; }
      VERSION="$arg" ;;
  esac
done
if [ "$MODE" = "--promote" ]; then
  [ "$DRY_RUN" = 0 ] || { echo "❌ --promote 는 빌드하지 않아서 --dry-run 이 없습니다." >&2; exit 1; }
  if ! printf '%s' "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+(-beta\.[0-9]+)?$'; then
    echo "❌ 올릴 버전을 주세요.  예) release.sh 0.5.0 --promote  ·  release.sh 0.5.0-beta.2 --promote" >&2
    exit 1
  fi
elif [ -n "$VERSION" ] && ! printf '%s' "$VERSION" | grep -Eq '^[0-9]+\.[0-9]+\.[0-9]+$'; then
  echo "❌ 버전은 x.y.z 형식이어야 합니다: $VERSION (베타 번호는 스크립트가 매깁니다)" >&2
  exit 1
fi
if [ -z "$MODE" ] && [ "$DRY_RUN" = 0 ] && [ -z "$VERSION" ]; then
  echo "❌ 바로 공개할 버전이 필요합니다.  예) RELEASE_NOTES_FILE=notes.md bash Scripts/release.sh 0.5.1" >&2
  echo "   베타는:  bash Scripts/release.sh --beta" >&2
  exit 1
fi
# 받는 사람이 읽는 노트다. 커밋 제목을 이어 붙이면 개발 기록이 그대로 나가므로 직접 쓴 노트만 받는다.
# 몇 분 걸리는 공증 전에 멈춘다. 베타(시험판) 노트는 커밋 제목이어도 된다.
if { { [ -z "$MODE" ] && [ "$DRY_RUN" = 0 ]; } || [ "$MODE" = "--promote" ]; } \
  && { [ -z "${RELEASE_NOTES_FILE:-}" ] || [ ! -f "$RELEASE_NOTES_FILE" ]; }; then
  echo "❌ RELEASE_NOTES_FILE 로 배포 노트 파일을 주세요. 공개 저장소라 커밋 제목을 그대로 올리지 않습니다." >&2
  exit 1
fi

[ -f Local.env ] && . ./Local.env
TEAM_ID="${PRAYER_TEAM_ID:-}"
if [ -z "$TEAM_ID" ]; then
  echo "❌ Local.env 에 PRAYER_TEAM_ID 가 없습니다. 어느 팀으로 서명할지 정해야 합니다." >&2
  exit 1
fi
# 소스·베타·배포본을 두는 공개 저장소(2026-10-30 소스 공개). origin 이 이곳이어야 한다.
# 앱의 UpdateCheck.repo·assetName 과 setup.sh 의 REPO·ZIP_PREFIX 와 같아야 한다.
REPO="itaehyeok/PRView"
PUBLIC_ZIP_PREFIX="PRView"
# 다리 저장소. 0.6.0~0.6.3 앱은 여기서 PRView-<버전>.zip 을 찾고 asset 주소가 정확히 이 저장소인지도 본다.
# 공개할 때 여기에도 같은 zip 을 올려 깔린 앱이 새 버전으로 넘어오게 한다. 처음 설치 안내(README)도 여기 있다.
BRIDGE_REPO="terry-yes/PRView"
# 릴리스 제목에 쓰는 화면 이름. 실행 파일은 PRayer 그대로다(깔린 앱의 업데이트가 zip 안의 PRayer.app 을 찾는다).
DISPLAY_NAME="PRView"
EXEC_NAME="PRayer"
# 베타 번호는 origin 의 태그로 매기고, 커밋·태그도 origin 에 올린다. origin 이 이 저장소가 아니면 엉뚱한 곳을 본다.
ORIGIN_URL="$(git remote get-url origin 2>/dev/null || true)"
if [ "$DRY_RUN" = 0 ] && ! printf '%s' "$ORIGIN_URL" | grep -Eiq "[:/]${REPO}(\.git)?/?$"; then
  echo "❌ origin 이 $REPO 여야 합니다(지금: ${ORIGIN_URL:-없음})." >&2
  exit 1
fi
# 주인 계정 토큰으로 올린다. 이 맥의 gh 에는 다른 계정이 활성으로 같이 로그인돼 있어, 그대로 두면 맨 마지막
# 게시에서 실패했다(v0.4.28 실측: 빌드·공증·태그 push 까지 끝낸 뒤 "Could not resolve to a Repository").
# beta.sh 처럼 이 스크립트 안에서만 주인 계정 토큰을 쓴다 — `gh auth switch` 로 활성 계정을 바꾸면 켜 둔
# 앱이 그 계정으로 보던 PR 을 못 읽는다.
OWNER="${REPO%%/*}"
if [ "$DRY_RUN" = 0 ]; then
  if [ -z "${GH_TOKEN:-}" ]; then
    GH_TOKEN="$(gh auth token --hostname github.com --user "$OWNER" 2>/dev/null || true)"
    export GH_TOKEN
  fi
  # 몇 분 걸리는 빌드·공증 전에 확인한다. 토큰이 있어도 다른 계정 것이면 같은 자리에서 실패한다.
  if [ -z "${GH_TOKEN:-}" ] || ! gh api "repos/$REPO" --jq .full_name >/dev/null 2>&1; then
    echo "❌ gh 로 $REPO 에 접근할 수 없습니다 — $OWNER 계정이 gh 에 로그인돼 있어야 합니다." >&2
    echo "   gh auth login 으로 더하면 그 계정이 활성이 되니, 끝나면 gh auth switch 로 원래 계정을 되돌리세요." >&2
    exit 1
  fi
fi
# 다리 저장소는 주인이 다르다. 그 토큰은 다리에 올리는 자리에서만 쓴다. 바로 공개·승격일 때만
# 미리 확인한다(베타는 다리를 안 건드린다).
BRIDGE_TOKEN=""
if [ "$DRY_RUN" = 0 ] && [ "$MODE" != "--beta" ] && [ -n "$BRIDGE_REPO" ]; then
  BRIDGE_OWNER="${BRIDGE_REPO%%/*}"
  BRIDGE_TOKEN="${PRAYER_BRIDGE_GH_TOKEN:-$(gh auth token --hostname github.com --user "$BRIDGE_OWNER" 2>/dev/null || true)}"
  if [ -z "$BRIDGE_TOKEN" ] || ! GH_TOKEN="$BRIDGE_TOKEN" gh api "repos/$BRIDGE_REPO" --jq .full_name >/dev/null 2>&1; then
    echo "❌ gh 로 다리 저장소 $BRIDGE_REPO 에 접근할 수 없습니다 — $BRIDGE_OWNER 계정이 gh 에 로그인돼 있는지 보세요." >&2
    echo "   빠지면 0.6.0~0.6.3 앱이 새 버전을 못 받습니다." >&2
    exit 1
  fi
fi
# 공증 자격 증명의 키체인 이름. 다른 이름으로 저장해 뒀으면 Local.env 에 PRAYER_NOTARY_PROFILE 로 준다
# (다시 등록하려면 Apple ID 암호가 필요해서, 이름만 바꾸려고 새로 등록할 일은 아니다).
NOTARY_PROFILE="${PRAYER_NOTARY_PROFILE:-PRayer-notary}"

# ─────────────────────────────────────────────── 번호 정하기
# 다른 작업이 올린 베타 태그까지 보고 번호를 매긴다. 못 받으면 번호가 겹칠 수 있어 멈춘다.
if ! git fetch -q origin 'refs/tags/*:refs/tags/*' 2>/dev/null; then
  if [ "$DRY_RUN" = 0 ]; then
    echo "❌ origin 에서 태그를 받지 못했습니다 — 다른 작업이 올린 베타 번호를 모르면 번호가 겹칩니다." >&2
    exit 1
  fi
  echo "⚠️  origin 에서 태그를 받지 못했습니다. 이 클론의 태그로만 번호를 셉니다(--dry-run)."
fi
# x.y.z 를 숫자 단위로 견준다(앞이 크면 참). 문자열로 견주면 0.10.0 < 0.9.0 이 된다.
version_gt() {
  python3 -c 'import sys; f=lambda v: tuple(int(p) for p in v.split(".")); sys.exit(0 if f(sys.argv[1]) > f(sys.argv[2]) else 1)' "$1" "$2"
}
# 번호만 있는 태그(vX.Y.Z) = 이미 나간 번호 — 공개했거나, 바로 공개했거나, 이 방식 전의 베타(v0.4.12 … v0.4.31).
plain_tag_exists() { git rev-parse -q --verify "refs/tags/v$1" >/dev/null; }
max_plain_tag() {
  git tag -l 'v*' | python3 -c 'import re,sys
v=[tuple(map(int,m.groups())) for m in (re.fullmatch(r"v(\d+)\.(\d+)\.(\d+)", l.strip()) for l in sys.stdin) if m]
print(".".join(map(str,max(v))) if v else "0.0.0")'
}
# 그 버전에서 가장 큰 베타 번호. 없으면 0.
last_beta_number() {
  git tag -l "v$1-beta.*" | sed -n "s/^v${1//./\\.}-beta\.\([0-9][0-9]*\)$/\1/p" | sort -n | tail -1 | grep . || echo 0
}
TARGET_IN_YML="$(grep -E '^    MARKETING_VERSION:' project.yml | head -1 | tr -dc '0-9.')"

BETA_N=""
if [ "$MODE" = "--beta" ]; then
  if [ -z "$VERSION" ] || [ "$VERSION" = "$TARGET_IN_YML" ]; then
    VERSION="$TARGET_IN_YML"
    if plain_tag_exists "$VERSION"; then
      IFS=. read -r MAJOR MINOR PATCH <<< "$VERSION"
      echo "❌ 지금 목표 v$VERSION 은 이미 나간 번호입니다(공개했거나 예전 방식 베타)." >&2
      echo "   다음 목표를 정해 주세요 — 사용자 결정입니다:" >&2
      echo "     bash Scripts/release.sh $MAJOR.$MINOR.$((PATCH + 1)) --beta   # 작은 수정" >&2
      echo "     bash Scripts/release.sh $MAJOR.$((MINOR + 1)).0 --beta   # 기능 묶음" >&2
      exit 1
    fi
  else
    # 새 목표를 연다. 열린 목표가 있는데 다른 번호를 주면, 베타 번호를 맞추던 예전 습관(0.4.32 …)일
    # 가능성이 크다. 목표를 바꾸는 건 사용자가 정할 일이라 확인 없이는 받지 않는다.
    if ! plain_tag_exists "$TARGET_IN_YML" && [ "${PRAYER_RETARGET:-}" != "1" ]; then
      echo "❌ 지금 목표 v$TARGET_IN_YML 이 아직 공개 전입니다. 다음 베타는 버전 없이 냅니다:" >&2
      echo "     bash Scripts/release.sh --beta" >&2
      echo "   사용자가 목표를 바꾸기로 정했다면(→ v$VERSION) PRAYER_RETARGET=1 을 붙이세요." >&2
      exit 1
    fi
    if plain_tag_exists "$VERSION"; then
      echo "❌ v$VERSION 은 이미 나간 번호입니다." >&2
      exit 1
    fi
    MAX_PLAIN="$(max_plain_tag)"
    if ! version_gt "$VERSION" "$MAX_PLAIN"; then
      echo "❌ 새 목표는 이미 나간 가장 큰 번호 v$MAX_PLAIN 보다 커야 합니다: v$VERSION" >&2
      exit 1
    fi
  fi
  BETA_N="$(( $(last_beta_number "$VERSION") + 1 ))"
  LABEL="$VERSION-beta.$BETA_N"
  echo "🧪 v$LABEL — 목표 v$VERSION 의 베타 $BETA_N"
elif [ "$MODE" != "--promote" ]; then
  VERSION="${VERSION:-$TARGET_IN_YML}"
  if [ "$DRY_RUN" = 0 ]; then
    if plain_tag_exists "$VERSION"; then
      echo "❌ v$VERSION 은 이미 나간 번호입니다. 같은 번호로 다시 내면 이미 받은 사람과 내용이 달라집니다." >&2
      exit 1
    fi
    MAX_PLAIN="$(max_plain_tag)"
    if ! version_gt "$VERSION" "$MAX_PLAIN"; then
      echo "❌ 이미 나간 가장 큰 번호 v$MAX_PLAIN 보다 커야 합니다: v$VERSION" >&2
      exit 1
    fi
  fi
  LABEL="$VERSION"
fi

# 공개로 나가기 전 검사. 방금 만든 것과 승격하는 베타가 같은 검사를 거친다.
check_for_public() {
  local app="$1" team
  # 디버그 정보가 남으면 빌드한 맥의 경로(/Users/<이름>/…)가 실행 파일에 박혀 공개된다.
  if grep -a -q "$HOME" "$app/Contents/MacOS/$EXEC_NAME"; then
    echo "❌ 실행 파일에 이 맥의 경로($HOME)가 남아 있습니다 — 디버그 정보가 벗겨지지 않았습니다." >&2
    return 1
  fi
  # 서명이 실제로 의도한 팀인지 확인한다. 자동 선택에 맡겼다가 다른 팀으로 서명된 적이 있다.
  team="$(codesign -dvvv "$app" 2>&1 | sed -n 's/^TeamIdentifier=//p')"
  if [ "$team" != "$TEAM_ID" ]; then
    echo "❌ 서명 팀이 다릅니다: 기대 $TEAM_ID · 실제 ${team:-없음}" >&2
    return 1
  fi
  echo "   팀 확인: $team"
}

# 한 줄 설치 명령은 공개 저장소의 setup.sh 를 받는다. 소스 쪽에서 고쳤으면 같이 올린다.
# 부르는 쪽이 GH_TOKEN 을 그 저장소 주인 것으로 넘긴다.
sync_public_file() {
  local repo="$1" path="$2" local_b64 remote_b64 remote_sha
  local_b64="$(base64 < "$path" | tr -d '\n')"
  remote_sha="$(gh api "repos/$repo/contents/$path" -q .sha 2>/dev/null || true)"
  remote_b64="$(gh api "repos/$repo/contents/$path" -q .content 2>/dev/null | tr -d '\n' || true)"
  [ "$remote_b64" = "$local_b64" ] && return 0
  local args=(-X PUT "repos/$repo/contents/$path" -f message="chore: $path (v$VERSION)" -f content="$local_b64")
  [ -n "$remote_sha" ] && args+=(-f sha="$remote_sha")
  if gh api "${args[@]}" >/dev/null; then
    echo "   $repo 의 $path 를 갱신했습니다"
  else
    echo "⚠️  $repo 의 $path 갱신 실패 — 배포본은 올라갔습니다" >&2
  fi
}

# 릴리스 하나를 저장소 하나에. 부르는 쪽이 GH_TOKEN 을 그 저장소 주인 것으로, 태그 자리(--verify-tag 또는
# --target main)를 뒤에 넘긴다.
publish_release() {
  local repo="$1" zip="$2" notes
  shift 2
  notes="$(cat "$RELEASE_NOTES_FILE")"
  echo "🚀 공개로 올리는 중 ($repo · $(basename "$zip"))"
  if gh release view "v$VERSION" -R "$repo" >/dev/null 2>&1; then
    gh release upload "v$VERSION" "$zip" -R "$repo" --clobber || return 1
  else
    gh release create "v$VERSION" "$zip" -R "$repo" "$@" \
      --title "$DISPLAY_NAME v$VERSION" --notes "$notes" || return 1
  fi
}

# 받은 zip(이름은 무엇이든)을 두 저장소에 PRView-<버전>.zip 으로 올린다. 앱이 찾는 이름이다.
publish_public() {
  local zip="$1" public_zip
  public_zip="$(dirname "$zip")/$PUBLIC_ZIP_PREFIX-$VERSION.zip"
  [ "$zip" -ef "$public_zip" ] || cp "$zip" "$public_zip"
  # 태그는 부르기 전에 origin(= 이 저장소)에 올려 둔다. 빌드한 커밋에 걸리도록 --verify-tag 로 확인한다.
  publish_release "$REPO" "$public_zip" --verify-tag || return 1
  if [ -n "$BRIDGE_REPO" ]; then
    # 다리 저장소에는 소스가 없어서 태그는 그쪽 main 에 새로 단다 — 릴리스를 거는 자리일 뿐이다.
    # 이미 이 저장소에는 나갔다. 다리가 실패해도 멈추지 않고, 다시 올리는 명령을 남긴다.
    if GH_TOKEN="$BRIDGE_TOKEN" publish_release "$BRIDGE_REPO" "$public_zip" --target main; then
      # 다리의 README 가 안내하는 한 줄 설치 명령이 그쪽 setup.sh 를 받는다. 고쳤으면 같이 올린다.
      GH_TOKEN="$BRIDGE_TOKEN" sync_public_file "$BRIDGE_REPO" Scripts/setup.sh
    else
      echo "⚠️  다리 저장소($BRIDGE_REPO)에 못 올렸습니다 — 0.6.0~0.6.3 앱이 새 버전을 못 받습니다. 다시 올리기:" >&2
      echo "     GH_TOKEN=\$(gh auth token -u ${BRIDGE_REPO%%/*}) gh release create v$VERSION $public_zip -R $BRIDGE_REPO --target main --title \"$DISPLAY_NAME v$VERSION\" --notes-file $RELEASE_NOTES_FILE" >&2
    fi
  fi
  echo
  echo "✅ $DISPLAY_NAME v$VERSION 배포 완료"
  echo "   설치·업데이트 한 줄:"
  echo "   curl -fsSL https://raw.githubusercontent.com/$REPO/main/Scripts/setup.sh | bash"
}

# ─────────────────────────────────────────────── 승격: 써 본 베타를 그대로 공개로
if [ "$MODE" = "--promote" ]; then
  case "$VERSION" in
    *-beta.*)
      SRC_LABEL="$VERSION"
      VERSION="${VERSION%-beta.*}" ;;
    *)
      LAST="$(last_beta_number "$VERSION")"
      [ "$LAST" != "0" ] || { echo "❌ v$VERSION 의 베타가 없습니다 — 먼저 release.sh --beta 로 올렸나요?" >&2; exit 1; }
      SRC_LABEL="$VERSION-beta.$LAST" ;;
  esac
  # 한 번 공개한 번호에 다른 zip 을 다시 올리면, 이미 받은 사람은 같은 번호라 새 것을 받지 못한다.
  if plain_tag_exists "$VERSION"; then
    echo "❌ v$VERSION 은 이미 나간 번호입니다. 고친 것은 다음 번호로 내세요." >&2
    exit 1
  fi
  SRC_N="${SRC_LABEL##*-beta.}"
  echo "⬆️  베타 v$SRC_LABEL → 공개 v$VERSION"
  WORK="build/promote"
  rm -rf "$WORK" && mkdir -p "$WORK"
  echo "⬇️  $REPO 의 v$SRC_LABEL 을 받는 중"
  gh release download "v$SRC_LABEL" -R "$REPO" -p "PRayer-$SRC_LABEL.zip" -D "$WORK" >/dev/null \
    || { echo "❌ 받지 못했습니다 — 먼저 --beta 로 올렸나요?" >&2; exit 1; }
  ditto -x -k "$WORK/PRayer-$SRC_LABEL.zip" "$WORK/unpacked" || { echo "❌ 압축 풀기 실패" >&2; exit 1; }
  APP="$WORK/unpacked/PRayer.app"
  ZIP_VERSION="$(/usr/libexec/PlistBuddy -c 'Print CFBundleShortVersionString' "$APP/Contents/Info.plist" 2>/dev/null)"
  if [ "$ZIP_VERSION" != "$VERSION" ]; then
    echo "❌ zip 안 앱의 버전이 다릅니다: 기대 $VERSION · 실제 ${ZIP_VERSION:-없음}" >&2
    exit 1
  fi
  ZIP_N="$(/usr/libexec/PlistBuddy -c 'Print PRayerBetaNumber' "$APP/Contents/Info.plist" 2>/dev/null)"
  if [ "$ZIP_N" != "$SRC_N" ]; then
    echo "❌ zip 안 앱의 베타 번호가 다릅니다: 기대 ${SRC_N:-없음} · 실제 ${ZIP_N:-없음}" >&2
    exit 1
  fi
  check_for_public "$APP" || exit 1
  # 브라우저로 받는 사람은 공증 없이는 못 연다. 공개로는 공증된 것만 올린다.
  if ! spctl -a -vv -t exec "$APP" 2>&1 | grep -q "source=Notarized Developer ID"; then
    echo "❌ 공증되지 않은 베타라 공개로 올리지 않습니다." >&2
    exit 1
  fi
  # 앱 안 업데이트와 setup.sh 는 <이름>-<공개 번호>.zip 을 찾는다. 내용은 그대로, 이름은 publish_public 이 맞춘다.
  # 어느 소스 커밋이 공개됐는지 — 올린 베타가 가리키는 커밋에 공개 번호의 태그를 먼저 단다. 릴리스가 이
  # 태그에 걸리고(--verify-tag), 이 태그가 있으면 다음 --beta 가 이 번호를 다 쓴 것으로 보고 새 목표를 묻는다.
  if ! { git tag "v$VERSION" "v$SRC_LABEL^{commit}" && git push -q origin "v$VERSION"; }; then
    echo "❌ v$VERSION 태그를 달지 못했습니다 — 올리지 않고 멈춥니다." >&2
    exit 1
  fi
  echo "   v$VERSION 태그를 달았습니다(= v$SRC_LABEL 커밋)"
  publish_public "$WORK/PRayer-$SRC_LABEL.zip" || exit 1
  exit 0
fi

# ─────────────────────────────────────────────── 빌드 (베타·바로 공개·dry-run)
# Developer ID 인증서를 팀 ID 로 고른다.
# 이름만 보고 고르면 안 된다 — 이 맥에는 여러 팀의 인증서가 있고, 괄호 안 값은 팀 ID 가 아니다.
IDENTITY="$(security find-identity -v -p codesigning 2>/dev/null \
  | grep "Developer ID Application" | grep "$TEAM_ID" | head -1 \
  | sed -E 's/.*"(.+)"$/\1/')"
if [ -z "$IDENTITY" ]; then
  echo "❌ 팀 $TEAM_ID 의 'Developer ID Application' 인증서를 찾지 못했습니다." >&2
  echo "   developer.apple.com 에서 Developer ID 인증서를 만들어 설치하세요." >&2
  exit 1
fi
echo "🔏 서명: $IDENTITY"
SIGN_FLAGS="--timestamp --options=runtime"
if [ "${PRAYER_SKIP_TIMESTAMP:-}" = "1" ]; then
  SIGN_FLAGS="--timestamp=none --options=runtime"
  echo "⚠️  Apple 타임스탬프 없이 서명합니다. 이 빌드는 공증 없이 배포됩니다."
fi

# 버전을 project.yml 에 박고(히스토리에 남는다) 프로젝트를 다시 만든다.
sed -i.bak "s/^    MARKETING_VERSION: .*/    MARKETING_VERSION: \"$VERSION\"/" project.yml
rm -f project.yml.bak
bash Scripts/gen.sh || exit 1

OUT="build/release"
rm -rf "$OUT"
echo "🔨 Release 빌드"
# DEPLOYMENT_POSTPROCESSING=YES — 아카이브처럼 실행 파일의 디버그 정보를 벗긴다. 안 벗기면 빌드한
# 맥의 경로(/Users/<이름>/…)가 실행 파일에 박혀 공개 배포본으로 나간다(실측 v0.4.1: 203곳 → 0곳,
# 11.4MB → 4.4MB). 서명보다 먼저 벗기므로 서명은 깨지지 않는다.
xcodebuild -project PRayer.xcodeproj -scheme PRayer -configuration Release \
  -derivedDataPath "$OUT" \
  DEPLOYMENT_POSTPROCESSING=YES \
  CODE_SIGN_IDENTITY="$IDENTITY" \
  CODE_SIGN_STYLE=Manual \
  DEVELOPMENT_TEAM="$TEAM_ID" \
  OTHER_CODE_SIGN_FLAGS="$SIGN_FLAGS" \
  CODE_SIGN_INJECT_BASE_ENTITLEMENTS=NO \
  PRAYER_BETA_NUMBER="$BETA_N" \
  build >/tmp/prayer-release.log 2>&1
if [ $? -ne 0 ]; then
  echo "❌ 빌드 실패 — 로그: /tmp/prayer-release.log" >&2
  tail -20 /tmp/prayer-release.log >&2
  exit 1
fi

APP="$OUT/Build/Products/Release/PRayer.app"
[ -d "$APP" ] || { echo "❌ 산출물이 없습니다: $APP" >&2; exit 1; }
# 승격이 이 번호로 zip 을 맞춰 보므로, 빌드 변수가 Info.plist 에 실제로 들어갔는지 확인한다.
BUILT_N="$(/usr/libexec/PlistBuddy -c 'Print PRayerBetaNumber' "$APP/Contents/Info.plist" 2>/dev/null)"
if [ "$BUILT_N" != "$BETA_N" ]; then
  echo "❌ 앱의 베타 번호가 다릅니다: 기대 ${BETA_N:-빈 값} · 실제 ${BUILT_N:-빈 값} — Config/PRayer-Info.plist 의 PRayerBetaNumber 를 확인하세요." >&2
  exit 1
fi
# 베타도 나중에 그대로 공개로 승격되므로 같은 검사를 거친다.
check_for_public "$APP" || exit 1

# 디버거가 붙을 수 있게 하는 권한(get-task-allow)이 남아 있으면 공증이 거절된다.
# 실측(v0.1.0 첫 시도): 엔타이틀먼트 파일이 없는데도 Xcode 가 기본값
# (CODE_SIGN_INJECT_BASE_ENTITLEMENTS=YES)으로 끼워 넣었고, 몇 분 뒤에야 Invalid 로 돌아왔다.
if codesign -d --entitlements - --xml "$APP" 2>/dev/null | grep -Eq 'get-task-allow</key>[[:space:]]*<true/>'; then
  echo "❌ 앱에 get-task-allow 권한이 남아 있어 공증이 거절됩니다." >&2
  exit 1
fi

ZIP="build/PRayer-$LABEL.zip"
rm -f "$ZIP"
# ditto 를 쓴다. `zip` 은 심볼릭 링크와 확장 속성을 잃어 서명이 깨진다.
ditto -c -k --keepParent "$APP" "$ZIP"
echo "📦 $ZIP ($(du -h "$ZIP" | cut -f1))"

# 공증 — 자격 증명이 있을 때만. 없으면 건너뛰고 그 사실을 알린다.
#
# `notarytool submit --wait` 는 애플이 **거절(Invalid)해도 성공으로 끝난다.** 그래서 종료
# 코드가 아니라 결과의 status 를 본다. 실측(v0.1.0 첫 시도): 거절됐는데 "공증·스테이플 완료"
# 를 찍고 공증 안 된 zip 을 그대로 올렸다. 자격 증명이 있는데 거절됐다면 빌드가 잘못된
# 것이라, 태그·게시 전에 멈추고 거절 이유를 보여 준다.
json_field() { python3 -c "import json,sys; print(json.load(sys.stdin).get('$1', ''))" 2>/dev/null; }
if xcrun notarytool history --keychain-profile "$NOTARY_PROFILE" >/dev/null 2>&1; then
  echo "🍎 공증 중(몇 분 걸립니다)"
  RESULT="$(xcrun notarytool submit "$ZIP" --keychain-profile "$NOTARY_PROFILE" --wait --output-format json 2>/dev/null)"
  STATUS="$(printf '%s' "$RESULT" | json_field status)"
  SUBMISSION="$(printf '%s' "$RESULT" | json_field id)"
  if [ "$STATUS" != "Accepted" ]; then
    echo "❌ 공증이 거절됐습니다(status: ${STATUS:-응답 없음}). 올리지 않고 멈춥니다." >&2
    if [ -n "$SUBMISSION" ]; then
      xcrun notarytool log "$SUBMISSION" --keychain-profile "$NOTARY_PROFILE" 2>/dev/null | python3 -c \
        "import json,sys; [print('   -', i.get('path'), '|', i.get('message')) for i in (json.load(sys.stdin).get('issues') or [])]" >&2
      echo "   전체 기록: xcrun notarytool log $SUBMISSION --keychain-profile $NOTARY_PROFILE" >&2
    fi
    exit 1
  fi
  if ! xcrun stapler staple "$APP" >/dev/null 2>&1; then
    echo "❌ 공증은 통과했는데 스테이플에 실패했습니다. 올리지 않고 멈춥니다." >&2
    exit 1
  fi
  ditto -c -k --keepParent "$APP" "$ZIP"
  echo "   공증·스테이플 완료 — $(spctl -a -vv -t exec "$APP" 2>&1 | sed -n 's/^source=//p')"
else
  cat <<'MSG'
ℹ️  공증을 건너뜁니다(자격 증명 없음).
   setup.sh 로 설치하면 열립니다 — curl 로 받은 파일에는 격리 딱지가 안 붙습니다.
   브라우저로 zip 을 직접 받는 사람까지 받으려면 한 번만 등록해 두세요:
     xcrun notarytool store-credentials PRayer-notary \
       --apple-id <your@apple.id> --team-id <TEAM_ID>
MSG
fi

if [ "$DRY_RUN" = 1 ]; then
  echo "✅ 만들기만 했습니다(--dry-run): $ZIP"
  exit 0
fi

# 버전 커밋 — 어느 커밋이 나갔는지 나중에 찾을 수 있어야 한다.
git add project.yml
git commit -q -m "chore(release): v$LABEL" 2>/dev/null || true
git tag "v$LABEL" >/dev/null \
  || { echo "❌ 태그 v$LABEL 이 이미 있습니다. 베타로 올린 버전이면 --promote 로 올리세요." >&2; exit 1; }
# 소스 쪽(origin)에 커밋과 태그를 올린다. 어느 소스 커밋이 나갔는지는 이 태그가 가리킨다.
# push 가 실패하면 여기서 멈춘다 — 소스에 태그가 없는 배포본은 나중에 출처를 찾을 수 없다.
# 다른 작업이 같은 베타 번호를 먼저 올렸어도 태그 push 가 거절돼 여기서 멈춘다.
git push -q origin HEAD || { echo "❌ 커밋 push 실패 — 올리지 않고 멈춥니다." >&2; exit 1; }
git push -q origin "v$LABEL" || { echo "❌ 태그 push 실패 — 올리지 않고 멈춥니다." >&2; exit 1; }

# ─────────────────────────────────────────────── 베타: 시험판으로
if [ "$MODE" = "--beta" ]; then
  PREV_TAG="$(git describe --tags --abbrev=0 "v$LABEL^" 2>/dev/null || true)"
  if [ -n "${RELEASE_NOTES_FILE:-}" ] && [ -f "$RELEASE_NOTES_FILE" ]; then
    NOTES="$(cat "$RELEASE_NOTES_FILE")"
  elif [ -n "$PREV_TAG" ]; then
    NOTES="$(git log --no-merges --format='- %s' "$PREV_TAG..v$LABEL")"
  else
    NOTES="베타"
  fi
  echo "🧪 시험판으로 올리는 중 ($REPO)"
  # 태그는 방금 origin 에 올렸다. 빌드한 커밋에 붙도록 --verify-tag 로 확인한다.
  gh release create "v$LABEL" "$ZIP" -R "$REPO" --verify-tag --prerelease \
    --title "$DISPLAY_NAME $VERSION 베타 $BETA_N" --notes "$NOTES" || exit 1
  echo
  echo "✅ $VERSION 베타 $BETA_N (v$LABEL) — 시험판이라 앱 업데이트·setup.sh 로는 다른 사람에게 가지 않습니다"
  echo "   이 맥에 깔기:    bash Scripts/beta.sh"
  echo "   정식으로 올리기: RELEASE_NOTES_FILE=<노트.md> bash Scripts/release.sh $VERSION --promote"
  exit 0
fi

# ─────────────────────────────────────────────── 바로 공개
publish_public "$ZIP" || exit 1
