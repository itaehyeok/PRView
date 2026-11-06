import Foundation

/// 툴바 "상태" 아이콘이 알리는 단계. 엔진은 `Settings.watchedEngines` 만 본다(깔려 있기만 한 엔진은 빠진다).
public enum ConnectionHealth: String, Sendable, CaseIterable {
    /// 켜고 기본 엔진·GitHub 을 아직 확인하는 중. 빨강은 확인한 뒤 안 된 것에만 쓴다.
    case checking
    case ok
    /// 쓸 수는 있다 — 갱신이 흔들리거나, 기본이 아닌 연결해 둔 엔진이 끊겼다.
    case warning
    /// 리뷰나 목록이 안 돈다 — 기본 엔진을 못 쓰거나 GitHub 이 끊겼다.
    case error

    /// - Parameters:
    ///   - watched: 지켜볼 엔진(`Settings.watchedEngines`). 기본 엔진은 따로 받아 늘 본다.
    ///   - status: 엔진의 마지막 확인 결과. 아직 확인하지 않았으면 nil.
    ///   - githubChecked: GitHub 계정을 한 번이라도 확인했는가(성공이든 실패든).
    public static func level(primary: ReviewEngineKind,
                             watched: [ReviewEngineKind],
                             status: (ReviewEngineKind) -> EngineStatus?,
                             githubChecked: Bool,
                             githubConnected: Bool,
                             refreshFailing: Bool) -> ConnectionHealth {
        // 확인한 뒤 안 된 것만 실패다. 아직 확인 전(nil)은 실패가 아니다.
        func failed(_ engine: ReviewEngineKind) -> Bool { status(engine).map { !$0.isReady } ?? false }
        if failed(primary) || (githubChecked && !githubConnected) { return .error }
        if refreshFailing || watched.contains(where: { $0 != primary && failed($0) }) { return .warning }
        if status(primary) == nil || !githubChecked { return .checking }
        return .ok
    }
}
