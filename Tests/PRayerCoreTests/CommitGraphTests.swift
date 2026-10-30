import XCTest
@testable import PRayerCore

/// 커밋 탭 위쪽 표 — 줄 세우기, 레인, PR 밖 부모(분기점·develop 머지), 리뷰한 지점, 고른 커밋의 diff 범위.
final class CommitGraphTests: XCTestCase {
    private func commit(_ oid: String, _ parents: [String]) -> BranchCommit {
        BranchCommit(oid: oid, abbreviatedOid: oid, headline: "msg \(oid)", authorName: "me",
                     date: Date(timeIntervalSince1970: 0), parents: parents)
    }

    private func ids(_ graph: CommitGraph) -> [String] { graph.rows.map(\.id) }

    // MARK: - 줄 세우기와 레인

    /// 곧은 브랜치 — 새 것이 위, 맨 아래는 갈라져 나온 base 커밋 한 줄.
    func testLinearBranchEndsWithForkPoint() {
        let graph = CommitGraph([commit("c1", ["dev0"]), commit("c2", ["c1"]), commit("c3", ["c2"])])
        XCTAssertEqual(ids(graph), ["c3", "c2", "c1", "base:dev0"])
        XCTAssertEqual(graph.rows.map(\.column), [0, 0, 0, 0])
        XCTAssertEqual(graph.columnCount, 1)
        XCTAssertEqual(graph.commits.map(\.oid), ["c3", "c2", "c1"])
    }

    /// develop 을 받아온 머지 — develop 커밋은 목록에 없어 레인을 열지 않고, 머지 행에 표시만 단다.
    /// 레인을 열면 끝나지 않는 선이 화면 아래로 이어진다.
    func testMergeFromBaseDoesNotOpenLane() {
        let graph = CommitGraph([commit("c1", ["dev0"]), commit("c2", ["c1"]),
                                 commit("m", ["c2", "dev9"]), commit("c3", ["m"])])
        XCTAssertEqual(ids(graph), ["c3", "m", "c2", "c1", "base:dev0"])
        XCTAssertEqual(graph.columnCount, 1)
        XCTAssertEqual(graph.rows.map(\.mergesFromBase), [false, true, false, false, false])
    }

    /// PR 안에서 갈라졌다 합친 가지 — 두 번째 레인이 생겼다가 공통 부모에서 합쳐진다.
    func testInternalBranchUsesSecondLaneAndJoins() {
        let graph = CommitGraph([commit("c1", ["dev0"]), commit("a", ["c1"]), commit("b", ["c1"]),
                                 commit("m", ["a", "b"])])
        XCTAssertEqual(ids(graph), ["m", "b", "a", "c1", "base:dev0"])
        XCTAssertEqual(graph.columnCount, 2)
        let b = graph.rows[1]
        XCTAssertEqual(b.column, 1)
        let c1 = graph.rows[3]
        XCTAssertEqual(c1.column, 0)
        // 두 번째 레인은 c1 점에서 끝난다(아래로 이어지지 않음).
        XCTAssertTrue(c1.lines.contains { $0.top == 1 && $0.bottom == nil })
        XCTAssertFalse(graph.rows[4].lines.contains { $0.top == 1 })
    }

    /// GitHub 순서는 날짜 순이라 리베이스 뒤에 부모가 자식보다 뒤에 올 수 있다. 자식이 늘 위에 온다.
    func testParentsAlwaysBelowChildrenEvenWhenDatesDisagree() {
        let graph = CommitGraph([commit("c2", ["c1"]), commit("c1", ["dev0"]), commit("c3", ["c2"])])
        XCTAssertEqual(ids(graph), ["c3", "c2", "c1", "base:dev0"])
    }

    /// 저장소 첫 커밋부터 들어 있는 PR — 갈라져 나온 곳이 없으니 분기점 줄도 없다.
    func testRootCommitHasNoForkPointRow() {
        let graph = CommitGraph([commit("c1", []), commit("c2", ["c1"])])
        XCTAssertEqual(ids(graph), ["c2", "c1"])
    }

    // MARK: - 리뷰한 지점

    func testCommitsAfterReviewAreTheRowsAboveIt() {
        let graph = CommitGraph([commit("c1", ["dev0"]), commit("c2", ["c1"]),
                                 commit("c3", ["c2"]), commit("c4", ["c3"])])
        XCTAssertEqual(graph.reviewedRowIndex(reviewedOid: "c2"), 2)
        XCTAssertEqual(graph.commitsAfterReview(reviewedOid: "c2").map(\.oid), ["c4", "c3"])
        // head 를 리뷰했으면 뒤에 올라온 것이 없다.
        XCTAssertEqual(graph.commitsAfterReview(reviewedOid: "c4").map(\.oid), [])
        // 강제 푸시로 사라진 커밋 — 자리를 지어내지 않는다.
        XCTAssertNil(graph.reviewedRowIndex(reviewedOid: "gone"))
        XCTAssertEqual(graph.commitsAfterReview(reviewedOid: "gone").map(\.oid), [])
    }

    // MARK: - 고른 커밋 → diff 범위

    func testDiffSpecForOneOrManyCommits() {
        let graph = CommitGraph([commit("c1", ["dev0"]), commit("c2", ["c1"]), commit("c3", ["c2"])])
        XCTAssertEqual(graph.diffSpec(for: ["c2"]), .commit("c2"))
        XCTAssertEqual(graph.diffSpec(for: ["c2", "c3"]), .range(base: "c1", head: "c3"))
        // 첫 커밋까지 고르면 base 는 갈라져 나온 develop 커밋.
        XCTAssertEqual(graph.diffSpec(for: ["c1", "c2", "c3"]), .range(base: "dev0", head: "c3"))
        XCTAssertNil(graph.diffSpec(for: []))
        XCTAssertNil(graph.diffSpec(for: ["base:dev0"]))
    }

    func testOidsBetweenIsInclusiveEitherDirection() {
        let graph = CommitGraph([commit("c1", ["dev0"]), commit("c2", ["c1"]),
                                 commit("c3", ["c2"]), commit("c4", ["c3"])])
        XCTAssertEqual(graph.oids(between: "c1", and: "c3"), ["c3", "c2", "c1"])
        XCTAssertEqual(graph.oids(between: "c4", and: "c3"), ["c4", "c3"])
        XCTAssertEqual(graph.oids(between: "c4", and: "nope"), [])
    }

    func testCacheKeyIsStableAndShort() {
        let a = String(repeating: "a", count: 40), b = String(repeating: "b", count: 40)
        XCTAssertEqual(CommitDiffSpec.commit(a).cacheKey, String(repeating: "a", count: 12))
        XCTAssertEqual(CommitDiffSpec.range(base: a, head: b).cacheKey,
                       String(repeating: "a", count: 12) + ".." + String(repeating: "b", count: 12))
    }
}
