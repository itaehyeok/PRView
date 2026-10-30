import XCTest
@testable import PRayerCore

/// 탭을 옮기면 목록이 달라지는데, 스냅샷을 그 목록으로 통째로 교체하면 "이미 본 PR" 기억을
/// 잃는다. 그러면 되돌아온 PR 이 전부 새 PR 알림으로 나간다(실측: 12건 탭 → 188건 탭에서 176건).
final class SnapshotMemoryTests: XCTestCase {
    private let repo = RepoID(owner: "acme", name: "sample-ios")
    private let now = Date(timeIntervalSince1970: 1_800_000_000)

    private func pr(_ number: Int, createdAt: Date? = nil, open: Bool = true,
                    author: String = "rio", mine: Bool = false) -> PullRequestInfo {
        PullRequestInfo(repo: repo, number: number, nodeID: "n\(number)", title: "제목", bodyText: "",
                        author: author, isDraft: false, state: open ? "OPEN" : "CLOSED",
                        createdAt: createdAt ?? now.addingTimeInterval(-86_400), updatedAt: now,
                        headRefOid: "sha\(number)", headRefName: "f", baseRefName: "develop",
                        additions: 1, deletions: 0, changedFiles: 1, mergeable: .mergeable,
                        mergeStateStatus: nil, reviewDecision: nil, approvals: [], labels: [],
                        viewerDidAuthor: mine, viewerHasReviewRequest: true,
                        viewerLatestReviewState: nil, viewerLatestReviewCommit: nil, checkState: nil,
                        threads: [], commits: [], reviewEvents: [], issueComments: [],
                        mergedAt: nil, mergedBy: nil, closedAt: nil)
    }

    private func changes(previous: [String: PRSnapshot], current: [PullRequestInfo],
                         lastSeenAt: Date? = nil) -> [PRChangeSet] {
        PRChangeDetector.changes(previous: previous, current: current,
                                 approvalThreshold: { _ in 3 }, lastSeenAt: lastSeenAt)
    }

    // MARK: - 누적

    func testMergedKeepsPRsThatLeftTheCurrentTab() {
        let wide = PRChangeDetector.merged(previous: [:], current: [pr(1), pr(2), pr(3)], now: now)
        XCTAssertEqual(wide.count, 3)
        // 좁은 탭으로 옮겨 1건만 보이더라도 나머지를 잊지 않는다.
        let narrow = PRChangeDetector.merged(previous: wide, current: [pr(1)], now: now)
        XCTAssertEqual(narrow.count, 3, "탭을 옮겨도 이미 본 PR 을 잊지 않는다")
    }

    func testReturningPRIsNotAnnouncedAsNew() {
        let wide = PRChangeDetector.merged(previous: [:], current: [pr(1), pr(2)], now: now)
        let narrow = PRChangeDetector.merged(previous: wide, current: [pr(1)], now: now)
        // 넓은 탭으로 되돌아왔을 때 #2 가 새 PR 로 잡히면 안 된다.
        let back = changes(previous: narrow, current: [pr(1), pr(2)],
                           lastSeenAt: PRChangeDetector.lastSeen(narrow))
        XCTAssertTrue(back.isEmpty, "돌아온 PR 은 새 PR 이 아니다")
    }

    func testOldEntriesAreForgotten() {
        let old = PRChangeDetector.merged(previous: [:], current: [pr(1)],
                                          now: now.addingTimeInterval(-PRChangeDetector.memory - 60))
        let fresh = PRChangeDetector.merged(previous: old, current: [pr(2)], now: now)
        XCTAssertEqual(Set(fresh.keys), [pr(2).id], "오래된 기억은 지운다")
    }

    /// seenAt 이 없는 옛 파일은 버리지 않는다 — 버리면 업데이트 직후 전부 새 PR 이 된다.
    func testLegacySnapshotsWithoutSeenAtSurvive() {
        let legacy = [pr(1).id: PRSnapshot(pr: pr(1))]
        XCTAssertNil(legacy[pr(1).id]?.seenAt)
        let merged = PRChangeDetector.merged(previous: legacy, current: [pr(2)], now: now)
        XCTAssertEqual(merged.count, 2)
    }

    // MARK: - "우리가 본 시각" 방어선

    /// 기억에 없어도, 우리가 마지막으로 본 시각보다 먼저 만들어진 PR 은 새 PR 이 아니다.
    func testPRCreatedBeforeLastSeenIsNotNew() {
        let seen = PRChangeDetector.merged(previous: [:], current: [pr(1)], now: now)
        let older = pr(99, createdAt: now.addingTimeInterval(-7 * 86_400))
        XCTAssertTrue(changes(previous: seen, current: [older],
                              lastSeenAt: PRChangeDetector.lastSeen(seen)).isEmpty)
    }

    func testGenuinelyNewPRStillNotifies() {
        let seen = PRChangeDetector.merged(previous: [:], current: [pr(1)], now: now)
        let brandNew = pr(100, createdAt: now.addingTimeInterval(60))
        let result = changes(previous: seen, current: [brandNew],
                            lastSeenAt: PRChangeDetector.lastSeen(seen))
        XCTAssertEqual(result.count, 1)
        XCTAssertEqual(result.first?.changes, [.appeared(reviewRequested: true)])
    }

    /// 기억이 아예 없으면(첫 실행) 이 판단을 하지 않는다 — 호출부가 기준선으로 걸러 낸다.
    func testNoMemoryMeansNoCutoff() {
        let result = changes(previous: [:], current: [pr(1)], lastSeenAt: nil)
        XCTAssertEqual(result.count, 1)
    }

    func testMyOwnPRAndClosedPRAreNeverAnnounced() {
        let lastSeen = now.addingTimeInterval(-2 * 86_400)
        let mine = pr(5, createdAt: now, mine: true)
        let closed = pr(6, createdAt: now, open: false)
        XCTAssertTrue(changes(previous: [:], current: [mine, closed], lastSeenAt: lastSeen).isEmpty)
    }
}

/// 처음 켠 사람이 보게 될 필터 기본값. 화면(설정 팝오버)과 어긋나면 안 된다.
/// PRFilter 는 앱 타깃에 있어 여기서 직접 못 보므로, Core 쪽 계약만 잠근다.
final class DefaultFilterStateTests: XCTestCase {
    /// 앱의 PRFilter 기본값과 같은 조합이 PRVisibility 에서 의도대로 동작하는지.
    func testFirstRunCombinationKeepsOnlyMyOpenWork() {
        let state = PRFilterState(hideIgnoredAuthors: true, hideLabels: true,
                                  hasIgnoredAuthors: true)
        XCTAssertEqual(Set(state.active(in: .open)), [.hideIgnoredAuthors, .hideLabels],
                       "처음 켜면 필터 2개가 걸려 있다")
        XCTAssertTrue(state.active(in: .recentAll(.day)).isEmpty,
                      "헤더 필터는 리뷰 대기 탭에서만 적용된다")
    }
}
