import XCTest
@testable import PRayerCore

/// 내 코멘트 답글 가르기. GitHub 이 "누구 글에 단 답인지" 를 주지 않아 글 모양과 순서로 가른다(MyCommentReplies 주석).
final class MyCommentRepliesTests: XCTestCase {
    private let me = "sam-lee"
    /// PR 작성자(Fixtures 기본값).
    private let author = "riley-park-acme"
    private let other = "jamie-acme"

    private func comment(_ who: String, _ body: String, minute: Int) -> ReviewThreadComment {
        ReviewThreadComment(author: who, body: body,
                            createdAt: Date(timeIntervalSince1970: 1_780_000_000 + Double(minute) * 60).ISO8601Format())
    }

    private func pr(_ threads: [[ReviewThreadComment]], viewerDidAuthor: Bool = false) -> PullRequestInfo {
        var pr = Fixtures.pr(viewerDidAuthor: viewerDidAuthor)
        pr.threads = threads.enumerated().map { index, comments in
            PRReviewThread(id: "T\(index)", path: "Sources/App/Feature.swift", line: 10 + index,
                           isResolved: false, isOutdated: false, comments: comments)
        }
        return pr
    }

    private func replies(_ threads: [[ReviewThreadComment]]) -> [MyCommentReply] {
        MyCommentReplies.replies(in: pr(threads), viewer: me)
    }

    // MARK: 규칙

    /// PRView 로 올린 코멘트는 저마다 새 스레드의 첫 글이다 — 그 스레드의 답글은 멘션이 없어도 나에게 온 것이다.
    func testReplyInMyThreadIsMine() {
        let found = replies([[comment(me, "구분선 색도 봐 주세요.", minute: 0),
                              comment(author, "맞췄습니다. 다시 봐 주세요.", minute: 5)]])
        XCTAssertEqual(found.map(\.comment.author), [author])
        XCTAssertEqual(found.first?.isGuess, false)
    }

    /// 내가 다시 답하면 그 앞 글은 처리한 것이다 — 내 마지막 글 뒤만 본다.
    func testOnlyAfterMyLastComment() {
        let found = replies([[comment(me, "질문", minute: 0),
                              comment(author, "답 1", minute: 1),
                              comment(me, "확인했어요", minute: 2),
                              comment(author, "답 2", minute: 3)]])
        XCTAssertEqual(found.map(\.comment.body), ["답 2"])
    }

    func testNothingWhenIHaveNotCommented() {
        XCTAssertTrue(replies([[comment(other, "질문", minute: 0), comment(author, "답", minute: 1)]]).isEmpty)
    }

    /// 남의 스레드에 끼어든 경우 내 글 바로 다음 글만 어림잡아 나에게 온 것으로 본다.
    func testNextCommentInOthersThreadIsAGuess() {
        let found = replies([[comment(other, "격리를 옮기는 게 좋겠어요.", minute: 0),
                              comment(me, "그러면 테스트도 바뀌어야 해요.", minute: 1),
                              comment(author, "테스트도 고쳤습니다.", minute: 2),
                              comment(other, "좋네요.", minute: 3)]])
        XCTAssertEqual(found.map(\.comment.body), ["테스트도 고쳤습니다."])
        XCTAssertEqual(found.first?.isGuess, true)
    }

    func testMentionMakesItMineAnywhere() {
        let found = replies([[comment(other, "질문", minute: 0),
                              comment(me, "저도 궁금해요", minute: 1),
                              comment(other, "@riley-park-acme 추가로 하나 더", minute: 2),
                              comment(author, "@Sam-Lee 이건 다음 PR 에서 할게요", minute: 3)]])
        XCTAssertEqual(found.map(\.comment.author), [author])
        XCTAssertEqual(found.first?.isGuess, false)
    }

    /// 다른 사람만 부른 글은 내 스레드라도 나에게 온 것이 아니다. 그 사람이 이 PR 어딘가에 나와야 사람으로 친다.
    func testMentionOfSomeoneElseIsNotMine() {
        XCTAssertTrue(replies([[comment(me, "질문", minute: 0),
                                comment(author, "@jamie-acme 이것 좀 봐 주세요", minute: 1)],
                               [comment(other, "다른 자리 얘기", minute: 2)]]).isEmpty)
    }

    /// PR 에 한 번도 안 나온 이름은 멘션으로 치지 않는다(`@MainActor` 와 못 가른다) — 내 스레드면 나에게 온 것으로 남는다.
    func testUnknownNameIsNotTreatedAsMention() {
        XCTAssertEqual(replies([[comment(me, "질문", minute: 0),
                                 comment(author, "@jamie-acme 이것 좀 봐 주세요", minute: 1)]]).count, 1)
    }

    /// Swift 코드 리뷰의 `@MainActor` 같은 말은 사람 이름이 아니다 — 멘션으로 보면 내 스레드 답글을 놓친다.
    func testSwiftAttributesAreNotMentions() {
        let found = replies([[comment(me, "격리가 필요해 보여요", minute: 0),
                              comment(author, "@MainActor 로 옮겼고 `@escaping` 도 뺐습니다", minute: 1)]])
        XCTAssertEqual(found.count, 1)
    }

    func testMentionInsideCodeIsIgnored() {
        let found = replies([[comment(me, "질문", minute: 0),
                              comment(author, "```\nlet x = \"@jamie-acme\"\n```\n고쳤어요", minute: 1)]])
        XCTAssertEqual(found.count, 1, "코드 안의 이름은 멘션이 아니다")
    }

    func testTeamMentionIsNotAPerson() {
        let found = replies([[comment(me, "질문", minute: 0), comment(author, "@acme/ios 팀 확인 부탁", minute: 1)]])
        XCTAssertEqual(found.count, 1)
    }

    func testQuoteOfMyTextMakesItMine() {
        let found = replies([[comment(other, "질문", minute: 0),
                              comment(me, "캐시 키에 사용자 id 가 빠져 있어요", minute: 1),
                              comment(other, "@riley-park-acme 저도 봤어요", minute: 2),
                              comment(author, "> 캐시 키에 사용자 id 가 빠져 있어요\n\n넣었습니다", minute: 3)]])
        XCTAssertEqual(found.map(\.comment.author), [author])
        XCTAssertEqual(found.first?.isGuess, false)
    }

    func testBotsAreSkipped() {
        XCTAssertTrue(replies([[comment(me, "질문", minute: 0), comment("ci-helper[bot]", "빌드 통과", minute: 1)]]).isEmpty)
    }

    /// 내 PR 에 달린 글은 "내 PR 새 코멘트" 가 맡는다.
    func testMyOwnPRIsNotCounted() {
        let mine = pr([[comment(me, "질문", minute: 0), comment(other, "답", minute: 1)]], viewerDidAuthor: true)
        XCTAssertTrue(MyCommentReplies.replies(in: mine, viewer: me).isEmpty)
    }

    // MARK: 알림

    func testNewReplyIsAChange() {
        let before = pr([[comment(me, "질문", minute: 0)]])
        let after = pr([[comment(me, "질문", minute: 0), comment(author, "답", minute: 5)]])
        let changes = PRChangeDetector.changes(previous: PRChangeDetector.snapshots([before], viewerLogin: me),
                                               current: [after], approvalThreshold: { _ in 2 }, viewerLogin: me)
        XCTAssertEqual(changes.first?.changes, [.repliesToMyComments(count: 1)])
    }

    /// 옛 기억(답글 칸이 없던 파일)은 기준선이 없다 — 지난 답글을 새 알림으로 내보내지 않는다.
    func testOldSnapshotWithoutRepliesIsABaseline() {
        let now = pr([[comment(me, "질문", minute: 0), comment(author, "답", minute: 5)]])
        let changes = PRChangeDetector.changes(previous: PRChangeDetector.snapshots([now]),
                                               current: [now], approvalThreshold: { _ in 2 }, viewerLogin: me)
        XCTAssertTrue(changes.isEmpty)
    }

    func testSameRepliesAreNotAnnouncedTwice() {
        let now = pr([[comment(me, "질문", minute: 0), comment(author, "답", minute: 5)]])
        let changes = PRChangeDetector.changes(previous: PRChangeDetector.snapshots([now], viewerLogin: me),
                                               current: [now], approvalThreshold: { _ in 2 }, viewerLogin: me)
        XCTAssertTrue(changes.isEmpty)
    }
}
