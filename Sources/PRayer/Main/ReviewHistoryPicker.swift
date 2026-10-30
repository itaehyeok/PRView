import SwiftUI
import PRayerCore

/// 리뷰 생성 시각. 같은 PR 을 여러 번 리뷰했으면 눌러서 지난 리뷰를 고를 수 있다.
///
/// 리뷰가 1건뿐이면 그냥 시각만 보여 준다 — 고를 것이 없는데 화살표를 달면 눌러 보게 된다.
struct ReviewHistoryPicker: View {
    @Environment(AppModel.self) private var model
    let pr: PullRequestInfo
    let record: ReviewRecord

    @State private var showing = false

    private var history: [ReviewRecord] { model.history(for: pr) }

    /// 오래된 리뷰인가 — 그 뒤 새 커밋이 올라왔거나 하루가 넘었다. 이유는 시계 아이콘에 마우스를 올리면 나온다.
    /// "오래됨" 글자 배지는 두지 않는다 — 줄이 길어지고, 아이콘만으로 충분했다(사용자 결정, 2026-10-20).
    private var staleReason: String? {
        var reasons: [String] = []
        if record.headSha != pr.headRefOid { reasons.append("그 뒤 새 커밋이 올라왔습니다") }
        if Date().timeIntervalSince(record.createdAt) > 24 * 60 * 60 {
            reasons.append("리뷰한 지 \(RelativeTime.ago(record.createdAt))")
        }
        return reasons.isEmpty ? nil : "오래됨 — " + reasons.joined(separator: " · ")
    }

    @ViewBuilder
    private var staleIcon: some View {
        if let staleReason {
            Image(systemName: "clock.badge.exclamationmark")
                .font(.caption)
                .foregroundStyle(Color.orange)
                .help(staleReason)
        }
    }

    var body: some View {
        if history.count <= 1 {
            HStack(spacing: 3) {
                staleIcon
                Text(RelativeTime.ago(record.createdAt))
                    .font(.caption)
                    .help("리뷰 생성 \(record.createdAt.formatted(date: .abbreviated, time: .standard))")
            }
        } else {
            Button {
                showing = true
            } label: {
                HStack(spacing: 3) {
                    staleIcon
                    Text(RelativeTime.ago(record.createdAt))
                        .font(.caption)
                    Text("· 리뷰 \(history.count)회")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    Image(systemName: "chevron.down")
                        .font(.system(size: 7, weight: .bold))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("이 PR 을 리뷰한 내역 \(history.count)회 — 눌러서 지난 리뷰를 봅니다")
            .popover(isPresented: $showing, arrowEdge: .bottom) {
                list
            }
        }
    }

    private var list: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("이 PR 의 리뷰 내역")
                .font(.caption2.weight(.semibold))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.top, 8)
            ForEach(history, id: \.storageKey) { item in
                Button {
                    showing = false
                    model.selectRecord(item)
                } label: {
                    row(item)
                }
                .buttonStyle(.plain)
            }
            Text("최근 \(Store.historyLimit)건까지 남깁니다")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.horizontal, 10)
                .padding(.top, 4)
                .padding(.bottom, 8)
        }
        .frame(minWidth: 280)
    }

    private func row(_ item: ReviewRecord) -> some View {
        let isCurrent = item.storageKey == record.storageKey
        return HStack(alignment: .top, spacing: 6) {
            Image(systemName: "checkmark")
                .font(.system(size: 9, weight: .bold))
                .opacity(isCurrent ? 1 : 0)
            VStack(alignment: .leading, spacing: 1) {
                HStack(spacing: 5) {
                    Text(item.createdAt.formatted(date: .omitted, time: .shortened))
                        .font(.caption.weight(.medium).monospacedDigit())
                    Text(RelativeTime.ago(item.createdAt))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                    if let posted = item.posted {
                        Tag(text: ReviewEvent(rawValue: posted.event)?.label ?? "게시", color: .green)
                    } else {
                        Tag(text: "미게시", color: .secondary)
                    }
                    if item.headSha != pr.headRefOid {
                        // 그 뒤에 커밋이 올라온 리뷰. 지금 코드와 다를 수 있다.
                        Tag(text: "지난 커밋", color: .orange)
                    }
                }
                // 리뷰마다 무엇이 나왔는지 — 고를 때 '막는 이슈가 있던 리뷰' 를 바로 알아보게.
                Text(issueSummary(item) + " · \(item.isDeep ? "전체 리뷰" : "diff 리뷰")"
                     + " · \(item.usage.billableTokens / 1000)k 토큰")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 8)
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 4)
        .background(isCurrent ? Color.accentColor.opacity(0.10) : Color.clear)
        .contentShape(Rectangle())
    }

    /// "필수 1 · 코멘트 2" — 필수가 없으면 코멘트 수만.
    private func issueSummary(_ item: ReviewRecord) -> String {
        let issues = item.issues
        let blocking = issues.filter(\.isBlocking).count
        let count = issues.isEmpty ? "코멘트 없음" : "코멘트 \(issues.count)"
        return blocking > 0 ? "필수 \(blocking) · \(count)" : count
    }
}
