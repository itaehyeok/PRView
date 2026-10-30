import AppKit
import Foundation
import PRayerCore

/// "응용 프로그램 폴더로 옮길까요?" — 받은 zip 을 다운로드 폴더 등에서 바로 연 앱을 제자리로 옮긴다.
///
/// 그 자리에서 열면 macOS 가 앱을 읽기 전용 임시 위치에서 실행해(App Translocation) 앱 안 업데이트가
/// 막혔다(팀원 맥, 2026-10-01). 켤 때 한 번 묻고, 옮기면 사본을 응용 프로그램 폴더에 놓고 새 자리에서
/// 다시 켠다. 안 옮긴 채 업데이트를 눌러도 응용 프로그램 폴더로 옮겨 깐다(AppUpdater).
///
/// 원래 앱은 **새 자리에서 켠 뒤에** 치운다 — 옮기다 실패해도 쓸 앱이 하나는 남게.
/// 다운로드 폴더는 macOS 가 따로 지키는 폴더라, 치울 때 접근을 묻는 창이 한 번 뜰 수 있다.
enum AppMover {
    /// "다시 묻지 않기"
    static let declineKey = "moveToApplicationsDeclined"
    /// 새 자리에서 켠 뒤 치울 원래 앱. 앱 사본끼리 UserDefaults(번들 ID 단위)를 같이 쓰는 것으로 넘긴다.
    static let leftoverKey = "moveLeftover"
    /// 자동화 탈출구(실측용): `defaults write dev.itaehyeok.PRayer moveToApplicationsAnswer -string move` 면
    /// 묻지 않고 옮기고, `later` 면 묻지 않고 넘어간다. 종료 안내의 `skipQuitGuard` 와 같은 용도 —
    /// 창을 누를 수 없는 실측(공증된 베타를 격리 실행으로 띄워 보기)에서 쓴다.
    static let presetAnswerKey = "moveToApplicationsAnswer"

    enum Reason: String, Sendable { case move, update }

    private static let bundleID = "dev.itaehyeok.PRayer"

    /// 소스로 빌드한 것(DerivedData·build 폴더에서 뜬다)은 묻지 않는다.
    private static var isDevelopmentBuild: Bool {
        #if DEBUG
        true
        #else
        false
        #endif
    }

    enum MoveError: LocalizedError {
        case occupied(String)
        case invalidCopy

        var errorDescription: String? {
            switch self {
            case .occupied(let path): "\(path) 에 \(AppInfo.displayName) 가 아닌 앱이 있습니다."
            case .invalidCopy: "복사한 앱의 코드 서명을 확인할 수 없습니다."
            }
        }
    }

    // MARK: - 켤 때

    /// 앱이 뜬 직후 한 번(AppDelegate). 옮겨 깔고 새 자리에서 켰으면 원래 앱을 치우고,
    /// 응용 프로그램 폴더 밖이면 옮길지 묻는다.
    @MainActor
    static func launchTasks() {
        if let record = LeftoverRecord.load() {
            let running = Bundle.main.bundleURL.resolvingSymlinksInPath()
            // 다운로드 폴더 접근을 묻는 창이 뜨면 대답할 때까지 파일 호출이 멈춘다 — 메인 스레드에서 하지 않는다.
            Task.detached(priority: .utility) {
                let outcome = cleanUp(record, running: running)
                await MainActor.run { show(outcome, reason: record.reason) }
            }
        }
        // 창이 먼저 뜨게 한 박자 늦춘다.
        DispatchQueue.main.async { offerIfNeeded() }
    }

    @MainActor
    private static func offerIfNeeded() {
        guard !isDevelopmentBuild, !RuntimeEnvironment.isRunningTests,
              !UserDefaults.standard.bool(forKey: declineKey) else { return }
        let running = Bundle.main.bundleURL.resolvingSymlinksInPath()
        guard running.pathExtension == "app", Bundle.main.bundleIdentifier == bundleID else { return }
        let home = FileManager.default.homeDirectoryForCurrentUser
        guard case .misplaced(let original) = AppPlacement.placement(of: running, home: home) else { return }
        let destination = AppPlacement.destination(home: home)
        let here = AppPlacement.describe(original, home: home)
        Log.info("응용 프로그램 폴더 밖에서 실행 중: \(original?.path ?? "격리 실행(원래 위치 모름)") → 옮길 자리 \(destination.path)", "app")

        switch UserDefaults.standard.string(forKey: presetAnswerKey) {
        case "move":
            Log.info("응용 프로그램 폴더로 옮기기: 미리 정한 답(move)", "app")
        case "later":
            return
        default:
            guard askToMove(here: here, destination: destination, home: home) else { return }
        }
        do {
            try move(running: running, original: original, to: destination)
            Log.info("응용 프로그램 폴더로 옮김 → \(destination.path), 다시 켠다", "app")
            NSApp.terminate(nil)
        } catch {
            Log.error("응용 프로그램 폴더로 옮기지 못함: \(error.localizedDescription)", "app", problem: .appMoveFailed)
            let failure = NSAlert()
            failure.alertStyle = .warning
            failure.messageText = "옮기지 못했습니다"
            failure.informativeText = """
                \(error.localizedDescription)

                \(AppInfo.displayName) 를 끈 뒤 Finder 에서 응용 프로그램 폴더로 끌어다 놓아 주세요.
                """
            failure.runModal()
        }
    }

    /// "응용 프로그램 폴더로 옮길까요?" — 옮기기를 누르면 true.
    @MainActor
    private static func askToMove(here: String, destination: URL, home: URL) -> Bool {
        let alert = NSAlert()
        alert.messageText = "응용 프로그램 폴더로 옮길까요?"
        alert.informativeText = """
            \(AppInfo.displayName) 가 \(here)에서 실행되고 있습니다. 앱은 응용 프로그램 폴더에 있어야 업데이트가 깔끔하고, \
            폴더를 정리하다 지워질 일도 없습니다.

            옮기면 \(AppPlacement.destinationLabel(destination, home: home))에 넣고 바로 다시 켭니다. \
            설정과 초안은 그대로입니다.
            """
        alert.addButton(withTitle: "옮기기")
        alert.addButton(withTitle: "나중에")
        alert.showsSuppressionButton = true
        alert.suppressionButton?.title = "다시 묻지 않기"
        NSApp.activate()
        guard alert.runModal() == .alertFirstButtonReturn else {
            let suppressed = alert.suppressionButton?.state == .on
            if suppressed { UserDefaults.standard.set(true, forKey: declineKey) }
            Log.info("응용 프로그램 폴더로 옮기기: 나중에\(suppressed ? "(다시 묻지 않기)" : "")", "app")
            return false
        }
        return true
    }

    /// 사본을 옮길 자리 옆에 준비하고, 앱이 꺼지면 바꿔 끼워 새 자리에서 켜는 스크립트를 띄운다.
    /// 부른 쪽이 곧바로 앱을 끈다.
    @MainActor
    private static func move(running: URL, original: URL?, to destination: URL) throws {
        let folder = destination.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: folder, withIntermediateDirectories: true)
        var stage: URL?
        var version = UpdateCheck.currentVersion()
        if FileManager.default.fileExists(atPath: destination.path) {
            guard let existing = Bundle(url: destination), existing.bundleIdentifier == bundleID else {
                throw MoveError.occupied((destination.path as NSString).abbreviatingWithTildeInPath)
            }
            let existingVersion = existing.infoDictionary?["CFBundleShortVersionString"] as? String
            if AppPlacement.shouldReplace(existingVersion: existingVersion, with: version) {
                stage = try makeStage(from: running, in: folder)
            } else if let existingVersion {
                // 같거나 더 새 버전이 이미 있으면 덮지 않고 그걸 켠다.
                version = existingVersion
            }
        } else {
            stage = try makeStage(from: running, in: folder)
        }
        do {
            try AppUpdater.launchHelper(stage: stage, target: destination)
        } catch {
            if let stage { try? FileManager.default.removeItem(at: stage) }
            throw error
        }
        recordLeftover(original, destination: destination, version: version, reason: .move)
    }

    private static func makeStage(from running: URL, in folder: URL) throws -> URL {
        let stage = folder.appendingPathComponent(".PRayer-move-\(UUID().uuidString).app")
        do {
            try AppBundleCopy.copy(running, to: stage)
            try AppBundleCopy.removeQuarantine(at: stage)
            guard AppUpdater.verifySignature(stage) else { throw MoveError.invalidCopy }
        } catch {
            try? FileManager.default.removeItem(at: stage)
            throw error
        }
        return stage
    }

    // MARK: - 새 자리에서 켠 뒤

    /// 옮겨 깔고 나서 치울 원래 앱을 남긴다. 업데이트로 옮겨 깔 때도 쓴다.
    /// `version` 은 바꿔 끼운 뒤 `destination` 에서 켜질 버전 — 교체가 안 됐는데(종료 안내에서 취소 등)
    /// 그 자리의 옛 앱을 켰을 때 원래 앱을 치우지 않게 견준다.
    static func recordLeftover(_ leftover: URL?, destination: URL, version: String, reason: Reason) {
        LeftoverRecord(app: leftover?.path, destination: destination.path, version: version, reason: reason).save()
    }

    struct LeftoverRecord: Sendable {
        var app: String?
        var destination: String
        var version: String
        var reason: Reason

        func save() {
            UserDefaults.standard.set(["app": app ?? "", "destination": destination, "version": version,
                                       "reason": reason.rawValue],
                                      forKey: AppMover.leftoverKey)
        }

        static func load() -> LeftoverRecord? {
            guard let raw = UserDefaults.standard.dictionary(forKey: AppMover.leftoverKey) as? [String: String],
                  let destination = raw["destination"] else { return nil }
            let app = raw["app"].flatMap { $0.isEmpty ? nil : $0 }
            return LeftoverRecord(app: app, destination: destination, version: raw["version"] ?? "",
                                  reason: Reason(rawValue: raw["reason"] ?? "") ?? .move)
        }

        static func clear() {
            UserDefaults.standard.removeObject(forKey: AppMover.leftoverKey)
        }
    }

    enum CleanupOutcome: Sendable {
        /// 옮긴 자리에서 켠 게 아니다(교체가 실패해 원래 앱을 다시 연 경우 등). 기록을 그대로 둔다.
        case notHere
        /// 그 자리에서 켜졌지만 바꿔 끼우기 전 버전이다(종료를 취소해 교체가 안 된 경우). 기록만 지운다.
        case notSwitched
        /// 원래 앱이 어디였는지 모른다(격리 실행인데 원래 위치를 못 찾음).
        case unknownOriginal
        case trashed(here: String)
        /// 원래 앱을 못 치웠다 — 읽을 수 없었거나(접근을 허용하지 않음 등) 휴지통으로 못 보냈다.
        case leftBehind(path: String, here: String)
        /// 치울 게 없다(이미 지웠거나, 치우면 안 되는 자리).
        case nothingToDo
    }

    private static func cleanUp(_ record: LeftoverRecord, running: URL) -> CleanupOutcome {
        guard URL(fileURLWithPath: record.destination).standardizedFileURL.path == running.standardizedFileURL.path else {
            return .notHere
        }
        LeftoverRecord.clear()
        // 그 자리에 있던 옛 앱이다 — 바꿔 끼우기가 일어나지 않았다. 원래 앱이 아직 쓰던 앱일 수 있다.
        guard record.version == UpdateCheck.currentVersion() else { return .notSwitched }
        guard let path = record.app else { return .unknownOriginal }
        let home = FileManager.default.homeDirectoryForCurrentUser
        let leftover = URL(fileURLWithPath: path)
        guard AppPlacement.canDiscardLeftover(leftover, running: running, home: home) else { return .nothingToDo }
        let here = AppPlacement.describe(leftover, home: home)
        // 다운로드 폴더면 macOS 가 여기서 처음 접근을 묻는다(Info.plist 의 NSDownloadsFolderUsageDescription).
        guard let identifier = Bundle(url: leftover)?.bundleIdentifier else {
            return FileManager.default.fileExists(atPath: path) ? .leftBehind(path: path, here: here) : .nothingToDo
        }
        // 그 자리에 PRayer 가 아닌 것이 있으면 손대지 않는다.
        guard identifier == bundleID else { return .nothingToDo }
        do {
            try FileManager.default.trashItem(at: leftover, resultingItemURL: nil)
            Log.info("옮기기 전 앱을 휴지통으로: \(path)", "app")
            return .trashed(here: here)
        } catch {
            Log.error("옮기기 전 앱을 치우지 못함: \(path) — \(error.localizedDescription)", "app")
            return .leftBehind(path: path, here: here)
        }
    }

    @MainActor
    private static func show(_ outcome: CleanupOutcome, reason: Reason) {
        let moved = reason == .update ? "업데이트하면서 응용 프로그램 폴더로 옮겼습니다." : "응용 프로그램 폴더로 옮겼습니다."
        let banner: Banner
        switch outcome {
        case .notHere, .notSwitched:
            return
        case .nothingToDo:
            banner = Banner(kind: .info, message: moved)
        case .unknownOriginal:
            banner = Banner(kind: .info, message: moved + " 처음 받은 자리(다운로드 폴더 등)에 남은 \(AppInfo.displayName) 는 지워도 됩니다.")
        case .trashed(let here):
            banner = Banner(kind: .info, message: moved + " \(here)에 있던 예전 앱은 휴지통으로 보냈습니다.")
        case .leftBehind(let path, let here):
            let leftover = URL(fileURLWithPath: path)
            banner = Banner(kind: .warning,
                            message: moved + " \(here)에 남은 예전 \(AppInfo.displayName) 는 헷갈리지 않게 직접 지워 주세요.",
                            actionTitle: "Finder 에서 보기",
                            action: { NSWorkspace.shared.activateFileViewerSelecting([leftover]) })
        }
        AppDelegate.model?.banner = banner
    }
}

extension AppDelegate {
    @MainActor
    func applicationDidFinishLaunching(_ notification: Notification) {
        AppMover.launchTasks()
    }
}
