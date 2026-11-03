import XCTest
@testable import PRayerCore

/// 가볍게 훑고 바뀐 PR 만 자세히 받는 규칙.
///
/// 배경: 목록 쿼리는 요청한 칸 수로 값을 매겨 100건에 40점이 든다(실측). 2분마다 두 탭을 다 받으면 시간당 한도의 36%
/// 를 썼다. 훑기는 100건에도 1점이라, 훑은 뒤 바뀐 것만 자세히 받는다. 놓치는 것이 없어야 한다.
final class PRFetchPlanTests: XCTestCase {
    private let updated = Date(timeIntervalSince1970: 1_790_000_000)

    private func known(_ number: Int = 42) -> PullRequestInfo {
        var pr = Fixtures.pr(number: number)
        pr.updatedAt = updated
        pr.checkState = "SUCCESS"
        return pr
    }

    private func probe(of pr: PullRequestInfo) -> PRProbe {
        PRProbe(key: pr.id, nodeID: "PR_\(pr.number)", updatedAt: pr.updatedAt, headRefOid: pr.headRefOid,
                state: pr.state, isDraft: pr.isDraft, mergeable: pr.mergeable, checkState: pr.checkState)
    }

    func testUnchangedNeedsNothing() {
        let pr = known()
        XCTAssertFalse(probe(of: pr).needsDetail(known: pr))
    }

    func testNeverSeenNeedsDetail() {
        XCTAssertTrue(probe(of: known()).needsDetail(known: nil))
    }

    /// 리뷰·코멘트·답글·커밋은 updatedAt 을 바꾼다(실측).
    func testActivityNeedsDetail() {
        let pr = known()
        var p = probe(of: pr)
        p.updatedAt = updated.addingTimeInterval(30)
        XCTAssertTrue(p.needsDetail(known: pr))
    }

    /// CI 결과와 머지 가능 여부는 updatedAt 을 바꾸지 않는다(실측) — 그 값을 직접 견준다.
    func testCheckAndMergeableChangesNeedDetailWithoutUpdatedAt() {
        let pr = known()
        var ci = probe(of: pr)
        ci.checkState = "FAILURE"
        XCTAssertTrue(ci.needsDetail(known: pr))
        var mergeable = probe(of: pr)
        mergeable.mergeable = .conflicting
        XCTAssertTrue(mergeable.needsDetail(known: pr))
    }

    func testHeadStateAndDraftChangesNeedDetail() {
        let pr = known()
        var head = probe(of: pr)
        head.headRefOid = "bbbbbbbbbbbb2222"
        XCTAssertTrue(head.needsDetail(known: pr))
        var merged = probe(of: pr)
        merged.state = "MERGED"
        XCTAssertTrue(merged.needsDetail(known: pr))
        var draft = probe(of: pr)
        draft.isDraft = true
        XCTAssertTrue(draft.needsDetail(known: pr))
    }

    func testNodesToFetchKeepsOrderAndOnlyChanged() {
        let a = known(1), b = known(2), c = known(3)
        var changed = probe(of: b)
        changed.updatedAt = updated.addingTimeInterval(60)
        let probes = [probe(of: a), changed, probe(of: c), probe(of: known(4))]
        let knownMap = [a.id: a, b.id: b, c.id: c]
        XCTAssertEqual(PRFetchPlan.nodesToFetch(probes, known: knownMap, fullSync: false), ["PR_2", "PR_4"])
        // 전부 받을 때는 바뀌지 않은 것도 받는다 — 훑기로 못 가르는 변화를 바로잡는 자리다.
        XCTAssertEqual(PRFetchPlan.nodesToFetch(probes, known: knownMap, fullSync: true), ["PR_1", "PR_2", "PR_3", "PR_4"])
    }

    /// 훑은 목록에 없는 PR(머지·기간 밖)은 받아 둔 것이 있어도 늘어놓지 않는다. 아직 못 받은 것도 뺀다.
    func testAssembleFollowsProbes() {
        let a = known(1), b = known(2)
        let probes = [probe(of: b), probe(of: known(3))]
        XCTAssertEqual(PRFetchPlan.assemble(probes, known: [a.id: a, b.id: b]).map(\.number), [2])
    }

    func testFullSyncInterval() {
        let now = Date()
        XCTAssertTrue(PRFetchPlan.needsFullSync(lastFullSync: nil, now: now))
        XCTAssertFalse(PRFetchPlan.needsFullSync(lastFullSync: now.addingTimeInterval(-60), now: now))
        XCTAssertTrue(PRFetchPlan.needsFullSync(lastFullSync: now.addingTimeInterval(-PRFetchPlan.fullSyncInterval), now: now))
    }

    /// 훑기 응답의 키는 `PullRequestInfo.id` 와 같아야 받아 둔 것과 맞춰진다.
    func testProbeDecodesSameKeyAsInfo() throws {
        let json = """
        {"id": "PR_kw1", "number": 128, "updatedAt": "2026-10-14T08:00:00Z", "headRefOid": "abc123",
         "state": "OPEN", "isDraft": false, "mergeable": "MERGEABLE",
         "repository": {"name": "sample-ios", "owner": {"login": "acme"}},
         "commits": {"nodes": [{"commit": {"statusCheckRollup": {"state": "PENDING"}}}]}}
        """
        let probe = try XCTUnwrap(JSONDecoder().decode(PRProbeData.Node.self, from: Data(json.utf8)).toProbe())
        XCTAssertEqual(probe.key, "acme/sample-ios#128")
        XCTAssertEqual(probe.nodeID, "PR_kw1")
        XCTAssertEqual(probe.checkState, "PENDING")
        XCTAssertEqual(probe.mergeable, .mergeable)
    }
}
