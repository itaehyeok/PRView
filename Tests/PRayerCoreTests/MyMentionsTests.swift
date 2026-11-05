import XCTest
@testable import PRayerCore

/// 글에서 나를 @멘션한 자리(MyMentions)와 목록 활동 줄의 @me(PRActivityBuilder 의 `mentionEntryID`).
final class MyMentionsTests: XCTestCase {
    private let me = "sam-lee"
    private let other = "jamie-acme"
    private let base = Date(timeIntervalSince1970: 1_780_000_000)

    private func at(_ minute: Int) -> Date { base.addingTimeInterval(Double(minute) * 60) }

    private func threadComment(_ who: String, _ body: String, minute: Int) -> ReviewThreadComment {
        ReviewThreadComment(author: who, body: body, createdAt: at(minute).ISO8601Format())
    }

    // MARK: 가르기

    func testFindsMyLoginIgnoringCase() {
        XCTAssertTrue(MyMentions.mentions("@Sam-Lee 이것 좀 봐 주세요", viewer: me))
        XCTAssertTrue(MyMentions.mentions("확인 부탁드려요 @sam-lee.", viewer: me))
        XCTAssertTrue(MyMentions.mentions("(@sam-lee)", viewer: me))
    }

    /// 앞이 이어진 이름이거나 뒤가 더 이어지면 다른 사람이다.
    func testOtherLoginsAreNotMe() {
        XCTAssertFalse(MyMentions.mentions("@sam-lee2 님 확인 부탁드려요", viewer: me))
        XCTAssertFalse(MyMentions.mentions("@jamie-acme 님 확인 부탁드려요", viewer: me))
        XCTAssertFalse(MyMentions.mentions("@sam 님", viewer: me))
    }

    /// 메일 주소·팀 멘션은 사람을 부른 것이 아니다.
    func testMailAndTeamMentionsAreNotMe() {
        XCTAssertFalse(MyMentions.mentions("메일은 a@sam-lee 로", viewer: me))
        XCTAssertFalse(MyMentions.mentions("@sam-lee/ios 팀 확인", viewer: me))
    }

    /// 코드 안에 적힌 것은 부른 것이 아니다.
    func testMentionsInsideCodeAreIgnored() {
        XCTAssertFalse(MyMentions.mentions("`@sam-lee` 는 예시예요", viewer: me))
        XCTAssertFalse(MyMentions.mentions("```\nlet owner = \"@sam-lee\"\n```", viewer: me))
        XCTAssertTrue(MyMentions.mentions("`@sam-lee` 말고 진짜로 @sam-lee 님", viewer: me))
    }

    func testNoViewerFindsNothing() {
        XCTAssertFalse(MyMentions.mentions("@sam-lee", viewer: nil))
        XCTAssertFalse(MyMentions.mentions("@sam-lee", viewer: ""))
    }

    func testRangesCoverTheAtSign() {
        let text = "앞 @sam-lee 뒤 @SAM-LEE"
        let found = MyMentions.ranges(in: text, viewer: me).map { String(text[$0]) }
        XCTAssertEqual(found, ["@sam-lee", "@SAM-LEE"])
    }

    // MARK: 미리보기

    /// 멘션이 글 첫머리 가까이 있으면 처음부터 보인다.
    func testPreviewKeepsShortLead() {
        XCTAssertEqual(MyMentions.preview(of: "좋아요. @sam-lee 도 봐 주세요", viewer: me), "좋아요. @sam-lee 도 봐 주세요")
    }

    /// 멘션이 뒤에 있으면 그 앞 몇 글자부터 — 낱말 가운데서 자르지 않는다.
    func testPreviewStartsNearTheMention() throws {
        let body = "접근성 라벨은 좋아 보이고 커버 비율도 맞습니다. 미니 플레이어 쪽은 @sam-lee 님이 같이 봐 주실 수 있을까요?"
        let preview = try XCTUnwrap(MyMentions.preview(of: body, viewer: me))
        XCTAssertTrue(preview.hasPrefix("… "))
        XCTAssertTrue(preview.contains("@sam-lee 님이 같이 봐 주실 수 있을까요?"))
        XCTAssertFalse(preview.contains("접근성"))
        let afterEllipsis = preview.dropFirst(2)
        XCTAssertTrue(body.contains(" " + afterEllipsis), "낱말 첫머리에서 시작한다: \(preview)")
    }

    /// 미리보기 기본 길이(280자)를 넘은 뒤쪽 멘션도 잡는다.
    func testPreviewFindsLateMention() throws {
        let body = String(repeating: "긴 설명입니다. ", count: 60) + "@sam-lee 확인 부탁드려요"
        let preview = try XCTUnwrap(MyMentions.preview(of: body, viewer: me))
        XCTAssertTrue(preview.hasSuffix("@sam-lee 확인 부탁드려요"))
    }

    func testPreviewIsNilWithoutMention() {
        XCTAssertNil(MyMentions.preview(of: "`@sam-lee` 는 예시", viewer: me))
    }

    // MARK: 대화 줄

    /// 스레드는 답글이 불러도 그 스레드가 나를 부른 줄이다. 내가 쓴 글은 세지 않는다.
    func testThreadMentionCountsRepliesButNotMine() {
        let thread = PRReviewThread(id: "T1", path: "Sources/App/Feature.swift", line: 3, isResolved: false, isOutdated: false,
                                    comments: [threadComment(other, "여기 순서가 바뀌나요?", minute: 0),
                                               threadComment(me, "@sam-lee 메모: 나중에 보기", minute: 1),
                                               threadComment(other, "@sam-lee 의도하신 거 맞죠?", minute: 2)])
        let entry = PRTimelineEntry.thread(thread, at: at(0))
        XCTAssertEqual(MyMentions.firstMentioningBody(in: entry, viewer: me), "@sam-lee 의도하신 거 맞죠?")
    }

    func testMyOwnPostIsNotAMention() {
        let comment = PRIssueComment(author: me, body: "@sam-lee 할 일 메모", createdAt: at(0))
        XCTAssertNil(MyMentions.firstMentioningBody(in: .comment(comment), viewer: me))
    }

    func testBodyMentionSkipsMyOwnPR() {
        var pr = Fixtures.pr()
        pr.bodyText = "@sam-lee 님 리뷰 부탁드려요"
        XCTAssertTrue(MyMentions.bodyMentions(pr, viewer: me))
        pr.author = me
        XCTAssertFalse(MyMentions.bodyMentions(pr, viewer: me))
    }

    // MARK: 활동 줄

    /// 대화 코멘트·리뷰 본문이 부르면 그 활동이 그 대화 줄을 가리킨다 — 개요 탭에서 그 줄로 간다.
    func testActivitiesPointAtTheirTimelineEntry() throws {
        var pr = Fixtures.pr()
        let comment = PRIssueComment(author: other, body: "@sam-lee 스크린샷도 봐 주세요", createdAt: at(10))
        let review = PRReviewEvent(author: "alex-acme", state: "APPROVED", submittedAt: at(20), body: "좋아요 @sam-lee")
        pr.issueComments = [comment, PRIssueComment(author: other, body: "멘션 없음", createdAt: at(5))]
        pr.reviewEvents = [review]
        pr.threads = []
        pr.commits = []
        let activities = PRActivityBuilder.build(from: pr, limit: nil, viewer: me, now: at(60))
        let commented = try XCTUnwrap(activities.first { $0.at == at(10) })
        XCTAssertEqual(commented.mentionEntryID, PRTimelineEntry.comment(comment).id)
        let approved = try XCTUnwrap(activities.first { $0.kind == .approved })
        XCTAssertEqual(approved.mentionEntryID, PRTimelineEntry.review(review).id)
        XCTAssertEqual(activities.filter(\.mentionsViewer).count, 2)
    }

    /// 리뷰 한 번에 묶인 코드 코멘트가 불렀으면 그 리뷰 활동이 스레드 줄을 가리킨다(개요에는 빈 리뷰 줄이 없다).
    func testInlineCommentMentionPointsAtThread() throws {
        var pr = Fixtures.pr()
        let thread = PRReviewThread(id: "T9", path: "Sources/App/Feature.swift", line: 7, isResolved: false, isOutdated: false,
                                    comments: [threadComment(other, "@sam-lee 이 부분 의도하신 거죠?", minute: 30)])
        pr.threads = [thread]
        pr.reviewEvents = [PRReviewEvent(author: other, state: "COMMENTED", submittedAt: at(31), body: "")]
        pr.issueComments = []
        pr.commits = []
        let activities = PRActivityBuilder.build(from: pr, limit: nil, viewer: me, now: at(60))
        XCTAssertEqual(activities.count, 1)
        XCTAssertEqual(activities.first?.mentionEntryID, "thread:T9")
    }

    /// PR 본문이 부르면 올린 일이 "Opened" 한 줄로 서고 본문 카드를 가리킨다. 부르지 않았으면 그 줄은 없다 —
    /// 올린 일은 목록 행 머리의 "Created … ago" 가 이미 말한다.
    func testBodyMentionAddsOpenedActivity() throws {
        var pr = Fixtures.pr()
        pr.createdAt = at(0)
        pr.bodyText = "로그인 화면 정리입니다. @sam-lee 님 키보드 쪽 봐 주세요"
        pr.issueComments = [PRIssueComment(author: other, body: "멘션 없음", createdAt: at(10))]
        pr.reviewEvents = []
        pr.threads = []
        pr.commits = []
        let activities = PRActivityBuilder.build(from: pr, limit: nil, viewer: me, now: at(60))
        let opened = try XCTUnwrap(activities.first { $0.kind == .opened })
        XCTAssertEqual(opened.actor, pr.author)
        XCTAssertEqual(opened.at, at(0))
        XCTAssertEqual(opened.mentionEntryID, PRActivity.bodyEntryID)
        XCTAssertEqual(activities.last?.kind, .opened, "가장 오래된 일이라 맨 아래")

        pr.bodyText = "멘션 없는 본문"
        XCTAssertFalse(PRActivityBuilder.build(from: pr, limit: nil, viewer: me, now: at(60)).contains { $0.kind == .opened })
        pr.bodyText = "@sam-lee 메모"
        pr.author = me
        XCTAssertFalse(PRActivityBuilder.build(from: pr, limit: nil, viewer: me, now: at(60)).contains { $0.kind == .opened },
                       "내 PR 본문은 보지 않는다")
    }

    /// 내 로그인을 주지 않으면 아무 활동도 멘션으로 치지 않는다(예전 호출 그대로).
    func testNoViewerMeansNoMentions() {
        var pr = Fixtures.pr()
        pr.issueComments = [PRIssueComment(author: other, body: "@sam-lee 봐 주세요", createdAt: at(10))]
        XCTAssertTrue(PRActivityBuilder.build(from: pr, limit: nil, now: at(60)).allSatisfy { !$0.mentionsViewer })
    }
}
