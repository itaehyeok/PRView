import Foundation

/// 이 PR 에만 쓸 리뷰 모델과 Effort — 리뷰 시작 자리의 두 칸에서 고른 것.
///
/// 기본값(설정의 `model`·`effort`)은 모든 PR 에 쓰고, 특정 PR 만 다르게 돌리고 싶을 때 여기에 남긴다
/// (예: 까다로운 PR 하나만 더 센 모델로). 예전에는 리뷰 버튼 우클릭으로 **한 번만** 다른 모델로 돌릴 수
/// 있었는데, 그 PR 을 다시 리뷰하면 또 골라야 했다. 고른 것을 기억해 그 PR 의 다음 리뷰에도 쓴다.
public struct PRReviewModel: Codable, Sendable, Equatable {
    /// `--model` 로 넘길 값. 계열 별칭(`opus`)이면 그 계열의 최신을 따라가고,
    /// 모델 이름(`claude-opus-5`)이면 그 버전으로 고정된다.
    public var model: String
    /// `EffortLevel` 값. 빈 문자열이면 Claude Code 기본값.
    public var effort: String
    public var chosenAt: Date

    public init(model: String, effort: String, chosenAt: Date = Date()) {
        self.model = model
        self.effort = effort
        self.chosenAt = chosenAt
    }

    /// 이만큼 지난 선택은 버린다. 머지·닫힌 PR 의 선택이 끝없이 쌓이지 않게 한다 —
    /// 리뷰가 몇 주씩 걸리는 PR 은 드물고, 버려져도 칩에서 다시 고르면 된다.
    public static let lifetime: TimeInterval = 60 * 86_400

    public static func pruned(_ choices: [String: PRReviewModel], now: Date) -> [String: PRReviewModel] {
        choices.filter { now.timeIntervalSince($0.value.chosenAt) < lifetime }
    }
}

/// 리뷰 한 번에 실제로 쓸 모델·Effort. 이 PR 만 따로 고른 것이 있으면 그것, 없으면 기본값.
public struct ReviewModelChoice: Sendable, Equatable {
    public var model: String
    public var effort: String
    /// 이 PR 만 따로 고른 값인가(기본값이 아닌가).
    public var isPRChoice: Bool

    public init(model: String, effort: String, isPRChoice: Bool) {
        self.model = model
        self.effort = effort
        self.isPRChoice = isPRChoice
    }
}
