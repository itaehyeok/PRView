import Foundation

/// 툴바 "상태" 아이콘이 알리는 단계. 엔진은 `Settings.watchedEngines` 만 본다(깔려 있기만 한 엔진은 빠진다).
///
/// 설정 › 연결의 엔진·GitHub 칸도 같은 판정(`engine`·`github`)으로 색을 정한다 — 툴바는 주황인데 설정은
/// 초록 "사용 가능" 처럼 두 곳이 다른 말을 하지 않게(2026-11-26 사용자 요청).
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

    /// 엔진 한 줄의 단계 — `level` 이 그 엔진을 어떻게 치는지와 같다.
    /// - Returns: nil 이면 지켜보지 않는 엔진이 안 되는 것이다. 툴바가 문제로 치지 않으니 경고색 없이 그린다.
    public static func engine(_ engine: ReviewEngineKind,
                              primary: ReviewEngineKind,
                              watched: [ReviewEngineKind],
                              status: EngineStatus?) -> ConnectionHealth? {
        guard let status else { return .checking }
        if status.isReady { return .ok }
        if engine == primary { return .error }
        return watched.contains(engine) ? .warning : nil
    }

    /// GitHub 한 줄의 단계 — `level` 이 GitHub 을 어떻게 치는지와 같다. 계정이 붙어 있어도 목록 갱신이 계속
    /// 실패하면 주황이다(설정이 계정만 보고 초록 "사용 가능" 을 그려 툴바와 어긋났다).
    public static func github(checked: Bool, connected: Bool, refreshFailing: Bool) -> ConnectionHealth {
        if checked && !connected { return .error }
        if refreshFailing { return .warning }
        return checked ? .ok : .checking
    }
}
