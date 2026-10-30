import Foundation

/// PR 목록에서 "최근에 누가 뭘 했는지" 를 보여주기 위한 표시용 활동 1건.
/// CI 상태 변화 같은 자동화 이벤트는 담지 않는다 — 화면에 따로 표시되고 있고,
/// 여기서는 사람의 리뷰 활동을 먼저 보여주는 것이 목적이다.
public struct PRActivity: Sendable, Codable, Hashable, Identifiable {
    public enum Kind: String, Sendable, Codable, CaseIterable {
        case commented
        case approved
        case changesRequested
        case dismissed
        case pushed
        case merged
        case closed
        case reopened

        /// 목록에 그대로 찍히는 영문 라벨. 폭이 좁아 길게 쓰지 않는다.
        public var label: String {
            switch self {
            case .commented: return "Commented"
            case .approved: return "Approved"
            case .changesRequested: return "Requested changes"
            case .dismissed: return "Dismissed review"
            case .pushed: return "Pushed commits"
            case .merged: return "Merged"
            case .closed: return "Closed"
            case .reopened: return "Reopened"
            }
        }

        public var symbolName: String {
            switch self {
            case .commented: return "text.bubble"
            case .approved: return "checkmark.circle.fill"
            case .changesRequested: return "exclamationmark.triangle.fill"
            case .dismissed: return "arrow.uturn.backward.circle"
            case .pushed: return "arrow.up.circle"
            case .merged: return "arrow.triangle.merge"
            case .closed: return "xmark.circle"
            case .reopened: return "arrow.clockwise.circle"
            }
        }

        init?(reviewState: String) {
            switch reviewState.uppercased() {
            case "APPROVED": self = .approved
            case "CHANGES_REQUESTED": self = .changesRequested
            case "COMMENTED": self = .commented
            case "DISMISSED": self = .dismissed
            default: return nil   // PENDING 등 제출되지 않은 리뷰는 활동이 아니다.
            }
        }
    }

    public var kind: Kind
    /// GitHub 로그인. 화면에는 Settings.displayName 으로 줄여서 찍는다.
    public var actor: String
    public var at: Date
    /// 코멘트 본문 일부. 본문이 없는 활동(Approve 등)은 nil.
    public var excerpt: String?

    /// 본문 일부까지 섞는다. 커밋을 하나하나 낼 때는 같은 사람이 같은 초에 여러 건을
    /// 올릴 수 있어서 종류·사람·시각만으로는 ForEach 가 항목을 구분하지 못한다.
    public var id: String {
        "\(kind.rawValue)|\(actor)|\(at.timeIntervalSince1970)|\(excerpt ?? "")"
    }

    public init(kind: Kind, actor: String, at: Date, excerpt: String? = nil) {
        self.kind = kind
        self.actor = actor
        self.at = at
        self.excerpt = excerpt
    }
}

public enum PRActivityBuilder {
    /// 이미 받아온 PR 데이터만으로 최근 활동을 만든다. 추가 API 호출은 하지 않는다.
    ///
    /// - Parameters:
    ///   - limit: 앞에서 몇 건만 남길지. `nil` 이면 전부 — "늘리기" 로 전체 내역을 볼 때 쓴다.
    ///   - collapseCommits: 커밋 푸시를 최근 1건으로 접을지. 목록에서 3줄만 보일 때는 접어야
    ///     한 번의 푸시가 줄을 다 먹지 않는다. 전체 내역을 볼 때는 펴서 커밋을 하나씩 보여준다.
    public static func build(from pr: PullRequestInfo,
                             limit: Int? = 3,
                             collapseCommits: Bool = true,
                             now: Date = Date()) -> [PRActivity] {
        var activities: [PRActivity] = []

        // 1) 리뷰 제출(Approve / Request changes / Comment / Dismiss).
        for event in pr.reviewEvents {
            guard let kind = PRActivity.Kind(reviewState: event.state) else { continue }
            activities.append(PRActivity(kind: kind,
                                         actor: event.author,
                                         at: event.submittedAt,
                                         excerpt: excerpt(event.body)))
        }

        // 2) PR 대화 코멘트(인라인이 아닌 코멘트).
        for comment in pr.issueComments {
            activities.append(PRActivity(kind: .commented,
                                         actor: comment.author,
                                         at: comment.createdAt,
                                         excerpt: excerpt(comment.body)))
        }

        // 3) 인라인 코멘트. 보통 리뷰 제출 1건에 묶여 오므로 새 항목으로 세지 않고,
        //    본문이 비어 있는 리뷰 항목의 미리보기를 채우는 데 쓴다.
        for thread in pr.threads {
            for comment in thread.comments {
                guard let at = isoDate(comment.createdAt) else { continue }
                if let index = activities.firstIndex(where: {
                    $0.actor == comment.author
                        && ($0.kind == .commented || $0.kind == .changesRequested)
                        && abs($0.at.timeIntervalSince(at)) < 300
                }) {
                    if activities[index].excerpt == nil {
                        activities[index].excerpt = excerpt(comment.body)
                    }
                } else {
                    activities.append(PRActivity(kind: .commented,
                                                 actor: comment.author,
                                                 at: at,
                                                 excerpt: excerpt(comment.body)))
                }
            }
        }

        // 4) 커밋 푸시. 줄이 몇 개뿐일 때는 가장 최근 1건만 넣는다 —
        //    같은 푸시의 커밋 여러 개가 줄을 다 먹으면 안 된다.
        if collapseCommits {
            if let latest = pr.commits.max(by: { $0.committedDate < $1.committedDate }) {
                activities.append(PRActivity(kind: .pushed, actor: latest.author, at: latest.committedDate))
            }
        } else {
            for commit in pr.commits {
                activities.append(PRActivity(kind: .pushed,
                                             actor: commit.author,
                                             at: commit.committedDate,
                                             excerpt: excerpt(commit.messageHeadline)))
            }
        }

        // 5) 상태 변화. 시각을 아는 것만 넣는다(추정하지 않는다).
        if let mergedAt = pr.mergedAt {
            activities.append(PRActivity(kind: .merged, actor: pr.mergedBy ?? "", at: mergedAt))
        } else if let closedAt = pr.closedAt {
            activities.append(PRActivity(kind: .closed, actor: "", at: closedAt))
        }

        let ordered = collapseRepeatedReviewStates(activities
            .filter { $0.at <= now.addingTimeInterval(60) }   // 시계 오차로 미래 항목이 튀는 것 방지
            .sorted { $0.at > $1.at })
        guard let limit else { return ordered }
        return Array(ordered.prefix(limit))
    }

    /// 같은 사람이 같은 상태의 리뷰를 여러 번 제출하는 일이 있다
    /// (실측: 한 사람이 8초 사이에 Approve 를 2번 냈다 — 04:50:51, 04:50:59).
    /// GitHub 은 그걸 승인 1건으로 세지만(`latestOpinionatedReviews` 는 사람당 1건) `reviews` 에는
    /// 둘 다 남아, 목록에 똑같은 줄이 두 번 뜬다.
    ///
    /// 상태를 나타내는 리뷰(승인·변경요청·무효)는 사람별로 가장 최근 것만 남기고, 묶은 개수를
    /// 툴팁에 적어 둔다 — 조용히 지우지는 않는다. 코멘트는 묶지 않는다: 여러 번 코멘트한 것은
    /// 실제로 서로 다른 활동이다.
    ///
    /// 입력은 최신순으로 정렬돼 있어야 한다(먼저 만나는 것이 최신이다).
    static func collapseRepeatedReviewStates(_ activities: [PRActivity]) -> [PRActivity] {
        let stateKinds: Set<PRActivity.Kind> = [.approved, .changesRequested, .dismissed]
        var kept: [PRActivity] = []
        var keptIndex: [String: Int] = [:]
        var counts: [String: Int] = [:]
        for activity in activities {
            guard stateKinds.contains(activity.kind) else {
                kept.append(activity)
                continue
            }
            let key = "\(activity.kind.rawValue)|\(activity.actor.lowercased())"
            counts[key, default: 0] += 1
            if keptIndex[key] == nil {
                keptIndex[key] = kept.count
                kept.append(activity)
            }
        }
        for (key, count) in counts where count > 1 {
            guard let index = keptIndex[key] else { continue }
            let note = "같은 상태의 리뷰 \(count)건을 하나로 묶었습니다."
            kept[index].excerpt = [kept[index].excerpt, note]
                .compactMap { $0 }
                .filter { !$0.isEmpty }
                .joined(separator: " · ")
        }
        return kept
    }

    /// 툴팁에 넣을 한두 줄. 줄바꿈을 없애고 길면 자른다.
    static func excerpt(_ body: String, limit: Int = 140) -> String? {
        let collapsed = body
            .split(whereSeparator: \.isNewline)
            .map { $0.trimmingCharacters(in: .whitespaces) }
            .filter { !$0.isEmpty }
            .joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        guard !collapsed.isEmpty else { return nil }
        if collapsed.count <= limit { return collapsed }
        return String(collapsed.prefix(limit)).trimmingCharacters(in: .whitespaces) + "…"
    }

    public static func isoDate(_ text: String) -> Date? {
        guard !text.isEmpty else { return nil }
        return try? Date(text, strategy: .iso8601)
    }
}
