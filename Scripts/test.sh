#!/bin/bash
# 단위 테스트(기본) / 통합 테스트(실제 gh·Claude 호출, 토큰 소모)
#   Scripts/test.sh                 → 단위 테스트만
#   Scripts/test.sh --integration   → GitHub 읽기 경로까지
#   Scripts/test.sh --review 2717   → 실제 리뷰 1건까지 (토큰 소모)
#   Scripts/test.sh --review-batch 2741,2806 [동시수] → 여러 건 리뷰 + 문체 채점 (토큰 소모)
#   Scripts/test.sh --explain 2725 → 남의 코멘트 1건 쉬운 설명 (아주 적게 소모)
#   Scripts/test.sh --relevance 2733 → "이미 언급됨" 대조 1건 (적게 소모)
#   Scripts/test.sh --recheck 2733 → 리뷰 이후 커밋·코멘트로 처리됐는지 대조 1건 (적게 소모)
#   Scripts/test.sh --deep 2725 [repo] [model] → 워크트리 깊은 리뷰 1건 (토큰 많이 소모)
#   Scripts/test.sh --models        → 설치된 claude 에 별칭이 가리키는 모델을 묻는다 (토큰 안 씀).
#                                     CLI 를 올린 뒤 `/model` 이 여전히 API 를 안 부르는지 잰다
set -uo pipefail

# ⚠️ 반드시 `bash Scripts/test.sh` 로 실행한다.
# `./Scripts/test.sh` 처럼 파일을 직접 실행하면 일부 환경에서 xcodebuild 가 테스트 번들을
# 로드하지 못해 "Failed to create a bundle instance" 로 실패한다(재현 100%). 두 형식의
# PWD·환경변수·열린 fd 는 완전히 동일하고 재실행(exec)으로도 우회되지 않아 원인은 미확인이다.
cd "$(cd "$(dirname "$0")/.." && pwd -P)"
# 파일 목록이 달라졌을 때도 다시 생성한다 — 새로 만든 테스트 파일이 프로젝트에 없는 채로
# 돌면 그 테스트가 조용히 실행되지 않는다(개수만 보고 통과라고 착각하기 쉽다).
# 스탬프 계산에 쓸 팀 ID 를 먼저 읽는다(gen.sh 와 같은 우선순위).
if [ -z "${PRAYER_TEAM_ID:-}" ] && [ -f Local.env ]; then
  # Local.env 를 통째로 읽으므로 그 안의 PRAYER_TEST_REPO 가 환경변수로 준 레포를 덮는다. 아래의 "환경변수 → Local.env"
  # 우선순위가 지켜지게 준 값을 되살린다(2026-10-29: 공개 레포를 주고 돌렸는데 Local.env 의 레포가 리뷰됐다).
  _given_repo="${PRAYER_TEST_REPO:-}"
  # shellcheck disable=SC1091
  . ./Local.env
  [ -n "$_given_repo" ] && PRAYER_TEST_REPO="$_given_repo"
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

# 통합 테스트가 조회할 레포. 공개 저장소라 소스에 박을 수 없으므로 여기서 넘긴다.
# 우선순위: 환경변수 → Local.env(커밋되지 않는다). 없으면 테스트가 가짜 레포로 떨어져 실패한다.
if [ -z "${PRAYER_TEST_REPO:-}" ] && [ -f Local.env ]; then
  # shellcheck disable=SC1091
  . ./Local.env
fi
[ -n "${PRAYER_TEST_REPO:-}" ] && export TEST_RUNNER_PRAYER_TEST_REPO="$PRAYER_TEST_REPO"
# 실측 리뷰의 effort(--review). 없으면 기본값으로 돈다.
[ -n "${PRAYER_REVIEW_EFFORT:-}" ] && export TEST_RUNNER_PRAYER_REVIEW_EFFORT="$PRAYER_REVIEW_EFFORT"
# 묶음 실측의 모델과 사용자 리뷰 규칙 파일(--review-batch). 규칙이 없으면 앱 기본 규칙만으로 돈다.
[ -n "${PRAYER_REVIEW_MODEL:-}" ] && export TEST_RUNNER_PRAYER_REVIEW_MODEL="$PRAYER_REVIEW_MODEL"
[ -n "${PRAYER_REVIEW_RULES:-}" ] && export TEST_RUNNER_PRAYER_REVIEW_RULES="$PRAYER_REVIEW_RULES"

ARGS=(-project PRayer.xcodeproj -scheme PRayerCoreTests -configuration Debug
      -derivedDataPath build -destination "platform=macOS" test)
case "${1:-}" in
  --integration)
    export TEST_RUNNER_PRAYER_INTEGRATION=1 ;;
  --models)
    export TEST_RUNNER_PRAYER_INTEGRATION=1
    ARGS+=(-only-testing:PRayerCoreTests/ModelCatalogTests/testInstalledCLIAnswersWithoutSpendingTokens) ;;
  --review)
    export TEST_RUNNER_PRAYER_INTEGRATION=1
    export TEST_RUNNER_PRAYER_REVIEW_PR="${2:?PR 번호가 필요합니다}"
    # 모델을 바꿔 잴 때: PRAYER_REVIEW_MODEL=codex:sol bash Scripts/test.sh --review 2717
    [ -n "${PRAYER_REVIEW_MODEL:-}" ] && export TEST_RUNNER_PRAYER_REVIEW_MODEL="$PRAYER_REVIEW_MODEL"
    # 리뷰 1건만 돌린다. 이게 없으면 통합 테스트 전체가 같이 돌아, 리뷰는 통과했는데
    # 무관한 테스트가 떨어져 "❌ 실패" 로 보인다(--harvest 는 이미 이렇게 한다).
    ARGS+=(-only-testing:PRayerCoreTests/IntegrationTests/testFullReviewPipeline) ;;
  --review-batch)
    # 여러 PR 을 동시에 리뷰하고 문체 규칙으로 채점한다. 실제 앱 초안과 섞이지 않게
    # 데이터 폴더를 PRayer-eval 로 따로 쓴다.
    export TEST_RUNNER_PRAYER_INTEGRATION=1
    export TEST_RUNNER_PRAYER_REVIEW_PRS="${2:?PR 번호 목록이 필요합니다 (예: 2741,2806)}"
    export TEST_RUNNER_PRAYER_DATA_DIR="${PRAYER_EVAL_DIR:-PRayer-eval}"
    [ -n "${3:-}" ] && export TEST_RUNNER_PRAYER_REVIEW_CONCURRENCY="$3"
    ARGS+=(-only-testing:PRayerCoreTests/IntegrationTests/testReviewBatch) ;;
  --harvest)
    export TEST_RUNNER_PRAYER_INTEGRATION=1
    export TEST_RUNNER_PRAYER_HARVEST_PR="${2:?PR 번호가 필요합니다}"
    ARGS+=(-only-testing:PRayerCoreTests/IntegrationTests/testSpoolHarvest) ;;
  --pool)
    export TEST_RUNNER_PRAYER_INTEGRATION=1
    export TEST_RUNNER_PRAYER_POOL_REPO="${2:-$HOME/work/sample-ios}"
    ARGS+=(-only-testing:PRayerCoreTests/IntegrationTests/testWorktreePoolReuse) ;;
  --relevance)
    export TEST_RUNNER_PRAYER_INTEGRATION=1
    export TEST_RUNNER_PRAYER_RELEVANCE_PR="${2:?PR 번호가 필요합니다}"
    ARGS+=(-only-testing:PRayerCoreTests/IntegrationTests/testRelevancePipeline) ;;
  --recheck)
    export TEST_RUNNER_PRAYER_INTEGRATION=1
    export TEST_RUNNER_PRAYER_RECHECK_PR="${2:?PR 번호가 필요합니다}"
    ARGS+=(-only-testing:PRayerCoreTests/IntegrationTests/testRecheckPipeline) ;;
  --explain)
    export TEST_RUNNER_PRAYER_INTEGRATION=1
    export TEST_RUNNER_PRAYER_EXPLAIN_PR="${2:?PR 번호가 필요합니다}"
    ARGS+=(-only-testing:PRayerCoreTests/IntegrationTests/testExplainPipeline) ;;
  --deep)
    export TEST_RUNNER_PRAYER_INTEGRATION=1
    export TEST_RUNNER_PRAYER_DEEP_PR="${2:?PR 번호가 필요합니다}"
    export TEST_RUNNER_PRAYER_DEEP_REPO="${3:-$HOME/work/sample-ios}"
    [ -n "${4:-}" ] && export TEST_RUNNER_PRAYER_DEEP_MODEL="$4"
    ARGS+=(-only-testing:PRayerCoreTests/IntegrationTests/testDeepReviewPipeline) ;;
  *)
    ARGS+=(-skip-testing:PRayerCoreTests/IntegrationTests) ;;
esac

run() { xcodebuild "${ARGS[@]}" >"$1" 2>&1; }

LOG="$(mktemp -t prayer-test)"
if ! run "$LOG"; then
  # xcodebuild 가 테스트 번들을 막 만든 직후 xctest 로 넘길 때
  # "Failed to create a bundle instance" 로 실패하는 일이 있다(빌드·산출물은 정상).
  # 이때만 한 번 다시 돌린다.
  if grep -q "Failed to create a bundle instance" "$LOG"; then
    echo "↻ 번들 로딩 실패 — 1회 재시도합니다"
    sleep 2
    run "$LOG"
  fi
fi

if grep -q "^\*\* TEST SUCCEEDED \*\*" "$LOG"; then
  grep -E "Executed [0-9]+ tests" "$LOG" | tail -1
  # 통합 테스트가 "### " 로 찍는 실측값(판정·토큰·근거)은 성공해도 보여 준다.
  grep -aE "^(###|프롬프트|verdict=|PR [0-9]+건|  \[)" "$LOG" || true
  grep -aE "was skipped|Skipped" "$LOG" | head -3 || true
  echo "✅ 통과"
  rm -f "$LOG"
else
  grep -E "error:|XCTAssert|Testing failed|encountered an error" "$LOG" | head -20
  echo "❌ 실패 — 전체 로그: $LOG"
  exit 1
fi
