import Foundation

/// 앱을 바꿔 끼우는 셸 스크립트. PRayer 가 꺼지기를 기다렸다가 새 앱을 놓고 연다.
/// 업데이트(받은 새 버전)와 "응용 프로그램 폴더로 옮기기"(지금 앱의 사본)가 같이 쓴다.
///
/// 인자: ① 놓을 앱(비우면 놓지 않고 ②를 열기만) ② 놓을 자리 ③ 기다릴 PID ④ 로그 파일
/// ⑤ 여는 명령(테스트용, 기본 `/usr/bin/open`)
///
/// 앱이 꺼진 뒤에 돌아서 실패해도 화면에 띄울 곳이 없다. 그래서 단계마다 앱 로그에 남긴다 —
/// "업데이트를 눌렀는데 아무 일도 없다" 를 로그만 보고 가를 수 있게.
public enum UpdateHelperScript {
    /// `waitSeconds`: 앱이 꺼지기를 기다리는 시간. 리뷰가 돌고 있으면 종료 안내가 떠서 사람이 누를 때까지 걸린다.
    public static func text(waitSeconds: Int = 120) -> String {
        """
        #!/bin/bash
        set -uo pipefail
        stage="$1"
        target="$2"
        pid="$3"
        log="$4"
        opener="${5:-/usr/bin/open}"
        backup="${target%.app}.previous-$$.app"
        trap 'rm -f "$0"' EXIT
        note() { printf '[%s.000] [update] %s\\n' "$(/bin/date '+%Y-%m-%d %H:%M:%S')" "$1" >> "$log" 2>/dev/null || true; }
        for _ in {1..\(max(1, waitSeconds * 5))}; do
          kill -0 "$pid" 2>/dev/null || break
          sleep 0.2
        done
        if kill -0 "$pid" 2>/dev/null; then
          note "PRayer 가 \(waitSeconds)초 안에 꺼지지 않아 교체를 그만둠"
          if [ -n "$stage" ]; then rm -rf "$stage"; fi
          exit 1
        fi
        if [ -n "$stage" ]; then
          if [ -e "$target" ] && ! mv "$target" "$backup"; then
            note "있던 앱을 비키지 못함: $target"
            rm -rf "$stage"
            exit 1
          fi
          if ! mv "$stage" "$target"; then
            note "새 앱을 놓지 못함: $target"
            if [ -e "$backup" ]; then mv "$backup" "$target"; fi
            exit 1
          fi
        fi
        if ! "$opener" "$target"; then
          note "새 앱을 열지 못함: $target"
          if [ -e "$backup" ]; then
            rm -rf "$target"
            mv "$backup" "$target"
            "$opener" "$target" || true
            note "있던 앱으로 되돌림: $target"
          fi
          exit 1
        fi
        if [ -e "$backup" ]; then rm -rf "$backup"; fi
        note "교체 완료: $target"
        exit 0
        """
    }
}
