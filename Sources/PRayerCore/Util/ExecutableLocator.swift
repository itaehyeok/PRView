import Foundation

/// GUI 앱에서 CLI 실행 파일(`claude`·`gh`)을 찾는다.
///
/// GUI 앱은 셸의 PATH 를 물려받지 않는다. 그래서 (1) 흔한 설치 위치를 먼저 보고, (2) 사용자의 셸에
/// 묻고, (3) 그래도 없으면 덜 흔한 위치까지 본다. (3)을 셸보다 앞에 두지 않는 이유: 예전에 깔고
/// 잊은 nvm 버전 같은 것이 지금 셸이 쓰는 실행 파일을 가린다.
///
/// 셸에 물을 때 **로그인 셸(`-l`)만으로는 모자란다.** nvm·alias·PATH 추가는 보통 `~/.zshrc` 에
/// 있는데 로그인 셸은 그 파일을 읽지 않는다. 그래서 대화형(`-i`)으로도 띄운다(실측 2026-09-29:
/// 팀원 맥에서 `zsh -lc 'command -v claude'` 가 아무것도 못 찾아 온보딩이 "설치 안 됨" 에서 멈췄다).
public enum ExecutableLocator {
    public static func find(_ name: String, preferred: [String], fallback: [String]) async -> String? {
        let fm = FileManager.default
        if let hit = preferred.first(where: { fm.isExecutableFile(atPath: $0) }) { return hit }
        if let hit = await askShell(name) { return hit }
        return fallback.first(where: { fm.isExecutableFile(atPath: $0) })
    }

    /// 사용자의 로그인 셸을 로그인·대화형으로 띄워 `command -v` 를 묻는다.
    ///
    /// 대화형 셸은 설정 파일이 뭔가를 찍거나 끝 코드가 0 이 아니어도 흔하다 — 출력만 보고 판단한다.
    /// 표준 입력은 비워 준다: 설정 파일이 입력을 기다리면(업데이트 확인 같은) 바로 넘어가게.
    static func askShell(_ name: String) async -> String? {
        let spec = ProcessSpec(executable: loginShell(),
                               arguments: ["-l", "-i", "-c", "command -v \(name)"],
                               stdin: "",
                               environment: ProcessEnvironment.base(),
                               timeout: 10,
                               gracePeriod: 2)
        guard let result = try? await ProcessRunner().run(spec),
              let path = parseLookup(result.stdout, name: name),
              FileManager.default.isExecutableFile(atPath: path) else { return nil }
        return path
    }

    /// 계정에 등록된 로그인 셸. zsh 가 아닌 사람(bash·fish)도 있다.
    static func loginShell() -> String {
        if let entry = getpwuid(getuid()), let shell = entry.pointee.pw_shell {
            let path = String(cString: shell)
            if FileManager.default.isExecutableFile(atPath: path) { return path }
        }
        return "/bin/zsh"
    }

    /// `command -v` 출력에서 실행 파일 경로를 뽑는다.
    ///
    /// 경로(`/…/bin/claude`)와 alias(`alias claude='~/.claude/local/claude'`) 둘 다 받는다 — 예전
    /// "로컬 설치" 는 PATH 에 넣지 않고 alias 로만 부른다. 셸 설정이 찍은 잡음·색 코드는 건너뛴다.
    /// 경로가 아니면(함수·`npx …` 같은 alias) nil.
    static func parseLookup(_ output: String, name: String, home: String = NSHomeDirectory()) -> String? {
        let lines = stripANSI(output)
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
        for line in lines.reversed() {
            var candidate = line
            if line.hasPrefix("alias \(name)=") || line.hasPrefix("\(name)=") {
                let value = line.split(separator: "=", maxSplits: 1).last.map(String.init) ?? ""
                candidate = value.trimmingCharacters(in: CharacterSet(charactersIn: "'\""))
                // alias 뒤에 붙인 옵션은 뗀다(`alias claude='… --verbose'`).
                candidate = candidate.split(separator: " ").first.map(String.init) ?? ""
            }
            if candidate.hasPrefix("~/") {
                candidate = home + candidate.dropFirst(1)
            } else if candidate.hasPrefix("$HOME/") {
                candidate = home + candidate.dropFirst("$HOME".count)
            }
            if candidate.hasPrefix("/") { return candidate }
        }
        return nil
    }

    static func stripANSI(_ text: String) -> String {
        text.replacingOccurrences(of: "\u{1B}\\[[0-9;?]*[ -/]*[@-~]", with: "", options: .regularExpression)
            .replacingOccurrences(of: "\u{1B}\\][^\u{07}\u{1B}]*(\u{07}|\u{1B}\\\\)", with: "", options: .regularExpression)
    }

    /// 셸 설정으로만 PATH 에 들어가는 흔한 도구 폴더. 셸에 물어도 못 찾았을 때 마지막으로 본다.
    static func userToolDirectories(home: String = NSHomeDirectory()) -> [String] {
        [
            "\(home)/.npm-global/bin",
            "\(home)/.volta/bin",
            "\(home)/.bun/bin",
            "\(home)/Library/pnpm",
            "\(home)/.local/share/mise/shims",
            "\(home)/.asdf/shims",
            "\(home)/.nix-profile/bin",
            "/run/current-system/sw/bin",
            "/opt/local/bin",
        ] + nvmBinDirectories(home: home)
    }

    /// `~/.nvm/versions/node/<버전>/bin`, 새 Node 부터. npm 으로 깐 CLI 는 Node 버전마다 따로 있다.
    static func nvmBinDirectories(home: String) -> [String] {
        let root = URL(fileURLWithPath: home).appendingPathComponent(".nvm/versions/node", isDirectory: true)
        guard let versions = try? FileManager.default.contentsOfDirectory(atPath: root.path) else { return [] }
        return versions
            .sorted { $0.compare($1, options: .numeric) == .orderedDescending }
            .map { root.appendingPathComponent($0).appendingPathComponent("bin").path }
    }
}
