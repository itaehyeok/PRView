import Foundation

/// 터미널에서 여는 로그인 창(`.command`)의 본문과, 그 창이 끝났다는 신호.
///
/// 터미널에서 로그인이 끝나도 앱은 그걸 몰랐다 — 앱으로 돌아와야 상태를 다시 봤다. 그래서
/// 로그인해 놓고도 "로그인이 끊겼습니다" 토스트를 손으로 닫아야 했다(10-20 사용자).
/// 스크립트가 끝나면서 결과를 파일에 남기고, 앱은 그 파일을 기다렸다가 곧바로 상태를 다시 본다.
public enum LoginScript {
    public enum Outcome: Equatable, Sendable {
        /// 로그인 명령이 0 으로 끝났다.
        case succeeded
        /// 실패·취소(Ctrl-C)·창 닫기. 값은 스크립트가 남긴 것(종료 코드, `int`, `hup`, `term`).
        case failed(String)
        /// 정해 둔 시간 안에 결과가 오지 않았다.
        case timedOut
    }

    /// - Parameter resultPath: 끝나면 결과를 남길 파일. nil 이면 남기지 않는다(기다리는 쪽이 없는 창).
    public static func text(appName: String, title: String, command: String, resultPath: String?) -> String {
        guard let resultPath else {
            return """
                #!/bin/bash
                echo "\(appName) — \(title)"
                echo
                \(command)
                echo
                echo "끝나면 이 창을 닫고 \(appName) 로 돌아가세요. 상태는 자동으로 다시 확인합니다."
                """
        }
        // 창을 닫거나(HUP) Ctrl-C 로 멈춰도 결과를 남긴다 — 안 남기면 앱이 시간이 다 될 때까지
        // "로그인하는 중" 을 띄워 둔다. 결과는 임시 파일에 쓰고 옮겨, 반쯤 쓴 파일을 읽지 않게 한다.
        return """
            #!/bin/bash
            RESULT=\(shellQuoted(resultPath))
            finish() { printf '%s\\n' "$1" > "$RESULT.tmp" && mv -f "$RESULT.tmp" "$RESULT"; }
            trap 'finish hup; exit 129' HUP
            trap 'finish int; exit 130' INT
            trap 'finish term; exit 143' TERM
            echo "\(appName) — \(title)"
            echo
            \(command)
            code=$?
            trap - HUP INT TERM
            finish "$code"
            echo
            if [ "$code" -eq 0 ]; then
              echo "로그인이 끝났습니다. 이 창은 닫아도 됩니다 — \(appName) 가 바로 다시 확인합니다."
            else
              echo "로그인이 끝나지 않았습니다(종료 코드 $code). 이 창을 닫고 \(appName) 에서 다시 시도하세요."
            fi
            """
    }

    /// 결과 파일의 내용 → 결과. 스크립트는 종료 코드나 신호 이름 한 줄을 남긴다.
    public static func outcome(fromResult contents: String) -> Outcome {
        let value = contents.trimmingCharacters(in: .whitespacesAndNewlines)
        return value == "0" ? .succeeded : .failed(value)
    }

    /// 결과 파일이 생길 때까지 기다린다. 읽은 파일은 지운다(다음 창이 옛 결과를 읽지 않게).
    /// 기다리는 Task 가 취소되면 `.timedOut` 으로 돌아온다 — 부르는 쪽이 취소 여부를 따로 본다.
    public static func waitForResult(at url: URL, timeout: Duration,
                                     interval: Duration = .milliseconds(500)) async -> Outcome {
        let clock = ContinuousClock()
        let deadline = clock.now.advanced(by: timeout)
        while clock.now < deadline {
            if let data = try? Data(contentsOf: url) {
                try? FileManager.default.removeItem(at: url)
                return outcome(fromResult: String(decoding: data, as: UTF8.self))
            }
            do {
                try await Task.sleep(for: interval)
            } catch {
                return .timedOut
            }
        }
        return .timedOut
    }

    /// 데이터 폴더가 `Application Support` 라 경로에 띄어쓰기가 있다.
    static func shellQuoted(_ value: String) -> String {
        "'" + value.replacingOccurrences(of: "'", with: "'\\''") + "'"
    }
}
