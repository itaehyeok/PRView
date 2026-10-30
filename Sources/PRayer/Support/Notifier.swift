import Foundation
import AppKit
import UserNotifications
import PRayerCore

/// 알림은 상태 전이 시에만 보낸다(폴링마다 보내지 않는다).
/// 무슨 말을 띄울지는 `NotificationText`(Core)가 정한다 — 제목은 무슨 일, 본문은 어느 PR.
enum Notifier {
    static let prKeyInfoKey = "prKey"

    /// **사용자가 직접 요청했을 때만** 호출한다.
    /// 앱이 임의로 부르면 사용자가 대화상자에 답하기 전에 앱이 닫히는 등으로
    /// 거부 상태가 번들 ID 단위로 캐시되고 이후 요청이 계속 실패한다(실측).
    static func requestAuthorizationNow() async -> Bool {
        do {
            let granted = try await UNUserNotificationCenter.current()
                .requestAuthorization(options: [.alert, .sound])
            Log.info("알림 권한: \(granted ? "허용" : "거부")", "notify")
            return granted
        } catch {
            Log.error("알림 권한 요청 실패: \(error.localizedDescription)", "notify")
            return false
        }
    }

    /// 현재 권한 상태(설정 화면 표시용).
    static func authorizationState() async -> UNAuthorizationStatus {
        await UNUserNotificationCenter.current().notificationSettings().authorizationStatus
    }

    /// 소리는 내지 않는다(사용자 결정, 2026-10-30) — 배너로만 알린다. `content.sound` 를 비워 두면 조용하다.
    /// 본문도 없다 — 제목 한 줄만 띄운다(같은 날 결정).
    private static func send(id: String, _ title: String, prKey: String?) {
        let content = UNMutableNotificationContent()
        content.title = title
        if let prKey {
            content.userInfo = [prKeyInfoKey: prKey]
            content.threadIdentifier = "pr/\(prKey)"
        }
        let request = UNNotificationRequest(identifier: id, content: content, trigger: nil)
        UNUserNotificationCenter.current().add(request) { error in
            if let error {
                Log.error("알림 전송 실패: \(error.localizedDescription)", "notify")
            }
        }
    }

    static func reviewDone(record: ReviewRecord) {
        send(id: "done-\(record.id)", NotificationText.reviewDone, prKey: record.prKey)
    }

    static func reviewFailed(prKey: String) {
        send(id: "fail-\(prKey)-\(Date().timeIntervalSince1970)", NotificationText.reviewFailed, prKey: prKey)
    }

    /// PR 변화 알림. 클릭하면 해당 PR 로 이동한다.
    static func prChange(pr: PullRequestInfo, change: PRChange) {
        send(id: "change-\(pr.id)-\(change.title)-\(Date().timeIntervalSince1970)",
             NotificationText.prChange(change),
             prKey: pr.id)
    }

    /// 한 번에 여러 건이면 개별 알림 대신 묶어서 하나만 보낸다.
    static func prChangeSummary(count: Int) {
        send(id: "changes-\(Date().timeIntervalSince1970)",
             NotificationText.prChangeSummary(count: count),
             prKey: nil)
    }

    static func limitReached() {
        send(id: "limit-\(Date().timeIntervalSince1970)",
             NotificationText.limitReached,
             prKey: nil)
    }
}

/// 알림 클릭 시 해당 PR 로 이동.
final class NotificationRouter: NSObject, UNUserNotificationCenterDelegate, @unchecked Sendable {
    static let shared = NotificationRouter()
    /// AppModel 이 설정한다.
    @MainActor var onSelect: ((String) -> Void)?

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                                willPresent notification: UNNotification) async -> UNNotificationPresentationOptions {
        [.banner]
    }

    func userNotificationCenter(_ center: UNUserNotificationCenter,
                               didReceive response: UNNotificationResponse) async {
        let prKey = response.notification.request.content.userInfo[Notifier.prKeyInfoKey] as? String
        guard let prKey else { return }
        await MainActor.run {
            NSApp.activate(ignoringOtherApps: true)
            onSelect?(prKey)
        }
    }
}
