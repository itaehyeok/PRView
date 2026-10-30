import AppKit
import PRayerCore

/// 켤 때 다른 PRayer 가 이미 떠 있으면 어느 쪽을 쓸지 묻는다(`SingleInstance` 주석).
@MainActor
enum InstanceGuard {
    /// `applicationWillFinishLaunching` 에서 부른다 — 창을 띄우고 데이터를 읽기(bootstrap) 전이다.
    ///
    /// 켜져 있는 것을 쓰기로 하면 **저장 없이** 바로 끝낸다(`exit`). 정상 종료(`NSApp.terminate`)는
    /// teardown 을 거치는데, 데이터를 아직 읽지 않은 이 앱이 빈 상태를 디스크에 쓸 수 있다.
    /// 지금 연 쪽을 쓰기로 하면 켜져 있던 쪽을 정상 종료시켜(그쪽이 들고 있던 것을 저장하고 끝난다)
    /// 그 뒤에 이쪽이 데이터를 읽는다.
    static func resolve() {
        guard let bundleID = Bundle.main.bundleIdentifier else { return }
        let peers = NSRunningApplication.runningApplications(withBundleIdentifier: bundleID)
            .filter { !$0.isTerminated && isAlive($0) }
        let overridden = ProcessInfo.processInfo.environment["PRAYER_DATA_DIR"] != nil
        guard let existing = SingleInstance.conflict(selfPID: ProcessInfo.processInfo.processIdentifier,
                                                     running: peers.map(instance),
                                                     dataDirOverridden: overridden),
              let other = peers.first(where: { $0.processIdentifier == existing.pid }) else { return }
        Log.info("다른 \(AppInfo.displayName) 가 켜져 있음: pid \(existing.pid) \(existing.path ?? "?") v\(existing.version ?? "?")", "app")

        // 미리 정한 답이면 묻지 않고, 창도 앞으로 가져오지 않는다(자동화 — 사람이 보고 있지 않다).
        let preset = UserDefaults.standard.string(forKey: SingleInstance.presetAnswerKey)
            .flatMap(SingleInstance.Answer.init(rawValue:))
        let answer = preset ?? ask(existing: existing)
        switch answer {
        case .existing:
            Log.info("켜져 있는 \(AppInfo.displayName) 를 쓰고 이쪽은 저장 없이 끝냄", "app")
            if preset == nil { _ = other.activate(from: .current, options: []) }
            exit(0)
        case .replace:
            replace(other, quietly: preset != nil)
        }
    }

    private static func ask(existing: SingleInstance.Instance) -> SingleInstance.Answer {
        NSApp.activate()
        let alert = NSAlert()
        alert.messageText = "\(AppInfo.displayName) 가 이미 켜져 있습니다"
        alert.informativeText = SingleInstance.explanation(existing: existing,
                                                           opened: instance(.current),
                                                           home: NSHomeDirectory())
        alert.alertStyle = .warning
        // 기본(⏎)은 아무것도 잃지 않는 쪽이다.
        alert.addButton(withTitle: "켜져 있는 것 쓰기")
        alert.addButton(withTitle: "그것을 끄고 이것 켜기")
        return alert.runModal() == .alertFirstButtonReturn ? .existing : .replace
    }

    /// 켜져 있는 쪽을 정상 종료시키고 끝날 때까지 기다린다. 못 끄면 그쪽을 쓰고 이쪽은 끝낸다.
    private static func replace(_ other: NSRunningApplication, quietly: Bool) {
        Log.info("켜져 있는 \(AppInfo.displayName)(pid \(other.processIdentifier))를 끄고 이쪽을 켬", "app")
        other.terminate()
        // 정상 종료는 1초도 안 걸린다. 곧바로 안 꺼지면 그쪽에 뜬 것이 막고 있다 — 돌고 있는 리뷰의 종료 안내는
        // 답해야 끝나고, 시트(시작 안내·편집 창)가 열려 있으면 macOS 가 종료 요청을 아예 받지 않는다(실측:
        // 시작 안내 시트가 뜬 사본은 바깥에서 보낸 terminate 에도 true 만 돌려주고 안 꺼졌다). 그래서 2초가 지나면
        // 그쪽을 앞으로 가져와 사람이 보게 하고, 15초까지만 기다린다 — 그동안 이쪽은 아무것도 안 보인다.
        let start = Date()
        var broughtForward = false
        while isAlive(other), Date().timeIntervalSince(start) < 15 {
            if !quietly, !broughtForward, Date().timeIntervalSince(start) > 2 {
                _ = other.activate(from: .current, options: [])
                broughtForward = true
            }
            RunLoop.current.run(until: Date().addingTimeInterval(0.2))
        }
        guard isAlive(other) else {
            if !quietly { NSApp.activate() }
            return
        }
        Log.info("켜져 있는 \(AppInfo.displayName) 가 15초 안에 꺼지지 않아 이쪽을 끝냄", "app")
        if !quietly {
            NSApp.activate()
            let alert = NSAlert()
            alert.messageText = "켜져 있는 \(AppInfo.displayName) 가 꺼지지 않았습니다"
            alert.informativeText = """
                그쪽에 열려 있는 창(시작 안내·편집 창, 돌고 있는 리뷰의 종료 안내 등)을 닫거나 답한 뒤 다시 여세요.
                이쪽은 켜지 않고 끝냅니다.
                """
            alert.runModal()
            _ = other.activate(from: .current, options: [])
        }
        exit(0)
    }

    /// 아직 살아 있는가. `isTerminated` 는 런루프가 돌아야 바뀌므로 프로세스에 직접 묻는 것과 함께 본다.
    private static func isAlive(_ app: NSRunningApplication) -> Bool {
        !app.isTerminated && kill(app.processIdentifier, 0) == 0
    }

    private static func instance(_ app: NSRunningApplication) -> SingleInstance.Instance {
        let url = app.bundleURL
        let version = url.flatMap { Bundle(url: $0)?.infoDictionary?["CFBundleShortVersionString"] as? String }
        return SingleInstance.Instance(pid: app.processIdentifier, path: url?.path, version: version)
    }
}
