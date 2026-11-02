import XCTest
@testable import PRayerCore

/// 내 코멘트 답글을 어디까지 봤나(MyReplyReadState) — 목록 칩·개요 탭 "새 답글" 이 본다.
final class MyReplyReadStateTests: XCTestCase {
    private let me = "sam-lee"
    /// PR 작성자(Fixtures 기본값).
    private let author = "riley-park-acme"

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

    func testUnreadUntilMarkedRead() {
        let reply = pr([[comment(me, "질문", minute: 0), comment(author, "답", minute: 5)]])
        var state = MyReplyReadState(since: .distantPast)
        XCTAssertEqual(state.unread(in: reply, viewer: me).count, 1)
        XCTAssertTrue(state.markRead(reply, viewer: me))
        XCTAssertTrue(state.unread(in: reply, viewer: me).isEmpty)
        XCTAssertFalse(state.markRead(reply, viewer: me), "바뀐 것이 없으면 저장하지 않는다")

        var later = reply
        later.threads[0].comments.append(comment(author, "하나 더", minute: 9))
        XCTAssertEqual(state.unread(in: later, viewer: me).map(\.comment.body), ["하나 더"])
    }

    /// 기능을 처음 켠 시각 전의 답글은 본 것으로 친다 — 업데이트하자마자 칩이 쏟아지면 안 된다.
    func testRepliesBeforeFirstLaunchAreRead() {
        let reply = pr([[comment(me, "질문", minute: 0), comment(author, "답", minute: 5)]])
        let state = MyReplyReadState(since: Date(timeIntervalSince1970: 1_780_000_000 + 600))
        XCTAssertTrue(state.unread(in: reply, viewer: me).isEmpty)
    }

    func testPruneDropsOldThreadsAndMovesSince() {
        let now = Date(timeIntervalSince1970: 1_790_000_000)
        var state = MyReplyReadState(since: .distantPast,
                                     seenUpTo: ["old": now.addingTimeInterval(-MyReplyReadState.memory - 60),
                                                "new": now.addingTimeInterval(-60)])
        XCTAssertTrue(state.prune(now: now))
        XCTAssertEqual(Set(state.seenUpTo.keys), ["new"])
        XCTAssertEqual(state.since, now.addingTimeInterval(-MyReplyReadState.memory))
    }
}
