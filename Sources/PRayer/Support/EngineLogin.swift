import AppKit
import PRayerCore

/// Claude 로그인을 사용자 대신 **시작해 주는** 것까지가 앱의 몫이다.
///
/// 앱이 직접 로그인할 수는 없다 — `claude auth login` 은 브라우저를 열고 코드를 붙여 넣는
/// 대화형 흐름이라 헤드리스로 돌릴 수 없다. 대신 터미널을 열고 그 명령을 대신 쳐 준다.
///
/// AppleScript(`osascript`)로 터미널을 조종하지 않는 이유: 자동화 권한을 따로 받아야 하고,
/// 거절당하면 조용히 아무 일도 안 일어난다. 실행 가능한 `.command` 파일을 열면 macOS 가
/// 알아서 터미널에서 실행하므로 추가 권한이 필요 없다.
enum EngineLogin {
    static func command(path: String) -> String {
        let quoted = path.contains(" ") ? "\"\(path)\"" : path
        return "\(quoted) auth login"
    }

    /// `gh` 로그인도 같은 이유로 터미널을 열어 준다. 호스트를 주면 그 호스트로 붙는다.
    @discardableResult
    static func openGitHub(ghPath: String, host: String) -> String? {
        let quoted = ghPath.contains(" ") ? "\"\(ghPath)\"" : ghPath
        let command = "\(quoted) auth login --hostname \(host)"
        return run(title: "GitHub(\(host)) 로그인", command: command, fileName: "gh-login")
    }

    /// 터미널을 열어 로그인 명령을 실행한다. 실패하면 이유를 돌려준다.
    ///
    /// 실행 파일이 없으면 스크립트를 만들지 않는다. 없는 경로로 돌리면 터미널에
    /// "No such file or directory" 만 찍히고, 사용자는 로그인 문제로 읽는다(실측: 팀원 맥).
    @discardableResult
    static func open(path: String) -> String? {
        guard FileManager.default.isExecutableFile(atPath: path) else {
            return "Claude Code CLI 를 찾지 못했습니다(\(path)). 먼저 설치하세요."
        }
        return run(title: "Claude Code 로그인", command: command(path: path), fileName: claudeLoginName, reportsResult: true)
    }

    /// 공식 설치 스크립트로 CLI 를 깔고, 이어서 로그인까지 한 창에서 한다.
    ///
    /// 설치 스크립트는 `~/.local/bin/claude` 에 놓는다 — 앱이 제일 먼저 보는 자리라 돌아오면 바로 잡힌다.
    /// 데스크톱 앱만 쓰던 사람은 터미널용 CLI 가 따로 없어서 여기로 온다.
    @discardableResult
    static func openInstall() -> String? {
        let installed = "\(NSHomeDirectory())/.local/bin/claude"
        let command = "\(ClaudeRunner.installCommand) && \"\(installed)\" auth login"
        return run(title: "Claude Code 설치", command: command, fileName: claudeInstallName, reportsResult: true)
    }

    static let claudeLoginName = "claude-login"
    static let claudeInstallName = "claude-install"

    /// Codex 로그인 — `codex login` 이 브라우저를 열어 ChatGPT 로 붙는다. 이것도 대화형이라 터미널에서 한다.
    @discardableResult
    static func openCodex(path: String) -> String? {
        guard FileManager.default.isExecutableFile(atPath: path) else {
            return "Codex CLI 를 찾지 못했습니다(\(path)). 먼저 설치하세요."
        }
        let quoted = path.contains(" ") ? "\"\(path)\"" : path
        return run(title: "Codex 로그인", command: "\(quoted) login", fileName: codexLoginName, reportsResult: true)
    }

    /// Codex CLI 를 깔고 이어서 로그인한다. 공식 설치는 npm 이고, npm 이 없으면 Homebrew 로 깐다.
    /// 둘 다 없으면 무엇이 필요한지만 알리고 끝낸다 — 앱이 Node 까지 깔아 주지는 않는다.
    @discardableResult
    static func openCodexInstall() -> String? {
        let command = """
            if command -v npm >/dev/null 2>&1; then \(CodexRunner.installCommand)
            elif command -v brew >/dev/null 2>&1; then brew install codex
            else echo "npm(Node.js) 이나 Homebrew 가 있어야 Codex 를 깔 수 있습니다."; false
            fi && codex login
            """
        return run(title: "Codex 설치", command: command, fileName: codexInstallName, reportsResult: true)
    }

    static let codexLoginName = "codex-login"
    static let codexInstallName = "codex-install"

    /// 그 창이 끝나면서 결과를 남기는 파일(`LoginScript`). 앱이 이걸 기다렸다가 상태를 다시 본다.
    static func resultFile(_ fileName: String) -> URL {
        AppPaths.support.appendingPathComponent("\(fileName).result")
    }

    private static func run(title: String, command: String, fileName: String, reportsResult: Bool = false) -> String? {
        let result = resultFile(fileName)
        // 지난 창의 결과가 남아 있으면 기다리자마자 그걸 읽는다.
        try? FileManager.default.removeItem(at: result)
        let script = LoginScript.text(appName: AppInfo.displayName, title: title, command: command,
                                      resultPath: reportsResult ? result.path : nil)
        let url = AppPaths.support.appendingPathComponent("\(fileName).command")
        do {
            try script.write(to: url, atomically: true, encoding: .utf8)
            try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        } catch {
            return "로그인 스크립트를 만들지 못했습니다: \(error.localizedDescription)"
        }
        guard NSWorkspace.shared.open(url) else {
            return "터미널을 열지 못했습니다. 직접 실행하세요: \(command)"
        }
        return nil
    }
}
