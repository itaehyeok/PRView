#!/bin/bash
# 앱 빌드. 실패하면 컴파일 오류만 뽑아 보여준다.
set -uo pipefail
# 물리 경로로 정규화해서 이동한다. `cd "$(dirname "$0")/.."` 로 두면 cwd 가
# `.../PRayer/Scripts/..` 형태가 되고, 그 경로로 만든 .xctestrun 을 xctest 가 해석하지 못해
# "Failed to create a bundle instance" 로 실패한다.
cd "$(cd "$(dirname "$0")/.." && pwd -P)"
# 프로젝트를 다시 생성해야 하는 경우가 둘이다.
#  1) project.yml 이 프로젝트보다 새롭다.
#     예전처럼 `[ -d PRayer.xcodeproj ] || xcodegen generate` 로 두면 project.yml 을 고쳐도
#     조용히 옛 프로젝트로 빌드된다(리소스 빌드 단계가 통째로 빠진 채 배포된 적이 있다).
#  2) 소스·리소스 **파일 목록**이 달라졌다. 파일을 새로 만들면 프로젝트에 없는 채로 빌드돼
#     `cannot find 'X' in scope` 가 난다 — 원인이 오타처럼 보여서 매번 헛걸음한다.
# 스탬프 계산에 쓸 팀 ID 를 먼저 읽는다(gen.sh 와 같은 우선순위).
if [ -z "${PRAYER_TEAM_ID:-}" ] && [ -f Local.env ]; then
  # shellcheck disable=SC1091
  . ./Local.env
fi
STAMP=".build-filelist"
# 스탬프에 **서명 팀**도 섞는다. 파일 목록만 보면, 팀을 바꿔도 프로젝트가 다시 생성되지
# 않아 옛 팀 ID 가 박힌 채로 빌드된다 — 실제로 의도하지 않은 팀으로 서명되고 있었다.
CURRENT="$(( find Sources Resources Tests -type f \( -name '*.swift' -o -name '*.md' -o -name '*.json' -o -name '*.ttf' -o -name '*.strings' \) | sort; echo "team=${PRAYER_TEAM_ID:-}" ) | shasum | cut -d' ' -f1)"
if [ ! -d PRayer.xcodeproj ] || [ project.yml -nt PRayer.xcodeproj/project.pbxproj ] \
   || [ "$CURRENT" != "$(cat "$STAMP" 2>/dev/null)" ]; then
  # 스탬프는 gen.sh 가 갱신한다(주인을 하나로 둔다).
  bash Scripts/gen.sh
fi
LOG="$(mktemp -t prayer-build)"
if xcodebuild -project PRayer.xcodeproj -scheme PRayer -configuration Debug \
     -derivedDataPath build -destination "platform=macOS" build >"$LOG" 2>&1; then
  echo "✅ 빌드 성공: $(pwd)/build/Build/Products/Debug/PRayer.app"
  rm -f "$LOG"
else
  grep -E "error:|warning: .*Sendable" "$LOG" | head -30
  echo "❌ 빌드 실패 — 전체 로그: $LOG"
  exit 1
fi
