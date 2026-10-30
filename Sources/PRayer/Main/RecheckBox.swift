import SwiftUI
import PRayerCore

/// 지적 하나 아래에 붙는 "코멘트와 커밋 다시 확인하기".
///
/// 리뷰를 만든 뒤에 올라온 커밋·코멘트만 보고 이 지적이 처리됐는지 묻는다.
/// 새로 올라온 것이 없으면 버튼을 내지 않고 그 사실만 적는다 — 물어볼 것이 없는데
/// 토큰을 쓸 이유가 없다.
struct RecheckBox: View {
    @Environment(AppModel.self) private var model
    let pr: PullRequestInfo
    let record: ReviewRecord
    let subject: DiscussionSubject
    /// 항목 종류 이름(프롬프트에 그대로 들어간다).
    let kindLabel: String
    let severity: String?

    private var key: String { model.recheckKey(pr: pr, record: record, subject: subject) }
    private var result: ItemRecheck? { model.recheck(for: key) }
    private var isRunning: Bool { model.isRechecking(key) }
    private var delta: RecheckDelta { model.recheckDelta(pr: pr, record: record) }

    var body: some View {
        let delta = delta
        VStack(alignment: .leading, spacing: 5) {
            if let result {
                resultView(result)
            }
            controls(delta)
        }
        .padding(.top, 2)
    }

    // MARK: - 버튼 줄

    @ViewBuilder
    private func controls(_ delta: RecheckDelta) -> some View {
        if isRunning {
            HStack(spacing: 5) {
                ProgressView().controlSize(.small)
                Text("리뷰 이후 올라온 것들과 대조하는 중…")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } else if delta.isEmpty {
            // 부를 이유가 없다는 것을 그 자리에 적는다.
            Label("리뷰한 커밋(\(record.shortHead)) 이후 새 커밋도 새 코멘트도 없습니다.",
                  systemImage: "clock.badge.checkmark")
                .font(.caption2)
                .foregroundStyle(.tertiary)
        } else {
            Button {
                model.startRecheck(pr: pr, record: record, subject: subject, target: target)
            } label: {
                HStack(spacing: 4) {
                    Image(systemName: "arrow.triangle.2.circlepath")
                        .font(.system(size: 9, weight: .semibold))
                    Text(result == nil ? buttonTitle(delta) : "다시 확인 (\(summaryOf(delta)))")
                        .font(.caption2.weight(.semibold))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .foregroundStyle(Color.accentColor)
            .help("리뷰 이후 올라온 커밋과 코멘트만 AI 에게 보내 이 지적이 처리됐는지 물어봅니다. 코드 전체는 보내지 않습니다.")
        }
    }

    private func buttonTitle(_ delta: RecheckDelta) -> String {
        "코멘트와 커밋 다시 확인하기 (\(summaryOf(delta)))"
    }

    private func summaryOf(_ delta: RecheckDelta) -> String {
        var parts: [String] = []
        if !delta.newCommits.isEmpty { parts.append("새 커밋 \(delta.newCommits.count)개") }
        if !delta.newComments.isEmpty { parts.append("새 코멘트 \(delta.newComments.count)건") }
        return parts.joined(separator: " · ")
    }

    private var target: RecheckPromptBuilder.Target {
        RecheckPromptBuilder.Target(kindLabel: kindLabel,
                                    severity: severity,
                                    path: subject.path.isEmpty ? nil : subject.path,
                                    line: subject.line,
                                    body: subject.body,
                                    rationale: subject.rationale)
    }

    // MARK: - 결과

    private func resultView(_ result: ItemRecheck) -> some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 5) {
                Image(systemName: result.status.symbolName)
                    .font(.caption)
                    .foregroundStyle(tint(result.status))
                Text(result.status.label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(tint(result.status))
                Text("· 커밋 \(String(result.checkedHeadSha.prefix(7))) 기준")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
            }
            Text(result.summaryKo)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            // 인덱스로 센다. 근거 두 건이 같은 id 를 갖게 되면 ForEach 가 한 줄을 조용히 버린다.
            ForEach(Array(result.evidence.enumerated()), id: \.offset) { _, evidence in
                HStack(alignment: .top, spacing: 5) {
                    Image(systemName: symbol(evidence.kind))
                        .font(.system(size: 9))
                        .foregroundStyle(.tertiary)
                        .padding(.top, 2)
                    VStack(alignment: .leading, spacing: 0) {
                        Text(reference(evidence))
                            .font(.caption2.monospaced())
                            .foregroundStyle(.secondary)
                        Text(evidence.note)
                            .font(.caption2)
                            .foregroundStyle(.secondary)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
            if result.isStale(against: pr.headRefOid) {
                // 판단한 뒤로 PR 이 또 움직였다. 낡은 결론을 최신인 척 두지 않는다.
                Label("그 뒤로 PR 이 또 바뀌었습니다. 다시 확인해 주세요.",
                      systemImage: "exclamationmark.triangle.fill")
                    .font(.caption2)
                    .foregroundStyle(.orange)
            }
        }
        .padding(7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(tint(result.status).opacity(0.07), in: RoundedRectangle(cornerRadius: 5))
    }

    private func reference(_ evidence: ItemRecheck.Evidence) -> String {
        var text = evidence.ref
        if let path = evidence.path, !path.isEmpty {
            let name = path.split(separator: "/").last.map(String.init) ?? path
            text += " · \(name)\(evidence.line.map { ":\($0)" } ?? "")"
        }
        return text
    }

    private func symbol(_ kind: ItemRecheck.Evidence.Kind) -> String {
        switch kind {
        case .commit: return "arrow.up.circle"
        case .comment: return "text.bubble"
        case .code: return "chevron.left.forwardslash.chevron.right"
        }
    }

    private func tint(_ status: ItemRecheck.Status) -> Color {
        switch status {
        case .fixedInCommit: return .green
        case .partiallyFixed: return .orange
        case .answeredInComment: return .accentColor
        case .untouched: return .orange
        case .cannotTell: return .secondary
        }
    }
}
