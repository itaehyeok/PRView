import Foundation

/// 어느 엔진을 지켜볼지. 맥에 CLI 가 깔려 있기만 한 엔진은 보지 않고, 이 앱에서 연결된 것을 본 적 있는 엔진만 본다 —
/// Claude 만 쓰는 사람이 Codex 를 깔아 두었다고 "Codex 로그인이 필요합니다" 를 띄우면 안 된다(2026-11-06 사용자 결정).
/// 한 번 연결된 엔진이 끊기면 그때 문제로 친다.
extension Settings {
    /// 기본 리뷰 엔진 — 리뷰 버튼을 누르면 이 엔진으로 돈다.
    public var primaryEngine: ReviewEngineKind { ReviewEngineKind(model: model) }

    /// 지켜볼 엔진 — 기본 엔진은 기록이 없어도 늘, 그 밖에는 `connectedEngines` 에 든 것만. 순서는 `ReviewEngineKind.allCases`.
    public var watchedEngines: [ReviewEngineKind] {
        ReviewEngineKind.allCases.filter { $0 == primaryEngine || connectedEngines.contains($0) }
    }

    /// 연결된 것을 본 엔진을 기록한다. 새로 들었으면 true(저장할 것).
    public mutating func noteEngineConnected(_ engine: ReviewEngineKind) -> Bool {
        guard !connectedEngines.contains(engine) else { return false }
        connectedEngines.append(engine)
        return true
    }
}
