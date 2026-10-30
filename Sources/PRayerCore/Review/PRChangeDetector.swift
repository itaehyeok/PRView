import Foundation

/// 폴링 사이에 PR 이 어떻게 변했는지 비교하기 위한 최소 상태.
public struct PRSnapshot: Codable, Sendable, Equatable {
    public var headSha: String
    public var state: String
    public var approvals: Int
    public var mergeable: MergeableState
    public var checkState: String?
    public var viewerHasReviewRequest: Bool
    public var viewerHasSubmittedReview: Bool
    public var threadCount: Int
    /// 이 PR 을 마지막으로 본 시각. 옛 파일에는 없으므로 optional 이다.
    public var seenAt: Date?

    public init(pr: PullRequestInfo, seenAt: Date? = nil) {
        self.seenAt = seenAt
        headSha = pr.headRefOid
        state = pr.state
        approvals = pr.approvalCount
        mergeable = pr.mergeable
        checkState = pr.checkState
        viewerHasReviewRequest = pr.viewerHasReviewRequest
        viewerHasSubmittedReview = pr.viewerHasSubmittedReview
        threadCount = pr.threads.count
    }
}

public enum PRChange: Sendable, Equatable, Hashable {
    /// 목록에 새로 나타난 PR.
    case appeared(reviewRequested: Bool)
    /// 기존 PR 인데 나에게 리뷰 요청이 새로 왔다.
    case reviewRequested
    /// 내가 리뷰를 냈던 PR 에 다시 리뷰 요청이 왔다.
    case reReviewRequested
    /// 내가 만든 PR 에 리뷰 코멘트가 늘었다.
    case commentsOnMyPR(added: Int)
    /// 내가 만든 PR 이 승인 임계값을 채웠다.
    case approvalsReached(count: Int)
    /// 내가 만든 PR 의 CI 가 실패로 바뀌었다.
    case checksFailed
    /// 내가 만든 PR 에 충돌이 생겼다.
    case conflictAppeared
    /// 내가 리뷰한 PR 에 새 커밋이 올라왔다(초안이 오래됨).
    case newCommitsOnReviewed
    /// 내가 만든 PR 이 머지됐다.
    case merged

    public var title: String {
        switch self {
        case .appeared(let requested): return requested ? "새 리뷰 요청" : "새 PR"
        case .reviewRequested: return "리뷰 요청 도착"
        case .reReviewRequested: return "재리뷰 요청"
        case .commentsOnMyPR: return "내 PR 에 리뷰 코멘트"
        case .approvalsReached: return "내 PR Approve 완료"
        case .checksFailed: return "내 PR CI 실패"
        case .conflictAppeared: return "내 PR 충돌 발생"
        case .newCommitsOnReviewed: return "리뷰한 PR 에 새 커밋"
        case .merged: return "내 PR 머지됨"
        }
    }

    public var detail: String {
        switch self {
        case .appeared(let requested): return requested ? "나에게 리뷰가 요청됐습니다." : "새 PR 이 올라왔습니다."
        case .reviewRequested: return "나에게 리뷰가 요청됐습니다."
        case .reReviewRequested: return "수정 후 다시 리뷰를 요청했습니다."
        case .commentsOnMyPR(let added): return "코멘트 \(added)건이 달렸습니다."
        case .approvalsReached(let count): return "Approve \(count)명 — 머지할 수 있습니다."
        case .checksFailed: return "CI 가 실패했습니다."
        case .conflictAppeared: return "베이스와 충돌합니다. 해결이 필요합니다."
        case .newCommitsOnReviewed: return "리뷰한 커밋 이후 새 커밋이 올라왔습니다."
        case .merged: return "머지 완료."
        }
    }
}

public struct PRChangeSet: Sendable {
    public var pr: PullRequestInfo
    public var changes: [PRChange]
}

public enum PRChangeDetector {
    /// 스냅샷을 이만큼 지나면 잊는다. 무한히 쌓이면 파일이 계속 커진다.
    public static let memory: TimeInterval = 60 * 24 * 3600

    public static func snapshots(_ prs: [PullRequestInfo]) -> [String: PRSnapshot] {
        Dictionary(prs.map { ($0.id, PRSnapshot(pr: $0)) },
                   // 검색 API 페이지네이션은 오프셋 기반이라 같은 PR 이 두 페이지에 걸쳐 올 수 있다.
                   // uniqueKeysWithValues 로 만들면 그때 런타임이 트랩한다.
                   uniquingKeysWith: { _, new in new })
    }

    /// 이전 스냅샷 위에 지금 목록을 **덮어 쌓는다**.
    ///
    /// 통째로 교체하면 안 된다. 스냅샷은 "이 PR 을 이미 봤다" 는 기억인데, 목록은 보고 있는
    /// 탭에 따라 달라진다 — `리뷰 대기`(12건)에서 `전체 30일`(188건)로 옮기면 교체 방식에서는
    /// 176건이 "처음 보는 PR" 이 되어 전부 새 PR 알림으로 나갔다(실측). 탭을 되돌리면 기억이
    /// 다시 12건으로 줄어들어 같은 일이 반복된다.
    public static func merged(previous: [String: PRSnapshot],
                              current: [PullRequestInfo],
                              now: Date = Date()) -> [String: PRSnapshot] {
        var result = previous.filter { entry in
            // seenAt 이 없는 옛 기록은 이번에 시각을 받는다(버리지 않는다).
            guard let seenAt = entry.value.seenAt else { return true }
            return now.timeIntervalSince(seenAt) < memory
        }
        for pr in current {
            result[pr.id] = PRSnapshot(pr: pr, seenAt: now)
        }
        return result
    }

    /// 기억에 남은 것 중 가장 최근에 본 시각. "그 전에 만들어진 PR 은 새 PR 이 아니다" 의 기준이다.
    public static func lastSeen(_ snapshots: [String: PRSnapshot]) -> Date? {
        snapshots.values.compactMap(\.seenAt).max()
    }

    /// 이전 스냅샷과 비교해 알릴 만한 변화를 뽑는다.
    /// - Parameter approvalThreshold: 그 PR 의 Approve 임계값(PR 이 향하는 브랜치 규칙 — `Settings.approvalThreshold(for:)`).
    /// - Parameter lastSeenAt: 우리가 마지막으로 목록을 본 시각. 처음 보는 PR 이라도 이보다
    ///   먼저 만들어졌다면 새로 올라온 것이 아니라, 그동안 다른 탭을 보고 있어서 안 보였을 뿐이다.
    ///   `nil` 이면 이 판단을 하지 않는다(기억이 아예 없을 때).
    public static func changes(previous: [String: PRSnapshot],
                               current: [PullRequestInfo],
                               approvalThreshold: (PullRequestInfo) -> Int,
                               lastSeenAt: Date? = nil) -> [PRChangeSet] {
        var results: [PRChangeSet] = []
        for pr in current {
            var changes: [PRChange] = []
            let threshold = approvalThreshold(pr)

            guard let before = previous[pr.id] else {
                // 처음 보는 PR. 닫힌 PR 이 뒤늦게 목록에 들어온 경우는 알리지 않는다.
                // 우리가 마지막으로 본 시각보다 먼저 만들어진 PR 도 알리지 않는다 —
                // 새로 올라온 것이 아니라 그동안 안 보고 있던 것이다.
                let isNewToUs = lastSeenAt.map { pr.createdAt > $0 } ?? true
                if pr.isOpen, !pr.viewerDidAuthor, isNewToUs {
                    changes.append(.appeared(reviewRequested: pr.viewerHasReviewRequest))
                }
                if !changes.isEmpty { results.append(PRChangeSet(pr: pr, changes: changes)) }
                continue
            }

            if pr.viewerHasReviewRequest, !before.viewerHasReviewRequest, !pr.viewerDidAuthor {
                changes.append(before.viewerHasSubmittedReview ? .reReviewRequested : .reviewRequested)
            }
            if pr.viewerDidAuthor {
                let added = pr.threads.count - before.threadCount
                if added > 0 { changes.append(.commentsOnMyPR(added: added)) }
                if before.approvals < threshold, pr.approvalCount >= threshold {
                    changes.append(.approvalsReached(count: pr.approvalCount))
                }
                if isFailure(pr.checkState), !isFailure(before.checkState) {
                    changes.append(.checksFailed)
                }
                if pr.mergeable == .conflicting, before.mergeable != .conflicting {
                    changes.append(.conflictAppeared)
                }
                if pr.state == "MERGED", before.state != "MERGED" {
                    changes.append(.merged)
                }
            } else if pr.viewerHasSubmittedReview, pr.headRefOid != before.headSha, pr.isOpen {
                changes.append(.newCommitsOnReviewed)
            }

            if !changes.isEmpty { results.append(PRChangeSet(pr: pr, changes: changes)) }
        }
        return results
    }

    static func isFailure(_ state: String?) -> Bool {
        state == "FAILURE" || state == "ERROR"
    }
}

/// 어떤 변화를 알릴지. 기본값은 새 PR(나에게 요청된 것) · 내 PR 새 코멘트 · 머지 가능 · 충돌 넷이다
/// (사용자 결정, 2026-10-30). 리뷰어 지정·재리뷰 요청·CI 실패는 켤 수 있지만 기본으로는 끈다 — 리뷰어는 대개
/// PR 을 올릴 때 지정돼 "새 PR" 로 오고, CI 실패는 사용자가 받지 않아도 된다고 했다.
public struct PRChangeNotificationPrefs: Codable, Sendable, Equatable {
    public var newPR: Bool
    /// 새 PR 중 나에게 리뷰 요청이 온 것만 알린다.
    public var newPROnlyWhenReviewRequested: Bool
    public var reviewRequested: Bool
    public var reReviewRequested: Bool
    public var commentsOnMyPR: Bool
    public var approvalsReached: Bool
    public var checksFailed: Bool
    public var conflict: Bool
    public var newCommitsOnReviewed: Bool
    public var merged: Bool

    public static let `default` = PRChangeNotificationPrefs(
        newPR: true,
        newPROnlyWhenReviewRequested: true,
        reviewRequested: false,
        reReviewRequested: false,
        commentsOnMyPR: true,
        approvalsReached: true,
        checksFailed: false,
        conflict: true,
        newCommitsOnReviewed: false,
        merged: false)

    public init(newPR: Bool, newPROnlyWhenReviewRequested: Bool, reviewRequested: Bool,
                reReviewRequested: Bool, commentsOnMyPR: Bool, approvalsReached: Bool,
                checksFailed: Bool, conflict: Bool, newCommitsOnReviewed: Bool, merged: Bool) {
        self.newPR = newPR
        self.newPROnlyWhenReviewRequested = newPROnlyWhenReviewRequested
        self.reviewRequested = reviewRequested
        self.reReviewRequested = reReviewRequested
        self.commentsOnMyPR = commentsOnMyPR
        self.approvalsReached = approvalsReached
        self.checksFailed = checksFailed
        self.conflict = conflict
        self.newCommitsOnReviewed = newCommitsOnReviewed
        self.merged = merged
    }

    /// 결측 필드는 기본값으로 채운다(설정 파일 호환).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        let d = PRChangeNotificationPrefs.default
        func v(_ key: CodingKeys, _ fallback: Bool) -> Bool {
            (try? c.decodeIfPresent(Bool.self, forKey: key)) ?? fallback
        }
        newPR = v(.newPR, d.newPR)
        newPROnlyWhenReviewRequested = v(.newPROnlyWhenReviewRequested, d.newPROnlyWhenReviewRequested)
        reviewRequested = v(.reviewRequested, d.reviewRequested)
        reReviewRequested = v(.reReviewRequested, d.reReviewRequested)
        commentsOnMyPR = v(.commentsOnMyPR, d.commentsOnMyPR)
        approvalsReached = v(.approvalsReached, d.approvalsReached)
        checksFailed = v(.checksFailed, d.checksFailed)
        conflict = v(.conflict, d.conflict)
        newCommitsOnReviewed = v(.newCommitsOnReviewed, d.newCommitsOnReviewed)
        merged = v(.merged, d.merged)
    }

    public func allows(_ change: PRChange) -> Bool {
        switch change {
        case .appeared(let requested):
            guard newPR else { return false }
            return newPROnlyWhenReviewRequested ? requested : true
        case .reviewRequested: return reviewRequested
        case .reReviewRequested: return reReviewRequested
        case .commentsOnMyPR: return commentsOnMyPR
        case .approvalsReached: return approvalsReached
        case .checksFailed: return checksFailed
        case .conflictAppeared: return conflict
        case .newCommitsOnReviewed: return newCommitsOnReviewed
        case .merged: return merged
        }
    }
}
