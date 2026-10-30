import XCTest
@testable import PRayerCore

final class PostActionTests: XCTestCase {
    private func context(hasBody: Bool = true,
                         inline: Int = 2,
                         blocker: Bool = false,
                         verdict: Verdict = .comment,
                         author: Bool = false,
                         approvedHead: Bool = false,
                         approvedOlder: Bool = false) -> PostActionContext {
        PostActionContext(hasBody: hasBody, inlineCount: inline, hasBlocker: blocker,
                          verdict: verdict, viewerDidAuthor: author,
                          alreadyApprovedThisHead: approvedHead, approvedOlderCommit: approvedOlder)
    }

    // MARK: - 기본값

    func testApproveIsTheDefault() {
        XCTAssertEqual(PostActionPlan.recommended(for: context()), .commentAndApprove)
    }

    /// 내가 올린 PR 은 GitHub 이 승인을 422 로 거부한다. 기본값이 그리로 가면 안 된다.
    func testOwnPRFallsBackToComment() {
        XCTAssertEqual(PostActionPlan.recommended(for: context(author: true)), .commentOnly)
    }

    /// 같은 커밋을 두 번 승인하면 목록에 같은 줄이 두 번 뜬다(실측).
    func testAlreadyApprovedFallsBackToComment() {
        XCTAssertEqual(PostActionPlan.recommended(for: context(approvedHead: true)), .commentOnly)
    }

    /// blocker 를 두고 "승인" 을 기본값으로 내밀지 않는다.
    func testBlockerDoesNotDefaultToApprove() {
        XCTAssertEqual(PostActionPlan.recommended(for: context(blocker: true)), .commentOnly)
    }

    func testNothingToSendDefaultsToApproveOnly() {
        XCTAssertEqual(PostActionPlan.recommended(for: context(hasBody: false, inline: 0)), .approveOnly)
    }

    // MARK: - 목록

    func testRequestChangesIsHiddenUntilNeeded() {
        XCTAssertFalse(PostActionPlan.menu(for: context()).contains(.requestChanges))
        XCTAssertTrue(PostActionPlan.menu(for: context(blocker: true)).contains(.requestChanges))
        XCTAssertTrue(PostActionPlan.menu(for: context(verdict: .requestChanges)).contains(.requestChanges))
    }

    func testMenuAlwaysOffersTheThreeEverydayActions() {
        let menu = PostActionPlan.menu(for: context())
        XCTAssertEqual(menu.prefix(3).map(\.self), [.commentAndApprove, .commentOnly, .approveOnly])
    }

    // MARK: - 잠금 사유

    func testApproveActionsAreBlockedOnOwnPR() {
        let c = context(author: true)
        XCTAssertNotNil(PostActionPlan.disabledReason(.commentAndApprove, in: c))
        XCTAssertNotNil(PostActionPlan.disabledReason(.approveOnly, in: c))
        XCTAssertNil(PostActionPlan.disabledReason(.commentOnly, in: c), "코멘트는 자기 PR 에도 남길 수 있다")
    }

    /// 막는 이슈가 있으면 메뉴에 변경 요청이 나타나는데, 내 PR 에 내가 변경 요청을 달 수는 없다(GitHub 422).
    /// 메뉴에서 빼지 않고 Approve 처럼 꺼 둔다 — 기본값으로도 골라지지 않는다.
    func testRequestChangesIsBlockedOnOwnPR() {
        let c = context(blocker: true, author: true)
        XCTAssertTrue(PostActionPlan.menu(for: c).contains(.requestChanges))
        XCTAssertNotNil(PostActionPlan.disabledReason(.requestChanges, in: c))
        XCTAssertEqual(PostActionPlan.current(saved: PostAction.requestChanges.rawValue, in: c), .commentOnly)
        XCTAssertNil(PostActionPlan.disabledReason(.requestChanges, in: context(blocker: true)), "남의 PR 은 그대로")
    }

    func testApproveActionsAreBlockedWhenAlreadyApproved() {
        let c = context(approvedHead: true)
        XCTAssertNotNil(PostActionPlan.disabledReason(.approveOnly, in: c))
        XCTAssertNil(PostActionPlan.disabledReason(.commentOnly, in: c))
    }

    /// 승인 이후 새 커밋이 올라왔으면 다시 승인하는 것이 의미가 있다.
    func testReapprovingANewCommitIsAllowed() {
        let c = context(approvedHead: false, approvedOlder: true)
        XCTAssertNil(PostActionPlan.disabledReason(.commentAndApprove, in: c))
        XCTAssertTrue(PostActionPlan.summary(.commentAndApprove, in: c).contains("다시 Approve"))
    }

    /// 빈 COMMENT 리뷰는 GitHub 이 거부한다.
    func testContentActionsAreBlockedWhenThereIsNothingToSend() {
        let c = context(hasBody: false, inline: 0)
        XCTAssertNotNil(PostActionPlan.disabledReason(.commentOnly, in: c))
        XCTAssertNotNil(PostActionPlan.disabledReason(.commentAndApprove, in: c))
        XCTAssertNil(PostActionPlan.disabledReason(.approveOnly, in: c), "승인만은 보낼 내용이 없어도 된다")
    }

    // MARK: - 무엇이 나가는지

    /// 본문 체크를 다 끄고 "코멘트+승인" 을 눌렀을 때 본문이 빠진 걸 몰라서는 안 된다.
    func testSummarySaysWhenTheBodyIsMissing() {
        let text = PostActionPlan.summary(.commentAndApprove, in: context(hasBody: false, inline: 3))
        XCTAssertTrue(text.contains("본문 없음"))
        XCTAssertTrue(text.contains("인라인 3건"))
        XCTAssertTrue(text.contains("Approve 1표"))
    }

    func testApproveOnlySaysNothingElseGoesOut() {
        let text = PostActionPlan.summary(.approveOnly, in: context())
        XCTAssertTrue(text.contains("본문·인라인 없음"))
        XCTAssertTrue(text.contains("Approve 1표"))
    }

    func testCommentOnlySaysItDoesNotCount() {
        XCTAssertTrue(PostActionPlan.summary(.commentOnly, in: context()).contains("Approve 수 영향 없음"))
    }

    // MARK: - 이벤트 매핑

    func testEventMapping() {
        XCTAssertEqual(PostAction.commentOnly.event, .comment)
        XCTAssertEqual(PostAction.commentAndApprove.event, .approve)
        XCTAssertEqual(PostAction.approveOnly.event, .approve)
        XCTAssertEqual(PostAction.requestChanges.event, .requestChanges)
        XCTAssertFalse(PostAction.approveOnly.includesContent)
        XCTAssertTrue(PostAction.commentAndApprove.includesContent)
    }
}

/// 내가 올린 PR — GitHub 이 자기 PR 승인을 거부한다. 앱이 먼저 막아야
/// "눌렀는데 실패" 대신 "왜 못 누르는지" 를 볼 수 있다.
final class OwnPRApprovalTests: XCTestCase {
    func testApproveIsNeverOfferedOnMyOwnPR() {
        let events = PostBuilder.availableEvents(viewerDidAuthor: true)
        XCTAssertFalse(events.contains(.approve))
        XCTAssertFalse(events.contains(.requestChanges), "변경 요청도 GitHub 이 거부한다")
        XCTAssertTrue(events.contains(.comment), "코멘트는 내 PR 에도 남길 수 있다")
    }

    func testApproveIsOfferedOnSomeoneElsesPR() {
        XCTAssertTrue(PostBuilder.availableEvents(viewerDidAuthor: false).contains(.approve))
    }

    /// 이미 이 커밋을 승인했으면 또 승인할 이유가 없다(표가 늘지 않는다).
    func testApproveIsNotOfferedTwiceForTheSameCommit() {
        XCTAssertFalse(PostBuilder.availableEvents(viewerDidAuthor: false, alreadyApprovedHead: true)
            .contains(.approve))
    }
}
