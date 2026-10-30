import XCTest
@testable import PRayerCore

/// "Claude 가 읽고 판단" 의 90% 범위. 줄 수에 곱하지 않고 비슷한 크기의 지난 리뷰로 잡는다.
final class ClaudeStepEstimateTests: XCTestCase {
    private func samples(_ pairs: [(lines: Int, seconds: Double)]) -> [ClaudeStepSample] {
        pairs.enumerated().map { index, pair in
            ClaudeStepSample(lines: pair.lines, seconds: pair.seconds, date: Date(timeIntervalSince1970: Double(index) * 60))
        }
    }

    func testNoRangeUntilEnoughReviews() {
        let few = samples(Array(repeating: (100, 60), count: ClaudeStepEstimate.minimumSamples - 1))
        XCTAssertNil(ClaudeStepEstimate.range(lines: 100, samples: few), "몇 건으로 만든 범위는 믿을 수 없다")
        let enough = samples(Array(repeating: (100, 60), count: ClaudeStepEstimate.minimumSamples + 3))
        XCTAssertNotNil(ClaudeStepEstimate.range(lines: 100, samples: enough))
    }

    func testSteadyHistoryGivesTightRange() {
        let steady = samples(Array(repeating: (200, 90), count: 20))
        XCTAssertEqual(ClaudeStepEstimate.range(lines: 200, samples: steady), 90...90)
    }

    func testBiggerPRGetsLaterRange() throws {
        // 작은 PR 은 20초 안팎, 큰 PR 은 2분 안팎. 섞어 쌓는다.
        var pairs: [(Int, Double)] = []
        for index in 0..<15 {
            let smallSeconds: Double = 18 + Double(index % 5)
            let largeSeconds: Double = 110 + Double(index % 7) * 3
            pairs.append((20 + index, smallSeconds))
            pairs.append((800 + index * 10, largeSeconds))
        }
        let history = samples(pairs)
        let small = try XCTUnwrap(ClaudeStepEstimate.range(lines: 25, samples: history))
        let large = try XCTUnwrap(ClaudeStepEstimate.range(lines: 900, samples: history))
        // 범위는 겹칠 수 있다(빗나간 비율을 모든 기록에서 재므로). 범위 전체가 뒤로 밀리면 된다.
        XCTAssertLessThan(small.lowerBound, large.lowerBound, "크기가 비슷한 리뷰끼리 견준다")
        XCTAssertLessThan(small.upperBound, large.upperBound)
    }

    func testDoesNotScaleLinearlyWithLines() throws {
        // 지난 리뷰가 전부 2분 안팎이면 10배 큰 PR 도 10배로 잡지 않는다(실측: 시간은 줄 수에 따라 늘다가 멈춘다).
        var pairs: [(lines: Int, seconds: Double)] = []
        for index in 0..<20 {
            let seconds: Double = 120 + Double(index % 4) * 5
            pairs.append((lines: 300 + index * 20, seconds: seconds))
        }
        let history = samples(pairs)
        let range = try XCTUnwrap(ClaudeStepEstimate.range(lines: 5_000, samples: history))
        XCTAssertLessThan(range.upperBound, 200)
    }

    func testIgnoresZeroDurations() {
        let broken = samples(Array(repeating: (100, 0), count: 20))
        XCTAssertNil(ClaudeStepEstimate.range(lines: 100, samples: broken), "시간을 못 잰 기록은 근거가 아니다")
    }

    func testRangeText() {
        XCTAssertEqual(ClaudeStepEstimate.text(13.6...83.2), "13초 ~ 1:24", "위 끝은 올린다")
        XCTAssertEqual(ClaudeStepEstimate.text(47.9...324.2), "47초 ~ 5:25")
        XCTAssertEqual(ClaudeStepEstimate.text(60...600), "1:00 ~ 10:00")
    }

    func testModelKey() {
        XCTAssertEqual(ClaudeStepEstimate.modelKey("claude-opus-5-5[1m]"), "claude-opus-5-5")
        XCTAssertEqual(ClaudeStepEstimate.modelKey("Claude-Sonnet-5"), "claude-sonnet-5")
    }

    func testRecordKeepsChangedLines() throws {
        var record = Fixtures.record(pr: Fixtures.pr(), output: Fixtures.output())
        record.changedLines = 512
        let data = try JSONEncoder().encode(record)
        XCTAssertEqual(try JSONDecoder().decode(ReviewRecord.self, from: data).changedLines, 512)
    }
}
