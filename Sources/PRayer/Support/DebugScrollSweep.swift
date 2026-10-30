import AppKit
import PRayerCore

/// `PRAYER_DEBUG_SCROLL_SWEEP=pt`(DebugLaunch) — 변경 파일 탭의 diff 를 그 pt 씩 맨 위 → 맨 아래 → 맨 위로 훑는다.
/// 메인 스레드가 0.25초 넘게 막히면 그 시간을, 3초 넘게 답하지 않으면 그때의 스크롤 위치를 로그(`debug`)에 남긴다.
///
/// 지연 스택(LazyVStack)의 레이아웃 무한 루프는 **특정 스크롤 위치에서만** 걸린다(2026-10-21 실측: 같은 화면을
/// 띄우기만 해서는 안 걸렸다). 이 세션에는 스크롤 이벤트를 보낼 권한이 없어서, 앱 안에서 diff 의 NSScrollView 를
/// 직접 움직인다. 멈추면 메인 스레드가 이 훑기도 같이 멈추므로, 마지막으로 적어 둔 위치가 곧 걸린 자리다.
@MainActor
enum DebugScrollSweep {
    /// - Parameter keyToggles: 한 칸 움직일 때마다 키 창을 화면 밖 패널로 넘겼다 돌려받는 횟수(0 이면 안 한다).
    ///   창이 키를 잃고 얻을 때 AppKit 컨트롤이 모양을 다시 정하는데, 그 무효화가 지연 스택의 배치 도중에 끼면 같은
    ///   배치로 다시 들어간다(cmux #8224 가 같은 스택으로 겪은 것). 사용자가 다른 앱으로 갔다 오는 것을 흉내 낸다.
    static func run(step: CGFloat, keyToggles: Int) async {
        // 감시는 변경 파일 탭이 열리기 전부터 돌린다 — 파일을 처음 그리는 동안 막힌 시간도 잰다(큰 파일 확인용).
        let watchdog = HangWatchdog()
        watchdog.start()
        defer { watchdog.stop() }
        // 따라가기(2초 뒤)나 파일 고르기가 변경 파일 탭을 열고 그 줄로 스크롤한 다음에 훑는다.
        try? await Task.sleep(for: .seconds(6))

        guard let window = NSApp.windows.first(where: { $0.isVisible && $0.title == AppInfo.displayName }) ?? NSApp.mainWindow,
              let root = window.contentView, let scrollView = diffScrollView(in: root) else {
            Log.info("스윕: diff 스크롤뷰를 못 찾음", "debug")
            return
        }
        let clip = scrollView.contentView
        let decoy = NSPanel(contentRect: NSRect(x: -10_000, y: -10_000, width: 10, height: 10),
                            styleMask: [.titled], backing: .buffered, defer: false)
        if keyToggles > 0 { decoy.orderFrontRegardless() }
        defer { decoy.orderOut(nil) }
        Log.info("스윕 시작: 한 번에 \(step)pt\(keyToggles > 0 ? " · 키 창 넘기기 \(keyToggles)번" : ""), 문서 높이 \(Int(scrollView.documentView?.frame.height ?? 0))", "debug")

        var y = clip.bounds.origin.y
        for goingDown in [false, true, false] {
            while true {
                // 지연 스택은 훑는 동안 추정 높이가 바뀌어 문서 높이도 바뀐다. 매번 다시 잰다.
                let maxY = max(0, (scrollView.documentView?.frame.height ?? 0) - clip.bounds.height)
                let target = goingDown ? maxY : 0
                if abs(target - y) < 0.5 { break }
                y = goingDown ? min(target, y + step) : max(target, y - step)
                watchdog.note(offset: y, documentHeight: scrollView.documentView?.frame.height ?? 0)
                clip.scroll(to: NSPoint(x: clip.bounds.origin.x, y: y))
                scrollView.reflectScrolledClipView(clip)
                try? await Task.sleep(for: .milliseconds(40))
                for _ in 0..<keyToggles {
                    decoy.makeKey()
                    try? await Task.sleep(for: .milliseconds(30))
                    window.makeKey()
                    try? await Task.sleep(for: .milliseconds(30))
                }
            }
        }
        Log.info("스윕 끝", "debug")
    }

    /// 창에서 가장 오른쪽에 있는 큰 스크롤뷰가 diff 다(왼쪽부터 PR 목록 · 파일 트리 · diff).
    /// 코드 코멘트 카드 안의 입력칸도 NSScrollView 라 높이로 거른다.
    private static func diffScrollView(in root: NSView) -> NSScrollView? {
        var found: [NSScrollView] = []
        func walk(_ view: NSView) {
            if let scroll = view as? NSScrollView { found.append(scroll) }
            view.subviews.forEach(walk)
        }
        walk(root)
        return found
            .filter { $0.frame.height > 200 }
            .max { $0.convert($0.bounds, to: nil).minX < $1.convert($1.bounds, to: nil).minX }
    }
}

/// 메인 스레드에 0.1초마다 신호를 보내 답이 오기까지 걸린 시간을 잰다.
/// 메인 스레드가 멈춘 동안에도 돌아야 하므로 따로 스레드를 쓴다.
private final class HangWatchdog: @unchecked Sendable {
    private let lock = NSLock()
    private var offset: CGFloat = 0
    private var documentHeight: CGFloat = 0
    private var running = true

    func note(offset: CGFloat, documentHeight: CGFloat) {
        lock.withLock {
            self.offset = offset
            self.documentHeight = documentHeight
        }
    }

    func start() {
        Thread.detachNewThread { [self] in
            while lock.withLock({ running }) {
                let answered = DispatchSemaphore(value: 0)
                let sent = Date()
                DispatchQueue.main.async { answered.signal() }
                if answered.wait(timeout: .now() + 3) == .timedOut {
                    let (at, height) = lock.withLock { (offset, documentHeight) }
                    Log.info("스윕: 메인 스레드 멈춤 — 스크롤 위치 \(Int(at)) / 문서 높이 \(Int(height))", "debug")
                    // 무한 루프면 여기서 영영 기다린다. 이미 남겼으니 그래도 된다. 풀리면 걸린 시간을 남긴다.
                    answered.wait()
                    Log.info("스윕: \(Self.milliseconds(since: sent))ms 만에 풀림", "debug")
                } else if Date().timeIntervalSince(sent) > 0.25 {
                    let at = lock.withLock { offset }
                    Log.info("스윕: 메인 스레드 \(Self.milliseconds(since: sent))ms 막힘 — 스크롤 위치 \(Int(at))", "debug")
                }
                Thread.sleep(forTimeInterval: 0.1)
            }
        }
    }

    func stop() {
        lock.withLock { running = false }
    }

    private static func milliseconds(since date: Date) -> Int {
        Int(Date().timeIntervalSince(date) * 1000)
    }
}
