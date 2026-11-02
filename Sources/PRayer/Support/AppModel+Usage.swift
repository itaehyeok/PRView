import Foundation
import PRayerCore

/// 사용 통계(`UsageStats`) — 세기·하루 한 번 보내기.
///
/// Info.plist 에 App ID 가 있는 빌드만 세고 보낸다. 없으면(개발 빌드·포크)·데모 모드는 세지도 보내지도 않는다.
/// 화면에 안내를 띄우지 않는다(2026-11-02 사용자 결정).
extension AppModel {
    /// 보낼 곳. nil 이면 이 빌드는 사용 통계를 쓰지 않는다.
    static let usageConfig: UsageStatsConfig? = {
        if DemoMode.isOn { return nil }
        #if DEBUG
        // 개발 빌드에서 보내 보려면 환경변수로 준다. 늘 테스트 표시를 달아 대시보드의 실제 숫자에 섞이지 않게 한다.
        let env = ProcessInfo.processInfo.environment
        return UsageStatsConfig(appID: env["PRAYER_TELEMETRY_APP_ID"], namespace: env["PRAYER_TELEMETRY_NAMESPACE"],
                                isTestMode: true)
        #else
        let info = Bundle.main.infoDictionary
        return UsageStatsConfig(appID: info?["PRayerTelemetryAppID"] as? String,
                                namespace: info?["PRayerTelemetryNamespace"] as? String, isTestMode: false)
        #endif
    }()

    /// 한 번 보내 보고 다음을 볼 때까지 기다리는 시간. 앱을 며칠씩 켜 두므로 켤 때만 보내면 날이 밀린다.
    private static let usageFlushInterval: Duration = .seconds(3600)

    func loadUsageStats() async {
        guard Self.usageConfig != nil else { return }
        usageStats = await store.loadUsageStats() ?? UsageStats()
        // 읽기 전에 센 것은 읽은 파일에 덮이므로, 읽은 뒤부터 센다.
        usageStats.noteStarted(day: UsageStats.dayKey(Date()))
        recordUsage(.appLaunch)
        Task { [weak self] in
            while !Task.isCancelled {
                await self?.flushUsage()
                try? await Task.sleep(for: Self.usageFlushInterval)
            }
        }
    }

    func recordUsage(_ event: UsageStats.Event) {
        guard Self.usageConfig != nil else { return }
        let before = usageStats
        usageStats.record(event, day: UsageStats.dayKey(Date()))
        if usageStats != before { saveUsageStats() }
    }

    func setUsageEnabled(_ on: Bool) {
        usageStats.setEnabled(on)
        Log.info("사용 통계 보내기 \(on ? "켬" : "끔")", "usage")
        saveUsageStats()
    }

    /// 다 지난 날을 하나씩 보낸다. 실패하면 남겨 두고 다음 차례에 다시 보낸다.
    func flushUsage() async {
        guard let config = Self.usageConfig, let endpoint = config.endpoint else { return }
        let client = UsageStatsClient(appVersion: UpdateCheck.currentVersion(), betaNumber: UpdateCheck.betaNumber(),
                                      osVersion: UsageStatsClient.osVersion(ProcessInfo.processInfo.operatingSystemVersion))
        for day in usageStats.pendingDays(today: UsageStats.dayKey(Date())) {
            guard let body = usageStats.body(for: day, config: config, client: client) else { continue }
            guard await postUsage(body, to: endpoint) else { return }
            // 보내는 동안 사람이 껐으면 그 뒤로는 아무것도 남기지 않는다(끌 때 이미 비웠다).
            guard usageStats.enabled else { return }
            usageStats.markSent(day: day, body: body, at: Date())
            saveUsageStats()
            Log.info("사용 통계 보냄 \(day)\(config.isTestMode ? " (테스트)" : "")", "usage")
        }
    }

    private func postUsage(_ body: String, to endpoint: URL) async -> Bool {
        var request = URLRequest(url: endpoint, timeoutInterval: 30)
        request.httpMethod = "POST"
        request.setValue("application/json; charset=utf-8", forHTTPHeaderField: "Content-Type")
        request.httpBody = Data(body.utf8)
        do {
            let (_, response) = try await URLSession.shared.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? 0
            guard (200..<300).contains(status) else {
                Log.info("사용 통계 보내기 실패 — HTTP \(status)", "usage")
                return false
            }
            return true
        } catch {
            // 오프라인·차단은 흔하고 사용자가 할 일도 없다. 문제 기록(ProblemLog)에 올리지 않는다.
            Log.info("사용 통계 보내기 실패 — \(error.localizedDescription)", "usage")
            return false
        }
    }

    private func saveUsageStats() {
        let snapshot = usageStats
        Task { await store.save(usageStats: snapshot) }
    }
}
