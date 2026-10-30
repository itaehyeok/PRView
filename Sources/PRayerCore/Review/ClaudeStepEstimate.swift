import Foundation

/// 지난 리뷰 1건에서 "Claude 가 읽고 판단" 에 걸린 시간과 그 PR 의 변경 줄 수.
public struct ClaudeStepSample: Sendable, Equatable {
    public var lines: Int
    public var seconds: Double
    public var date: Date

    public init(lines: Int, seconds: Double, date: Date) {
        self.lines = lines
        self.seconds = seconds
        self.date = date
    }
}

/// 리뷰 중 가장 오래 걸리는 "Claude 가 읽고 판단" 이 이번엔 얼마쯤 걸릴지 — 90% 가 들어오는 범위.
///
/// 다른 단계는 몇 초면 끝나 예상을 붙이지 않는다. 기다리게 만드는 건 이 단계 하나다(2026-10-27 사용자 결정).
///
/// 변경 줄 수 × 줄당 평균 초로 곱하면 큰 PR 에서 크게 틀린다. 지난 리뷰 155건을 맞춰 보니 시간은 줄 수에 따라
/// 늘다가 멈춘다(3,000줄을 34분으로 잡는데 실제는 2분 남짓). 그래서
/// ① 비슷한 크기(절반~2배) 지난 리뷰의 중앙값을 "보통" 으로 잡고
/// ② 지난 리뷰들이 그 "보통" 에서 몇 배로 빗나갔는지의 5%·95% 를 곱해 범위를 만든다.
/// 비슷한 크기 기록의 5%·95% 를 바로 쓰면 근거가 5~15건뿐이라 범위가 좁게 잡혀 실제로 72% 만 들어왔다.
/// ②는 같은 기록에서 93% 가 들어왔다(앞선 기록만으로 예상하는 백테스트, 2026-10-27).
public enum ClaudeStepEstimate {
    /// 이보다 적으면 범위를 내지 않는다 — 몇 건으로 만든 범위는 믿을 수 없다.
    public static let minimumSamples = 10
    /// 빗나간 비율을 재기 전에 앞에 깔아 둘 기록 수. 처음 몇 건은 "비슷한 크기" 를 고를 근거가 없다.
    static let warmUp = 5
    static let minimumRatios = 8
    /// 비슷한 크기가 이보다 적으면 크기가 가까운 순으로 채운다.
    static let minimumNeighbors = 5
    static let fallbackNeighbors = 8

    /// 90% 범위(초). 기록이 모자라면 nil.
    public static func range(lines: Int, samples: [ClaudeStepSample]) -> ClosedRange<Double>? {
        let sorted = samples.filter { $0.seconds > 0 }.sorted { $0.date < $1.date }
        guard sorted.count >= minimumSamples else { return nil }
        // 각 기록을 그보다 앞선 기록만으로 예상해 봤을 때 실제가 몇 배였나.
        var ratios: [Double] = []
        for index in warmUp..<sorted.count {
            let typical = median(neighbors(of: sorted[index].lines, in: sorted[..<index]).map(\.seconds))
            if typical > 0 { ratios.append(sorted[index].seconds / typical) }
        }
        guard ratios.count >= minimumRatios else { return nil }
        let typical = median(neighbors(of: lines, in: sorted[...]).map(\.seconds))
        let lower = typical * quantile(ratios, 0.05)
        let upper = typical * quantile(ratios, 0.95)
        guard lower > 0, upper >= lower else { return nil }
        return lower...upper
    }

    static func neighbors(of lines: Int, in samples: ArraySlice<ClaudeStepSample>) -> [ClaudeStepSample] {
        let near = samples.filter { Double($0.lines) >= Double(lines) * 0.5 && Double($0.lines) <= Double(lines) * 2 }
        if near.count >= minimumNeighbors { return near }
        return Array(samples.sorted { abs($0.lines - lines) < abs($1.lines - lines) }.prefix(fallbackNeighbors))
    }

    static func median(_ values: [Double]) -> Double {
        quantile(values, 0.5)
    }

    /// 선형 보간 분위수(numpy 기본값과 같다).
    static func quantile(_ values: [Double], _ p: Double) -> Double {
        let sorted = values.sorted()
        guard let first = sorted.first else { return 0 }
        guard sorted.count > 1 else { return first }
        let position = Double(sorted.count - 1) * p
        let lower = Int(position.rounded(.down))
        let upper = Int(position.rounded(.up))
        return sorted[lower] + (sorted[upper] - sorted[lower]) * (position - Double(lower))
    }

    /// 범위 글자 — `13초 ~ 1:23`, `0:47 ~ 5:25`. 위 끝은 올려 "늦어도" 보다 짧게 말하지 않는다.
    public static func text(_ range: ClosedRange<Double>) -> String {
        "\(clock(range.lowerBound.rounded(.down))) ~ \(clock(range.upperBound.rounded(.up)))"
    }

    /// `8초`, `1:08` — 진행 카드의 단계별 시간도 같은 꼴로 적는다.
    public static func clock(_ seconds: Double) -> String {
        let value = max(0, Int(seconds))
        return value < 60 ? "\(value)초" : "\(value / 60):\(String(format: "%02d", value % 60))"
    }

    /// 모델 이름을 견줄 꼴로 — 대소문자와 `[1m]` 같은 꼬리를 뗀다.
    public static func modelKey(_ model: String) -> String {
        let lowered = model.lowercased()
        guard let bracket = lowered.firstIndex(of: "[") else { return lowered }
        return String(lowered[..<bracket])
    }
}
