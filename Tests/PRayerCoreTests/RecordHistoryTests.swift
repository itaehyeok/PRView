import XCTest
@testable import PRayerCore

final class RecordHistoryTests: XCTestCase {
    private let repo = RepoID(owner: "acme", name: "sample-ios")

    private func record(headSha: String, createdAt: Date, posted: Bool = false) -> ReviewRecord {
        var rec = ReviewRecord(repo: repo, number: 42, headSha: headSha, baseRefName: "main",
                               promptVersion: "v1", model: "opus", createdAt: createdAt,
                               trigger: .manual,
                               output: ReviewOutput(verdict: .comment, summaryKo: "요약", concerns: [],
                                                    strengths: [], draftComments: []),
                               comments: [], bodyDraft: "", usage: EngineUsage(), validationIssues: [])
        if posted {
            rec.posted = PostedInfo(reviewID: 1, htmlURL: "https://x", event: "APPROVE",
                                    postedAt: createdAt, commentCount: 0)
        }
        return rec
    }

    /// 같은 커밋을 여러 번 리뷰해도 파일이 서로 달라야 한다 — 예전에는 덮어써서 히스토리가 없었다.
    func testSameCommitReviewsGetDifferentFiles() {
        let first = AppPaths.draftFile(repo: repo, number: 42, headSha: "abcdef123456789",
                                       createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        let second = AppPaths.draftFile(repo: repo, number: 42, headSha: "abcdef123456789",
                                        createdAt: Date(timeIntervalSince1970: 1_800_000_060))
        XCTAssertNotEqual(first.lastPathComponent, second.lastPathComponent)
    }

    /// 같은 리뷰를 편집해 다시 저장할 때는 같은 파일이어야 한다(편집마다 파일이 늘면 안 된다).
    func testEditingTheSameReviewKeepsOneFile() {
        let at = Date(timeIntervalSince1970: 1_800_000_000)
        XCTAssertEqual(AppPaths.draftFile(repo: repo, number: 1, headSha: "sha", createdAt: at),
                       AppPaths.draftFile(repo: repo, number: 1, headSha: "sha", createdAt: at))
    }

    func testFileNameCarriesCommitAndStamp() {
        let url = AppPaths.draftFile(repo: repo, number: 42, headSha: "0123456789abcdef",
                                     createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        XCTAssertEqual(url.lastPathComponent, "42-0123456789ab-20270115T080000Z.json")
    }

    func testLegacyNameIsUnchangedSoOldFilesStillResolve() {
        XCTAssertEqual(AppPaths.legacyDraftFile(repo: repo, number: 42, headSha: "0123456789abcdef")
                        .lastPathComponent,
                       "42-0123456789ab.json")
    }

    /// 리뷰 1건을 가리키는 키는 커밋만으로는 부족하다.
    func testStorageKeyDistinguishesReviewsOnTheSameCommit() {
        let a = record(headSha: "sha", createdAt: Date(timeIntervalSince1970: 1_800_000_000))
        let b = record(headSha: "sha", createdAt: Date(timeIntervalSince1970: 1_800_000_060))
        XCTAssertNotEqual(a.storageKey, b.storageKey)
        XCTAssertEqual(a.storageKey, record(headSha: "sha", createdAt: a.createdAt).storageKey)
    }

    func testHistoryLimitIsTen() {
        XCTAssertEqual(Store.historyLimit, 10)
    }
}
