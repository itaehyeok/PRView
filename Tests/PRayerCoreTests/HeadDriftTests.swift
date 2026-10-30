import XCTest
@testable import PRayerCore

/// 게시하려는데 새 커밋이 올라와 있을 때 — 무엇을 보여 주고, 그대로 올리면 어느 커밋에 남는가.
final class HeadDriftTests: XCTestCase {
    private let reviewed = "a1b2c3d0000000000000000000000000000000aa"
    private let head = "e4f5a6b0000000000000000000000000000000bb"

    private func comparison(status: String = "ahead", messages: [String]) -> CommitComparison.Outcome {
        let entries = messages.enumerated().map { index, message in
            CommitComparison.Entry(oid: String(format: "%07x", index + 1) + String(repeating: "0", count: 33),
                                   message: message)
        }
        return .compared(CommitComparison(status: status, totalCommits: entries.count, commits: entries))
    }

    private func drift(_ messages: [String] = ["[APP-12] style(list): 임시 코멘트 정리",
                                               "[APP-12] docs(readme): 설치 안내 보완"]) -> HeadDrift {
        HeadDrift.make(base: reviewed, head: head, outcome: comparison(messages: messages))
    }

    // MARK: - compare 결과 해석

    func testAheadComparisonListsCommitsAfterReviewed() {
        let d = drift()
        XCTAssertFalse(d.baseRewritten)
        XCTAssertEqual(d.totalCount, 2)
        XCTAssertEqual(d.commits.map(\.headline), ["[APP-12] style(list): 임시 코멘트 정리",
                                                    "[APP-12] docs(readme): 설치 안내 보완"])
    }

    /// 커밋 본문까지 보이면 확인 창이 길어져 무엇이 올라왔는지 안 읽힌다. 첫 줄만 쓴다.
    func testHeadlineIsFirstLineOfMessage() {
        let d = drift(["fix(list): 빈 목록 처리\n\n본문 설명이 길게 이어진다."])
        XCTAssertEqual(d.commits.first?.headline, "fix(list): 빈 목록 처리")
    }

    /// diverged 의 commits 는 "갈라진 뒤 head 쪽" 이라 "리뷰 뒤에 올라온 것" 이 아니다.
    func testDivergedMeansRewrittenAndShowsNoCommits() {
        let d = HeadDrift.make(base: reviewed, head: head,
                               outcome: comparison(status: "diverged", messages: ["a", "b"]))
        XCTAssertTrue(d.baseRewritten)
        XCTAssertTrue(d.commits.isEmpty)
        XCTAssertNil(d.totalCount)
    }

    func testMissingBaseMeansRewritten() {
        XCTAssertTrue(HeadDrift.make(base: reviewed, head: head, outcome: .baseMissing).baseRewritten)
    }

    /// 비교를 못 했다고 강제 푸시로 단정하지 않는다 — 그러면 인라인 코멘트가 있는 게시를 이유 없이 막는다.
    func testFailedComparisonIsNotRewritten() {
        let d = HeadDrift.make(base: reviewed, head: head, outcome: .failed)
        XCTAssertFalse(d.baseRewritten)
        XCTAssertFalse(d.blocksPosting(inlineCount: 3))
    }

    func testMissingBaseDetectionFromGhOutput() {
        XCTAssertTrue(CommitComparison.isMissingBase("gh: Not Found (HTTP 404)"))
        XCTAssertTrue(CommitComparison.isMissingBase("No common ancestor between a and b."))
        XCTAssertFalse(CommitComparison.isMissingBase("error connecting to api.github.com"))
    }

    /// `compareCommits` 의 `--jq` 가 만드는 모양을 그대로 읽는다.
    func testDecodesJqProjection() throws {
        let json = #"{"status":"ahead","total":2,"commits":[{"oid":"aaa","message":"one"},{"oid":"bbb","message":"two\n\nbody"}]}"#
        let decoded = try JSONDecoder().decode(CommitComparison.self, from: Data(json.utf8))
        XCTAssertEqual(decoded.status, "ahead")
        XCTAssertEqual(decoded.totalCommits, 2)
        XCTAssertEqual(decoded.commits.map(\.headline), ["one", "two"])
    }

    // MARK: - 어느 커밋에 남기나

    /// 인라인이 없으면 지금 head 에 — 그래야 Approve 가 지금 커밋 기준으로 집계된다.
    func testWithoutInlinePostsOnAcceptedHead() {
        XCTAssertEqual(HeadDrift.postingCommit(reviewed: reviewed, acceptedHead: head, postsInlineComments: false), head)
    }

    /// 인라인 줄 번호는 리뷰한 커밋의 diff 기준이다. 새 head 에 붙이면 엉뚱한 줄에 달리거나 422 가 난다.
    func testWithInlineKeepsReviewedCommit() {
        XCTAssertEqual(HeadDrift.postingCommit(reviewed: reviewed, acceptedHead: head, postsInlineComments: true), reviewed)
    }

    func testWithoutAcceptanceKeepsReviewedCommit() {
        XCTAssertEqual(HeadDrift.postingCommit(reviewed: reviewed, acceptedHead: nil, postsInlineComments: false), reviewed)
    }

    func testRewrittenBlocksOnlyWhenInlineComments() {
        let d = HeadDrift.make(base: reviewed, head: head, outcome: .baseMissing)
        XCTAssertTrue(d.blocksPosting(inlineCount: 1))
        XCTAssertFalse(d.blocksPosting(inlineCount: 0))
    }

    func testPayloadUsesGivenCommit() {
        let record = Fixtures.record(pr: Fixtures.pr(), output: Fixtures.output())
        XCTAssertEqual(PostBuilder.payload(record: record, event: .approve, body: "").commit_id,
                       record.headSha)
        XCTAssertEqual(PostBuilder.payload(record: record, event: .approve, body: "",
                                           commitID: head).commit_id,
                       head)
    }

    // MARK: - 확인 창 문구

    func testReviewPromptForApproveWithoutInline() {
        let p = HeadDriftPrompt.make(drift: drift(),
                                     subject: .review(event: .approve, label: "코멘트+Approve 게시", inlineCount: 0))
        XCTAssertEqual(p.title, "리뷰한 뒤 새 커밋 2개가 올라왔습니다")
        XCTAssertEqual(p.subtitle, "리뷰한 커밋 a1b2c3d 이후에 올라왔고, 리뷰에는 들어가지 않았습니다.")
        XCTAssertEqual(p.note, "Approve 는 최신 커밋(e4f5a6b)에 남습니다.")
        XCTAssertEqual(p.confirmLabel, "그대로 코멘트+Approve 게시")
        XCTAssertFalse(p.isDestructive)
        XCTAssertNil(p.emptyListText)
    }

    func testReviewPromptForApproveWithInlineNamesReviewedCommit() {
        let p = HeadDriftPrompt.make(drift: drift(),
                                     subject: .review(event: .approve, label: "코멘트+Approve 게시", inlineCount: 3))
        XCTAssertTrue(p.note.hasPrefix("인라인 코멘트 3건과 Approve 는 리뷰한 커밋(a1b2c3d) 기준으로 남습니다."))
        XCTAssertTrue(p.note.contains("Outdated"))
    }

    func testCommentOnlyAndRequestChangesNotes() {
        let comment = HeadDriftPrompt.make(drift: drift(),
                                           subject: .review(event: .comment, label: "코멘트만 게시", inlineCount: 2))
        XCTAssertTrue(comment.note.hasPrefix("인라인 코멘트 2건은 리뷰한 커밋(a1b2c3d) 줄에 달립니다."))
        XCTAssertEqual(comment.confirmLabel, "그대로 코멘트만 게시")

        let changes = HeadDriftPrompt.make(drift: drift(),
                                           subject: .review(event: .requestChanges, label: "변경 요청 게시", inlineCount: 0))
        XCTAssertEqual(changes.note, "변경 요청은 최신 커밋(e4f5a6b)에 남고, 머지를 막습니다.")
        XCTAssertTrue(changes.isDestructive)
    }

    /// AI 리뷰 없이 Approve 할 때는 "리뷰한" 이 거짓말이다. 화면에 보이던 커밋을 기준으로 말한다.
    func testPlainApprovePrompt() {
        let p = HeadDriftPrompt.make(drift: drift(), subject: .plainApprove)
        XCTAssertEqual(p.title, "보고 있던 커밋 이후 새 커밋 2개가 올라왔습니다")
        XCTAssertEqual(p.subtitle, "화면에 보이던 커밋 a1b2c3d 이후에 올라왔습니다.")
        XCTAssertEqual(p.confirmLabel, "그대로 Approve")
    }

    /// 브랜치의 커밋은 대개 같은 이슈 키를 달고 있다. 줄마다 같은 글자가 먼저 읽히지 않게 뗀다.
    func testSharedTagIsStripped() {
        let p = HeadDriftPrompt.make(drift: drift(), subject: .plainApprove)
        XCTAssertEqual(p.commits.map(\.headline), ["style(list): 임시 코멘트 정리", "docs(readme): 설치 안내 보완"])
    }

    func testDifferentTagsAreKept() {
        let lines = ["[APP-12] a", "[APP-13] b"]
        XCTAssertEqual(HeadDriftPrompt.strippingSharedTag(lines), lines)
        XCTAssertEqual(HeadDriftPrompt.strippingSharedTag(["[APP-12] a", "b"]), ["[APP-12] a", "b"])
        // 태그만 있는 제목은 비우지 않는다.
        XCTAssertEqual(HeadDriftPrompt.strippingSharedTag(["[APP-12]"]), ["[APP-12]"])
    }

    /// 창이 길어지면 무엇이 올라왔는지 오히려 안 읽힌다. 최근 5개만 보이고 나머지는 수로 말한다.
    func testLongListShowsLatestFiveAndCountsTheRest() {
        let d = drift((1...8).map { "commit \($0)" })
        let p = HeadDriftPrompt.make(drift: d, subject: .plainApprove)
        XCTAssertEqual(p.commits.map(\.headline), ["commit 4", "commit 5", "commit 6", "commit 7", "commit 8"])
        XCTAssertEqual(p.hiddenCount, 3)
        XCTAssertEqual(p.title, "보고 있던 커밋 이후 새 커밋 8개가 올라왔습니다")
    }

    /// 목록이 잘려 와도(compare 는 100개씩) 수는 전체로 말한다.
    func testHiddenCountUsesTotalNotReceivedList() {
        let entries = (1...3).map { CommitComparison.Entry(oid: "o\($0)", message: "m\($0)") }
        let d = HeadDrift.make(base: reviewed, head: head,
                               outcome: .compared(CommitComparison(status: "ahead", totalCommits: 140, commits: entries)))
        let p = HeadDriftPrompt.make(drift: d, subject: .plainApprove)
        XCTAssertEqual(p.hiddenCount, 137)
        XCTAssertEqual(p.title, "보고 있던 커밋 이후 새 커밋 140개가 올라왔습니다")
    }

    /// 개수를 모르면 "새 커밋 개가" 같은 빈 자리를 만들지 않는다.
    func testUnknownListStillReadsNaturally() {
        let d = HeadDrift.make(base: reviewed, head: head, outcome: .failed)
        let p = HeadDriftPrompt.make(drift: d, subject: .review(event: .approve, label: "Approve 만 게시", inlineCount: 0))
        XCTAssertEqual(p.title, "리뷰한 뒤 새 커밋이 올라왔습니다")
        XCTAssertEqual(p.emptyListText, "새 커밋 목록을 받지 못했습니다. 지금 커밋은 e4f5a6b 입니다.")
        XCTAssertEqual(p.hiddenCount, 0)
    }

    func testRewrittenPromptExplainsForcePush() {
        let d = HeadDrift.make(base: reviewed, head: head, outcome: .baseMissing)
        let p = HeadDriftPrompt.make(drift: d, subject: .review(event: .approve, label: "Approve 만 게시", inlineCount: 0))
        XCTAssertEqual(p.title, "리뷰한 뒤 PR 커밋이 바뀌었습니다")
        XCTAssertEqual(p.subtitle, "리뷰한 커밋(a1b2c3d)이 강제 푸시로 PR 에서 빠졌습니다.")
        XCTAssertNotNil(p.emptyListText)
    }
}
