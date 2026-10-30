import AppKit

#if DEBUG
/// 세션이 화면 확인용으로 띄운 사본(데모 모드나 `PRAYER_DEBUG_*` 로 켠 것)의 창을 다른 앱 창 **뒤**에 깐다.
///
/// `open -g` 로 띄우면 포커스는 안 뺏지만 창은 맨 앞 앱 바로 아래 층에 놓여 다른 앱 창을 덮는다(실측 2026-10-27:
/// Claude 바로 아래, Chrome 위). 그래서 작업할 때마다 Jamie 같은 데모 창이 사용자 화면에 튀어나와 보였다.
/// 창을 보통 창보다 한 층 아래(-1)에 두면 모든 앱 창 뒤로 가고, 가려져 있어도 `screencapture -l` 로는 그대로 찍힌다(실측).
/// 화면 밖으로 빼는 것은 안 된다 — 창이 아예 그려지지 않아 캡처가 실패한다(실측).
///
/// 사람이 Dock·⌘Tab 으로 불러 앱이 켜지면 창을 제 층으로 돌리고 그 뒤로는 손대지 않는다. `-g` 없이 `open` 해서
/// 처음부터 켜진 사본도 같다 — 사용자에게 보여 주려고 띄운 사본은 늘 앞에 뜬다.
/// 성능 실측처럼 창이 보이는 채로 돌아야 하면 `PRAYER_DEBUG_KEEP_LAYER=1` 로 끈다.
@MainActor
enum BackgroundCopy {
    private static let behind = NSWindow.Level(rawValue: NSWindow.Level.normal.rawValue - 1)
    private static var isOn = false
    private static var observers: [NSObjectProtocol] = []
    /// 창이 다 가려지면 App Nap 이 타이머를 늦춰 `DebugLaunch` 의 몇 초 기다림이 길어진다. 켜 있는 동안 막는다.
    private static var activity: NSObjectProtocol?

    /// `applicationWillFinishLaunching` 에서 부른다 — 앱이 켜지기(didBecomeActive) 전에 지켜보기 시작해야 한다.
    static func start() {
        let environment = ProcessInfo.processInfo.environment
        let automated = DemoMode.isOn || environment.keys.contains { $0.hasPrefix("PRAYER_DEBUG_") }
        guard automated, environment["PRAYER_DEBUG_KEEP_LAYER"] == nil else { return }
        isOn = true
        activity = ProcessInfo.processInfo.beginActivity(options: .userInitiatedAllowingIdleSystemSleep,
                                                         reason: "확인용 사본을 뒤에 깔아 둔다")
        let center = NotificationCenter.default
        // 창은 SwiftUI 가 언제든 새로 띄운다(본창·설정·시트). 이벤트 한 바퀴마다 보통 층 창만 내린다.
        observers.append(center.addObserver(forName: NSApplication.didUpdateNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { lower() }
        })
        observers.append(center.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil, queue: .main) { _ in
            MainActor.assumeIsolated { stop() }
        })
    }

    private static func lower() {
        guard isOn, !NSApp.isActive else { return }
        for window in NSApp.windows where window.level == .normal {
            window.level = behind
        }
    }

    private static func stop() {
        guard isOn else { return }
        isOn = false
        observers.forEach(NotificationCenter.default.removeObserver)
        observers = []
        activity.map(ProcessInfo.processInfo.endActivity)
        activity = nil
        for window in NSApp.windows where window.level == behind {
            window.level = .normal
        }
    }
}
#endif
