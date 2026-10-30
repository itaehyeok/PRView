#!/bin/bash
# 이 맥에서 PRView 를 빌드·실행할 수 있는지 점검한다. 고치는 방법까지 함께 알려 준다.
#   bash Scripts/doctor.sh
set -uo pipefail
cd "$(cd "$(dirname "$0")/.." && pwd -P)"

FAIL=0
ok()   { printf '  ✅ %s\n' "$1"; }
warn() { printf '  ⚠️  %s\n' "$1"; }
bad()  { printf '  ❌ %s\n     → %s\n' "$1" "$2"; FAIL=1; }

echo "PRView 준비 상태"
echo

echo "[빌드 도구]"
if [ "$(sw_vers -productVersion | cut -d. -f1)" -ge 14 ] 2>/dev/null; then
  ok "macOS $(sw_vers -productVersion)"
else
  bad "macOS $(sw_vers -productVersion) — 14 이상이 필요합니다" "OS 를 올리세요"
fi
if xcodebuild -version >/dev/null 2>&1; then
  ok "$(xcodebuild -version | head -1)"
else
  bad "Xcode 가 없거나 xcode-select 가 잘못됐습니다" \
      "App Store 에서 Xcode 설치 후: sudo xcode-select -s /Applications/Xcode.app"
fi
if command -v xcodegen >/dev/null 2>&1; then
  ok "xcodegen $(xcodegen --version 2>/dev/null | head -1)"
else
  bad "xcodegen 없음" "brew install xcodegen"
fi

echo
echo "[서명]  알림을 받으려면 실제 개발 인증서로 서명해야 합니다(ad-hoc 서명은 알림이 거부됩니다)."
TEAM="${PRAYER_TEAM_ID:-}"
[ -z "$TEAM" ] && [ -f Local.env ] && . ./Local.env && TEAM="${PRAYER_TEAM_ID:-}"
MULTI=""
if [ -z "$TEAM" ]; then
  # gen.sh 와 같은 방식 — 인증서마다 잘라 읽고(`openssl x509` 는 첫 장만 읽는다), 팀이 여럿이면 고르지 않는다.
  TEAMS="$(security find-certificate -a -c "Apple Development" -p 2>/dev/null \
    | awk 'BEGIN { cmd = "openssl x509 -noout -subject 2>/dev/null" }
           /-----BEGIN CERTIFICATE-----/ { pem = "" }
           { pem = pem $0 "\n" }
           /-----END CERTIFICATE-----/ { printf "%s", pem | cmd; close(cmd) }' \
    | sed -n 's/.*OU *= *\([A-Z0-9]*\).*/\1/p' | sort -u)"
  if [ "$(printf '%s\n' "$TEAMS" | grep -c .)" -gt 1 ]; then
    MULTI=1
    bad "Apple Development 인증서가 여러 팀에 걸쳐 있습니다: $(echo $TEAMS)" \
        "빌드(gen.sh)가 멈춥니다. 쓸 팀을 직접 지정하세요: echo 'PRAYER_TEAM_ID=XXXXXXXXXX' >> Local.env"
  else
    TEAM="$TEAMS"
    [ -n "$TEAM" ] && ok "팀 ID 자동 감지: $TEAM"
  fi
else
  ok "팀 ID 지정됨: $TEAM"
fi
if [ -z "$TEAM" ] && [ -z "$MULTI" ]; then
  bad "Apple Development 인증서가 없습니다" \
      "Xcode → Settings → Accounts 에서 Apple ID 로그인(무료 계정 가능). 또는 echo 'PRAYER_TEAM_ID=ABCDE12345' > Local.env"
fi

echo
echo "[연동]  계정은 각자 것을 씁니다. 앱은 토큰을 저장하지 않고 아래 CLI 로그인을 그대로 빌려 씁니다."
GH="$(command -v gh || true)"
if [ -n "$GH" ]; then
  if "$GH" auth status >/dev/null 2>&1; then
    ok "gh 로그인됨 ($("$GH" api user --jq .login 2>/dev/null || echo '사용자 확인 실패'))"
    "$GH" auth status 2>&1 | grep -q "'repo'" && ok "scope repo 있음" || warn "scope 'repo' 가 없을 수 있습니다 → gh auth refresh -s repo,read:org"
  else
    bad "gh 로그인 안 됨" "gh auth login  (scope: repo, read:org)"
  fi
else
  bad "gh 없음" "brew install gh && gh auth login"
fi
CLAUDE="$(command -v claude || echo "$HOME/.local/bin/claude")"
if [ -x "$CLAUDE" ]; then
  ok "claude 있음 ($CLAUDE)"
  echo "     로그인 여부는 앱의 상태 메뉴에서 확인됩니다 (claude 실행이 필요해 여기서는 건너뜁니다)"
else
  bad "claude CLI 없음" "https://code.claude.com 설치 후 로그인"
fi

echo
if [ "$FAIL" -eq 0 ]; then
  echo "준비됐습니다. 다음:"
  echo "  bash Scripts/install.sh && open ~/Applications/PRayer.app"
else
  echo "위 ❌ 를 먼저 해결하세요."
fi
exit "$FAIL"
