import XCTest
@testable import PRayerCore

/// 한 탭에서 받은 PR 로 다른 탭의 지난 목록을 미리 고쳐 두기.
final class ListCacheSeedingTests: XCTestCase {
    private let now = Date(timeIntervalSince1970: 1_800_000_000)
    private let me = "you-acme"

    private func pr(_ number: Int, updatedHoursAgo: Double = 1, createdHoursAgo: Double = 30,
                    title: String = "제목") -> PullRequestInfo {
        var pr = Fixtures.pr(number: number)
        pr.title = title
        pr.updatedAt = now.addingTimeInterval(-updatedHoursAgo * 3600)
        pr.createdAt = now.addingTimeInterval(-createdHoursAgo * 3600)
        return pr
    }

    private func merge(_ fetched: [PullRequestInfo], into cached: [PullRequestInfo],
                       _ scope: PRListScope) -> [PullRequestInfo]? {
        ListCacheSeeding.merge(fetched, into: cached, scope: scope, viewerLogin: me, now: now)
    }

    // MARK: 갈아 끼우기

    /// 다른 탭에서 더 새로 받은 같은 PR 은 조용히 갈아 끼운다.
    func testNewerReplacesSamePR() {
        let old = pr(1, updatedHoursAgo: 5, title: "옛 제목")
        let fresh = pr(1, updatedHoursAgo: 1, title: "새 제목")
        XCTAssertEqual(merge([fresh], into: [old], .recentAll(.day))?.first?.title, "새 제목")
    }

    /// 받은 것이 지난 목록보다 오래됐으면(다른 탭이 더 늦게 받아 둔 것) 덮지 않는다.
    func testOlderDoesNotOverwrite() {
        let cached = pr(1, updatedHoursAgo: 1, title: "새 제목")
        let stale = pr(1, updatedHoursAgo: 5, title: "옛 제목")
        XCTAssertNil(merge([stale], into: [cached], .recentAll(.day)))
    }

    /// 바뀐 것이 없으면 nil — 지난 목록을 새로 쓰지 않는다.
    func testSameIsNoChange() {
        XCTAssertNil(merge([pr(1)], into: [pr(1)], .recentAll(.day)))
    }

    /// 리뷰 대기에는 다른 탭에서 본 열린 PR 을 더한다 — 기간이 없어 오래 활동 없던 것도. 닫힌 것은 더하지 않고,
    /// 이미 있던 것이 머지됐으면 갈아 끼운다(그러면 화면의 거르기가 뺀다).
    func testOpenScopeAddsOpenOnly() {
        XCTAssertEqual(merge([pr(2, updatedHoursAgo: 300)], into: [pr(1)], .open)?.map(\.number).sorted(), [1, 2])
        var closed = pr(3)
        closed.state = "CLOSED"
        XCTAssertNil(merge([closed], into: [pr(1)], .open))
        var merged = pr(1, updatedHoursAgo: 0.5)
        merged.state = "MERGED"
        XCTAssertEqual(merge([merged], into: [pr(1)], .open)?.first?.state, "MERGED")
    }

    /// All PRs 를 먼저 받으면 그 안의 열린 PR 은 리뷰 대기에, 내가 Approve 한 것은 Approved 에 먼저 들어간다.
    func testAllPRsFetchSeedsBothOtherTabs() {
        var approvedByMe = pr(1)
        approvedByMe.reviewEvents = [PRReviewEvent(author: me, state: "APPROVED", submittedAt: now.addingTimeInterval(-600), body: "")]
        let waiting = pr(2)
        var merged = pr(3)
        merged.state = "MERGED"
        let fetched = [approvedByMe, waiting, merged]
        XCTAssertEqual(merge(fetched, into: [], .open)?.map(\.number).sorted(), [1, 2])
        XCTAssertEqual(merge(fetched, into: [], .myApprovals(.day))?.map(\.number), [1])
    }

    // MARK: 더하기 — 그 탭의 검색 조건

    /// All PRs 는 그 기간에 활동이 있었던 PR 만 더한다(`updated:>=`).
    func testAllPRsAddsOnlyRecentActivity() {
        let added = merge([pr(1, updatedHoursAgo: 2), pr(2, updatedHoursAgo: 30)], into: [], .recentAll(.day))
        XCTAssertEqual(added?.map(\.number), [1])
        XCTAssertEqual(merge([pr(2, updatedHoursAgo: 30)], into: [], .recentAll(.week))?.map(\.number), [2])
    }

    /// Approved 는 내가 그 기간에 Approve 한 PR 만 — 남의 Approve 는 아니다.
    func testApprovedAddsOnlyMyRecentApproval() {
        var mine = pr(1)
        mine.reviewEvents = [PRReviewEvent(author: me, state: "APPROVED", submittedAt: now.addingTimeInterval(-3600), body: "")]
        var others = pr(2)
        others.reviewEvents = [PRReviewEvent(author: "alex-acme", state: "APPROVED", submittedAt: now, body: "")]
        var old = pr(3)
        old.reviewEvents = [PRReviewEvent(author: me, state: "APPROVED", submittedAt: now.addingTimeInterval(-30 * 3600), body: "")]
        XCTAssertEqual(merge([mine, others, old], into: [], .myApprovals(.day))?.map(\.number), [1])
    }

    /// 로그인을 모르면 내 Approve 인지 가를 수 없어 더하지 않는다.
    func testApprovedNeedsViewer() {
        var mine = pr(1)
        mine.reviewEvents = [PRReviewEvent(author: me, state: "APPROVED", submittedAt: now, body: "")]
        XCTAssertNil(ListCacheSeeding.merge([mine], into: [], scope: .myApprovals(.day), viewerLogin: nil, now: now))
    }

    /// 더해도 목록은 올린 시각순이다.
    func testKeepsCreatedOrder() {
        let merged = merge([pr(3, createdHoursAgo: 2)], into: [pr(1, createdHoursAgo: 1), pr(2, createdHoursAgo: 5)],
                           .recentAll(.day))
        XCTAssertEqual(merged?.map(\.number), [1, 3, 2])
    }

    // MARK: 리뷰 대기에서 빠진 PR

    /// 지난번 받은 뒤에 닫힌 것이니 그 시각이 기간 안이면 All PRs 에 든다. 며칠 묵은 목록에서 빠진 것은 들지 않는다.
    func testDepartedJoinsAllPRsOnlyIfRecentlySeen() {
        let gone = pr(1, updatedHoursAgo: 40)
        let recent = ListCacheSeeding.departed([gone], since: now.addingTimeInterval(-120))
        XCTAssertEqual(merge(recent, into: [], .recentAll(.day))?.map(\.number), [1])
        let stale = ListCacheSeeding.departed([gone], since: now.addingTimeInterval(-50 * 3600))
        XCTAssertNil(merge(stale, into: [], .recentAll(.day)))
    }

    // MARK: 방금 Approve 한 PR

    /// 이 앱에서 Approve 하면 GitHub 이 알려 주기 전에도 Approved·All PRs 탭에 들어갈 모습이 된다.
    func testApprovedCopyBelongsToApprovedAndAll() {
        let approved = ListCacheSeeding.approved(pr(1, updatedHoursAgo: 40), by: me, at: now)
        XCTAssertTrue(approved.viewerApprovedCurrentHead)
        XCTAssertFalse(approved.viewerHasReviewRequest)
        XCTAssertEqual(approved.viewerApprovedAt(login: me), now)
        XCTAssertEqual(merge([approved], into: [], .myApprovals(.day))?.map(\.number), [1])
        XCTAssertEqual(merge([approved], into: [], .recentAll(.day))?.map(\.number), [1])
    }

    /// 방금 Approve 한 모습은 그 전에 받은 옛 정보에 덮이지 않는다.
    func testApprovedCopyIsNotOverwrittenByStaleFetch() {
        let before = pr(1, updatedHoursAgo: 3)
        let approved = ListCacheSeeding.approved(before, by: me, at: now)
        XCTAssertNil(merge([before], into: [approved], .myApprovals(.day)))
    }

    // MARK: 기간 넓히기

    /// 같은 종류에서 기간을 늘릴 때만 넓힌 것이다. 줄이거나, 종류가 바뀌거나, 리뷰 대기가 끼면 아니다.
    func testWidensOnlyWhenSameKindLongerWindow() {
        XCTAssertTrue(PRListScope.recentAll(.week).widens(from: .recentAll(.day)))
        XCTAssertTrue(PRListScope.myApprovals(.week).widens(from: .myApprovals(.day)))
        XCTAssertFalse(PRListScope.recentAll(.day).widens(from: .recentAll(.week)))
        XCTAssertFalse(PRListScope.recentAll(.week).widens(from: .recentAll(.week)))
        XCTAssertFalse(PRListScope.recentAll(.week).widens(from: .myApprovals(.day)))
        XCTAssertFalse(PRListScope.recentAll(.week).widens(from: .open))
        XCTAssertFalse(PRListScope.open.widens(from: .recentAll(.day)))
    }

    /// 넓힌 탭을 처음 열면 보던 목록이 그대로 그 탭의 목록이 된다 — 비지 않는다.
    func testWidenedKeepsShownListWhenNoCache() {
        let shown = [pr(2, createdHoursAgo: 5), pr(1, createdHoursAgo: 30)]
        XCTAssertEqual(ListCacheSeeding.widened(shown, into: []).map(\.number), [2, 1])
    }

    /// 넓힌 탭의 지난 목록이 있으면 둘을 합쳐 올린 시각순으로 놓는다. 같은 PR 은 더 새로 받은 쪽이 남는다.
    func testWidenedMergesWithCachedAndKeepsNewer() {
        let cached = [pr(3, updatedHoursAgo: 100, createdHoursAgo: 120), pr(1, updatedHoursAgo: 20, title: "옛 제목")]
        let shown = [pr(1, updatedHoursAgo: 2, title: "새 제목"), pr(2, createdHoursAgo: 10)]
        let widened = ListCacheSeeding.widened(shown, into: cached)
        XCTAssertEqual(widened.map(\.number), [2, 1, 3])
        XCTAssertEqual(widened.first { $0.number == 1 }?.title, "새 제목")
        // 지난 목록 쪽이 더 새것이면 그대로 둔다.
        let older = [pr(3, updatedHoursAgo: 150, createdHoursAgo: 120, title: "더 옛 제목")]
        XCTAssertEqual(ListCacheSeeding.widened(older, into: cached).first { $0.number == 3 }?.title, "제목")
    }

    /// Approved 에서 오래전에 Approve 했어도 그 뒤에 일이 생겨 보이던 PR 은 넓혀도 빠지지 않는다 — Approve 한 시각으로
    /// 거르는 `merge` 와 다르다(거르면 받기 전까지 사라졌다 돌아온다).
    func testWidenedKeepsApprovedLongAgoWithNews() {
        var old = pr(1, updatedHoursAgo: 2)
        old.reviewEvents = [PRReviewEvent(author: me, state: "APPROVED", submittedAt: now.addingTimeInterval(-40 * 86_400), body: "")]
        XCTAssertNil(merge([old], into: [], .myApprovals(.week)))
        XCTAssertEqual(ListCacheSeeding.widened([old], into: []).map(\.number), [1])
    }
}
