import AppKit
import Foundation
import PRayerCore

/// 실행 중인 앱 번들은 건드리지 않는다. 검증한 새 앱을 놓을 폴더에 준비하고,
/// 별도 프로세스가 PRayer 종료 후 교체·재실행한다.
///
/// 응용 프로그램 폴더 밖(다운로드 폴더에서 바로 연 앱 등)에서 돌면 응용 프로그램 폴더로 옮겨 깐다 —
/// 원래 앱은 새 자리에서 켠 뒤에 치운다(AppMover).
enum AppUpdater {
    struct Prepared {
        let stagedApp: URL
        let installedApp: URL
        /// 응용 프로그램 폴더로 옮겨 까는가.
        var moves = false
        /// 옮겨 깐 뒤 치울 원래 앱(모르면 nil).
        var leftover: URL?
        /// 바꿔 끼운 뒤 그 자리에서 켜질 버전.
        var version = ""
    }

    enum Failure: LocalizedError {
        case noAsset, unsupportedLocation, notWritable(String)
        case download, invalidArchive, invalidSignature
        case wrongApp, wrongVersion, wrongTeam, helper

        var errorDescription: String? {
            switch self {
            case .noAsset: "이 릴리스에 \(AppInfo.displayName) 설치 파일이 없습니다. GitHub 릴리스 페이지에서 확인하세요."
            case .unsupportedLocation: "설치된 \(AppInfo.displayName) 를 찾지 못해 업데이트하지 못했습니다. 설치 명령으로 다시 설치하세요."
            case .notWritable(let folder):
                "\(folder) 폴더에 쓸 권한이 없어 업데이트를 설치하지 못했습니다. "
                    + "\(AppInfo.displayName) 를 ~/Applications 로 옮긴 뒤 다시 시도하세요."
            case .download: "업데이트 파일을 내려받지 못했습니다."
            case .invalidArchive: "업데이트 파일을 열 수 없습니다."
            case .invalidSignature: "업데이트 파일의 코드 서명을 확인할 수 없습니다."
            case .wrongApp: "업데이트 파일이 \(AppInfo.displayName) 앱이 아닙니다."
            case .wrongVersion: "업데이트 파일의 버전이 릴리스 정보와 다릅니다."
            case .wrongTeam: "업데이트 파일의 서명 팀이 설치된 앱과 다릅니다."
            case .helper: "앱 교체 프로세스를 시작하지 못했습니다."
            }
        }
    }

    static func prepare(_ release: UpdateCheck.Release, ghPath: String) async throws -> Prepared {
        guard let assetURL = release.assetURL else { throw Failure.noAsset }
        let runningApp = Bundle.main.bundleURL.resolvingSymlinksInPath()
        guard runningApp.pathExtension == "app",
              Bundle.main.bundleIdentifier == "dev.itaehyeok.PRayer" else { throw Failure.unsupportedLocation }
        // 다운로드 폴더에서 바로 연 앱은 macOS 가 읽기 전용 임시 위치에서 실행한다(App Translocation).
        // 응용 프로그램 폴더 밖이면 그 옆이 아니라 응용 프로그램 폴더에 깐다.
        let plan: InstallPlan
        switch UpdateInstallTarget.plan(running: runningApp, home: FileManager.default.homeDirectoryForCurrentUser) {
        case .success(let found): plan = found
        case .failure(.notWritable(let folder)):
            throw Failure.notWritable((folder as NSString).abbreviatingWithTildeInPath)
        }
        let installedApp = plan.target
        // 그 자리에 무언가 있으면 PRayer 여야 바꿔 끼운다 — 실행 뒤에 옮기거나 지웠을 수 있다.
        if FileManager.default.fileExists(atPath: installedApp.path) {
            guard Bundle(url: installedApp)?.bundleIdentifier == Bundle.main.bundleIdentifier else {
                throw Failure.unsupportedLocation
            }
        } else if !plan.moves {
            throw Failure.unsupportedLocation
        }
        let parent = installedApp.deletingLastPathComponent()
        // ~/Applications 는 아직 없을 수 있다.
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        let work = FileManager.default.temporaryDirectory.appendingPathComponent("PRayer-update-\(UUID().uuidString)")
        try FileManager.default.createDirectory(at: work, withIntermediateDirectories: true)
        defer { try? FileManager.default.removeItem(at: work) }
        let archive = work.appendingPathComponent("PRayer.zip")
        if release.downloadWithCLI {
            guard await UpdateCheck.download(release, to: work, ghPath: ghPath) else { throw Failure.download }
            try FileManager.default.moveItem(
                at: work.appendingPathComponent(UpdateCheck.assetName(version: release.version)), to: archive)
        } else {
            let (downloaded, response) = try await URLSession.shared.download(from: assetURL)
            guard (response as? HTTPURLResponse)?.statusCode == 200 else { throw Failure.download }
            try FileManager.default.moveItem(at: downloaded, to: archive)
        }
        let size = try archive.resourceValues(forKeys: [.fileSizeKey]).fileSize ?? 0
        guard size > 0 && size < 500_000_000 else { throw Failure.download }
        let extracted = work.appendingPathComponent("unpacked")
        try FileManager.default.createDirectory(at: extracted, withIntermediateDirectories: true)
        guard run("/usr/bin/ditto", ["-x", "-k", archive.path, extracted.path]) != nil else {
            throw Failure.invalidArchive
        }
        let candidate = extracted.appendingPathComponent("PRayer.app")
        let attributes = try FileManager.default.attributesOfItem(atPath: candidate.path)
        guard attributes[.type] as? FileAttributeType == .typeDirectory else { throw Failure.invalidArchive }
        guard let bundle = Bundle(url: candidate),
              bundle.bundleIdentifier == Bundle.main.bundleIdentifier else { throw Failure.wrongApp }
        guard bundle.infoDictionary?["CFBundleShortVersionString"] as? String == release.version else {
            throw Failure.wrongVersion
        }
        guard verifySignature(candidate) else { throw Failure.invalidSignature }
        // 지금 도는 앱과 견준다. 옮겨 깔 자리에는 아직 앱이 없을 수 있다.
        guard let currentTeam = teamID(of: runningApp),
              let newTeam = teamID(of: candidate), currentTeam == newTeam else { throw Failure.wrongTeam }

        let staged = parent.appendingPathComponent(".PRayer-update-\(UUID().uuidString).app")
        try FileManager.default.moveItem(at: candidate, to: staged)
        return Prepared(stagedApp: staged, installedApp: installedApp, moves: plan.moves, leftover: plan.leftover,
                        version: release.version)
    }

    static func install(_ prepared: Prepared) throws {
        try launchHelper(stage: prepared.stagedApp, target: prepared.installedApp)
        if prepared.moves {
            AppMover.recordLeftover(prepared.leftover, destination: prepared.installedApp,
                                    version: prepared.version, reason: .update)
        }
    }

    /// 바꿔 끼우는 스크립트(UpdateHelperScript)를 띄운다. `stage` 가 nil 이면 놓지 않고 `target` 을 열기만 한다.
    /// 부른 쪽은 곧바로 앱을 끈다 — 스크립트가 종료를 기다렸다가 바꿔 끼운다.
    static func launchHelper(stage: URL?, target: URL) throws {
        let script = FileManager.default.temporaryDirectory.appendingPathComponent("PRayer-update-helper-\(UUID().uuidString).sh")
        try UpdateHelperScript.text().write(to: script, atomically: true, encoding: .utf8)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script.path, stage?.path ?? "", target.path,
                             String(ProcessInfo.processInfo.processIdentifier), AppPaths.logFile.path]
        do { try process.run() }
        catch {
            try? FileManager.default.removeItem(at: script)
            throw Failure.helper
        }
    }

    static func verifySignature(_ app: URL) -> Bool {
        run("/usr/bin/codesign", ["--verify", "--deep", "--strict", app.path]) != nil
    }

    private static func teamID(of app: URL) -> String? {
        guard let output = run("/usr/bin/codesign", ["-dvvv", app.path]) else { return nil }
        return output.split(separator: "\n")
            .first(where: { $0.hasPrefix("TeamIdentifier=") })
            .map { String($0.dropFirst("TeamIdentifier=".count)) }
    }

    @discardableResult
    private static func run(_ executable: String, _ arguments: [String]) -> String? {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: executable)
        process.arguments = arguments
        process.standardOutput = pipe
        process.standardError = pipe
        do { try process.run() } catch { return nil }
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { return nil }
        return String(data: output, encoding: .utf8)
    }
}
