#!/bin/bash
# Xcode 프로젝트 생성 (project.yml → PRayer.xcodeproj)
set -euo pipefail
# 물리 경로로 정규화해서 이동한다. `cd "$(dirname "$0")/.."` 로 두면 cwd 가
# `.../PRayer/Scripts/..` 형태가 되고, 그 경로로 만든 .xctestrun 을 xctest 가 해석하지 못해
# "Failed to create a bundle instance" 로 실패한다.
cd "$(cd "$(dirname "$0")/.." && pwd -P)"
# 서명에 쓸 팀 ID 를 정한다. 우선순위: 환경변수 → Local.env → 이 맥의 인증서에서 자동 감지.
#
# 팀 ID 를 project.yml 에 박아 두면 저장소를 받은 사람이 그대로 빌드할 수 없다. 반대로 ad-hoc(-)
# 서명으로 낮추면 알림(UNUserNotificationCenter)이 거부돼 리뷰 완료 알림이 오지 않는다(실측).
# 그래서 각자 자기 Apple Development 인증서로 서명하게 하고, 그 팀 ID 를 여기서 찾아 준다.
# 인증서의 OU 필드가 곧 팀 ID 다.
if [ -z "${PRAYER_TEAM_ID:-}" ] && [ -f Local.env ]; then
  # shellcheck disable=SC1091
  . ./Local.env
fi
if [ -z "${PRAYER_TEAM_ID:-}" ]; then
  # `|| true` 가 없으면 안 된다. 이 파일은 set -e -o pipefail 이라, 인증서가 없어
  # security 가 1 로 끝나는 순간 파이프라인 실패로 스크립트가 **아무 말 없이** 죽는다.
  # 정작 아래 안내를 보여 줘야 할 상황에서 침묵하게 된다(실측).
  # 인증서가 여러 개면 `head -1` 이 **아무거나** 고른다. 이 맥에는 팀이 둘 있었고,
  # 그래서 한동안 의도하지 않은 팀(다른 사람의 개인 팀)으로 서명되고 있었다(실측).
  # 후보가 둘 이상이면 고르지 않고 멈춘다 — 조용히 틀린 팀으로 서명하는 것보다 낫다.
  # `openssl x509` 는 PEM 이 여러 장 이어져 와도 **첫 장만** 읽는다. 그래서 팀이 둘이어도 후보가 하나로
  # 보여 이 멈춤이 걸리지 않았고, 첫 인증서의 팀으로 조용히 서명됐다(2026-10-06 실측, Local.env 없는 워크트리).
  # 인증서마다 잘라 한 장씩 읽는다.
  CANDIDATES="$(security find-certificate -a -c "Apple Development" -p 2>/dev/null \
    | awk 'BEGIN { cmd = "openssl x509 -noout -subject 2>/dev/null" }
           /-----BEGIN CERTIFICATE-----/ { pem = "" }
           { pem = pem $0 "\n" }
           /-----END CERTIFICATE-----/ { printf "%s", pem | cmd; close(cmd) }' \
    | sed -n 's/.*OU *= *\([A-Z0-9]*\).*/\1/p' | sort -u || true)"
  COUNT="$(printf '%s\n' "$CANDIDATES" | grep -c . || true)"
  if [ "$COUNT" = "1" ]; then
    PRAYER_TEAM_ID="$CANDIDATES"
  elif [ "$COUNT" -gt 1 ]; then
    echo "❌ Apple Development 인증서가 여러 팀에 걸쳐 있습니다:"
    printf '     %s\n' $CANDIDATES
    echo "   쓸 팀을 직접 지정하세요:  echo 'PRAYER_TEAM_ID=XXXXXXXXXX' >> Local.env"
    exit 1
  fi
fi
if [ -z "${PRAYER_TEAM_ID:-}" ]; then
  cat >&2 <<'MSG'
❌ 서명에 쓸 팀 ID 를 찾지 못했습니다.

이 맥에 Apple Development 인증서가 없습니다. 둘 중 하나를 하세요.
  1) Xcode → Settings → Accounts 에서 Apple ID 로 로그인 (무료 계정도 됩니다).
     그러면 인증서가 만들어지고 이 스크립트가 팀 ID 를 자동으로 찾습니다.
  2) 팀 ID 를 직접 지정: echo 'PRAYER_TEAM_ID=ABCDE12345' > Local.env

확인:  bash Scripts/doctor.sh
MSG
  exit 1
fi
export PRAYER_TEAM_ID
echo "서명 팀: $PRAYER_TEAM_ID"

# 빌드 번호 = 커밋 수. 손으로 올리면 언젠가 잊고, 두 릴리스가 같은 번호를 달면
# "설치된 것이 새 것인가" 를 앱이 판단할 수 없다.
PRAYER_BUILD="$(git rev-list --count HEAD 2>/dev/null || echo 1)"
export PRAYER_BUILD
sed -i.bak "s/^    CURRENT_PROJECT_VERSION: .*/    CURRENT_PROJECT_VERSION: \"$PRAYER_BUILD\"/" project.yml
rm -f project.yml.bak

xcodegen generate
# 생성할 때마다 파일 목록 스탬프를 갱신한다.
#
# 예전에는 build.sh·test.sh 만 스탬프를 썼고 gen.sh 는 그냥 생성만 했다. 그래서 gen.sh 를
# 직접 부르면 프로젝트는 바뀌는데 스탬프는 옛 목록 그대로 남았고, 다음 test.sh 가
# "목록 그대로네" 하고 재생성을 건너뛰어 이미 지운 파일을 참조한 채 빌드에 실패했다(실측).
# 스탬프의 주인을 여기 하나로 둔다.
( find Sources Resources Tests -type f \( -name '*.swift' -o -name '*.md' -o -name '*.json' -o -name '*.ttf' -o -name '*.strings' \) \
  | sort; echo "team=${PRAYER_TEAM_ID:-}" ) | shasum | cut -d' ' -f1 > .build-filelist
