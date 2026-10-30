import XCTest
@testable import PRayerCore

/// "리뷰 대기" 탭에 무엇이 들어오는가.
///
/// 닫힘·머지 · 내가 이미 승인한 PR · 초안은 **끌 수 있는 필터가 아니라 이 탭의 정의**다.
/// 예전에는 토글이었는데, 끄면 리뷰 대기함이 할 일이 아닌 것으로 차고 켜 두면 아무 일도
/// 안 하는 선택지라(닫힘 쪽은 서버 쿼리의 `is:open` 이 이미 걸렀다) 탭 조건으로 옮겼다.
final class OpenScopeTests: XCTestCase {
    private let open = PRListScope.open
    private let all = PRListScope.recentAll(.day)
    private let approvals = PRListScope.myApprovals(.day)

    /// "현재 커밋을 승인함" 상태. Fixtures 는 리뷰 커밋을 받지 않으므로 여기서 맞춘다.
    private func approvedAtHead(reRequested: Bool = false) -> PullRequestInfo {
        var pr = Fixtures.pr(viewerHasReviewRequest: reRequested, viewerLatestReviewState: "APPROVED")
        pr.viewerLatestReviewCommit = pr.headRefOid
        return pr
    }

    private func included(_ pr: PullRequestInfo, _ scope: PRListScope, approved: Bool = true) -> Bool {
        PRVisibility.scopeIncludes(pr: pr, scope: scope, approvedInWindow: approved)
    }

    // MARK: 내가 승인한 것

    func testApprovedCurrentHeadIsNotInTheQueue() {
        let pr = approvedAtHead()
        XCTAssertTrue(pr.viewerApprovedCurrentHead)
        XCTAssertFalse(included(pr, open))
    }

    /// 리뷰 대기에서 빠지는 대신 '최근 승인' 과 '전체 PR' 에서는 그대로 보인다.
    /// 그래야 "숨겼다" 가 아니라 "옮겼다" 가 된다.
    func testApprovedIsStillVisibleInOtherTabs() {
        let pr = approvedAtHead()
        XCTAssertTrue(included(pr, approvals, approved: true))
        XCTAssertTrue(included(pr, all))
    }

    /// 승인한 뒤 새 커밋이 오면 그 커밋은 아직 안 본 것이라 다시 보여야 한다.
    func testNewCommitBringsItBack() {
        var pr = approvedAtHead()
        pr.headRefOid = "bbbbbbbbbbbb2222"   // 승인은 옛 커밋 기준으로 남는다
        XCTAssertFalse(pr.viewerApprovedCurrentHead)
        XCTAssertTrue(included(pr, open))
    }

    /// 다시 봐 달라는 요청(Re-request review)이 왔으면 남긴다.
    /// 승인은 그대로 남아 있지만 사람이 한 번 더 봐 달라고 한 것이다.
    func testReRequestedStaysInTheQueue() {
        let pr = approvedAtHead(reRequested: true)
        XCTAssertTrue(pr.viewerApprovedCurrentHead)
        XCTAssertTrue(included(pr, open))
    }

    /// 코멘트만 남긴 것은 승인이 아니다 — 아직 내 몫이다.
    func testCommentedStaysInTheQueue() {
        let pr = Fixtures.pr(viewerHasReviewRequest: false, viewerLatestReviewState: "COMMENTED")
        XCTAssertTrue(included(pr, open))
    }

    // MARK: 닫힘·머지

    func testClosedIsNotInTheQueue() {
        var pr = Fixtures.pr()
        pr.state = "MERGED"
        XCTAssertFalse(included(pr, open))
        // 전체 PR 탭은 닫힘·머지를 보러 오는 곳이다.
        XCTAssertTrue(included(pr, all))
    }

    /// 승인 탭은 "그 기간에 내가 승인했는가" 가 조건이다. 이건 그대로다.
    func testApprovalTabStillNeedsAnApprovalInWindow() {
        let pr = Fixtures.pr()
        XCTAssertTrue(included(pr, approvals, approved: true))
        XCTAssertFalse(included(pr, approvals, approved: false))
    }

    // MARK: 초안

    /// 초안은 아직 봐 달라는 게 아니다.
    func testDraftIsNotInTheQueue() {
        let pr = Fixtures.pr(isDraft: true)
        XCTAssertFalse(included(pr, open))
        // 전체 PR 탭에는 그대로 있다. 내가 올린 초안은 맨 위 "내가 올린 PR" 그룹이 맡는다.
        XCTAssertTrue(included(pr, all))
    }

    // MARK: 남아 있는 필터

    /// 끌 수 있는 필터만 목록에 남는다. 없앤 것들이 다시 기어들어오면 잡는다.
    func testOnlyTogglableFiltersRemain() {
        XCTAssertEqual(Set(PRFilterKind.allCases),
                       [.hideIgnoredAuthors, .hideLabels, .repos, .search])
    }

    func testApprovedPRIsNotCountedAsFilterHidden() {
        // 탭 조건으로 빠진 것은 "필터로 숨김" 이 아니다 — 끌 수 있는 것처럼 세면 거짓말이 된다.
        let reasons = PRVisibility.hidingFilters(pr: approvedAtHead(),
                                                 state: PRFilterState(),
                                                 scope: open,
                                                 hasHiddenLabel: false)
        XCTAssertTrue(reasons.isEmpty)
    }
}

/// 필터를 더하거나 뺄 때마다 사용자가 맞춰 둔 설정이 초기화되면 안 된다.
final class FilterMigrationTests: XCTestCase {
    /// 없앤 키(hideClosed·onlyMyReviewRequests·hideMyApproved·hideDrafts·hideApprovalReached)가
    /// 남아 있는 옛 저장값도 그대로 읽히고, 없는 항목만 기본값을 쓴다.
    /// 합성 디코더는 여기서 통째로 실패한다 — 그러면 사용자의 필터가 전부 초기화된다.
    func testOldStoredValueSurvivesRemovedKeys() throws {
        // 0.3.0 까지의 저장 형식. 라벨 필터는 `hideDoNotReview` 라는 이름이었다.
        let old = #"{"hideDoNotReview":false,"hideClosed":true,"hideApprovalReached":true,"onlyMyReviewRequests":false,"hideMyApproved":false,"hideDrafts":true}"#
        let filter = try JSONDecoder().decode(PRFilterProbe.self, from: Data(old.utf8))
        XCTAssertFalse(filter.hideLabels, "옛 이름으로 꺼 둔 값이 유지돼야 한다")
        XCTAssertTrue(filter.hideIgnoredAuthors, "없는 항목은 기본값(켬)")
    }

    func testNewNameWinsOverLegacyName() throws {
        let both = #"{"hideLabels":true,"hideDoNotReview":false}"#
        XCTAssertTrue(try JSONDecoder().decode(PRFilterProbe.self, from: Data(both.utf8)).hideLabels)
    }
}

/// `PRFilter` 는 앱 타깃에 있어 Core 테스트에서 직접 못 쓴다.
/// 마이그레이션 계약(없는 키는 기본값, 모르는 키는 무시, 옛 이름도 읽음)만 같은 모양으로 잠근다.
struct PRFilterProbe: Codable {
    var hideLabels = true
    var hideIgnoredAuthors = true

    enum CodingKeys: String, CodingKey {
        case hideLabels, hideIgnoredAuthors
    }

    private enum LegacyKeys: String, CodingKey {
        case hideDoNotReview
    }

    init() {}

    init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let fallback = PRFilterProbe()
        let legacy = try? decoder.container(keyedBy: LegacyKeys.self)
        hideLabels = try c.decodeIfPresent(Bool.self, forKey: .hideLabels)
            ?? (try? legacy?.decodeIfPresent(Bool.self, forKey: .hideDoNotReview)) ?? fallback.hideLabels
        hideIgnoredAuthors = try c.decodeIfPresent(Bool.self, forKey: .hideIgnoredAuthors) ?? fallback.hideIgnoredAuthors
    }
}
