import SwiftUI
import PRayerCore

/// 내 PR 상세의 탭 줄 바로 아래 머지 줄 — 어느 탭을 보든 같은 자리에 있다. 남의 PR 이면 그리지 않는다.
///
/// 왼쪽은 Approve 수(아바타 + "Approve 2/3")와 막힌 이유 한 줄, 오른쪽은 머지 버튼(사용자 결정 — 시안 A "한 줄 띠").
/// 머지할 수 있게 되면 줄을 옅은 초록으로 칠하고 버튼 앞에 "보내는 브랜치 → 받는 브랜치" 를 띄워,
/// 어디로 합쳐지는지 누르기 전에 보이게 한다. 버튼은 막혀 있어도 초록을 옅게 남긴다 — 회색이면 머지 버튼으로
/// 안 보였다(사용자 피드백). 누르면 바로 머지하지 않고 확인 대화상자(시트)를 띄운다 — 머지는 되돌릴 수 없다.
/// 방식은 대화상자 안 드롭다운에서 고르고 늘 Merge commit 에서 시작한다(사용자 결정 — 시안 B).
/// 거쳐 온 안: 줄 아래 확인 줄 + 누른 버튼이 "취소" 로 바뀜(누른 자리의 뜻이 반대로 바뀌어 두 번 찾아 눌러야 했다),
/// 버튼 밑 팝오버(0.6.1 베타 2, "별로").
struct MergeBar: View {
    @Environment(AppModel.self) private var model
    let pr: PullRequestInfo

    @State private var confirming = false
    @State private var options: MergeOptions?
    @State private var method: MergeMethod = .merge
    @State private var merging = false
    @State private var failure: String?
    /// `PRAYER_DEBUG_MERGE` 로 띄운 확인용 빌드에서 "머지하기" 를 누른 뒤(실제로는 머지하지 않았다).
    @State private var previewMerged = false

    private var threshold: Int {
        if ["ready", "confirm"].contains(DebugLaunch.mergePreview), pr.approvalCount > 0 { return pr.approvalCount }
        return model.settings.approvalThreshold(for: pr)
    }

    private var readiness: MergeReadiness {
        if previewMerged { return .merged }
        if let forced = DebugLaunch.mergeReadiness, pr.viewerDidAuthor { return forced }
        return MergeReadiness.resolve(pr, threshold: threshold)
    }

    var body: some View {
        switch readiness {
        case .hidden:
            EmptyView()
        case .merged:
            VStack(spacing: 0) {
                mergedRow
                Divider()
            }
        case .ready, .blocked:
            VStack(spacing: 0) {
                mainRow
                // 대화상자가 열려 있으면 실패는 그 안에 적는다.
                if let failure, !confirming {
                    failureRow(failure)
                }
                Divider()
            }
            .task {
                guard DebugLaunch.mergePreview == "confirm" else { return }
                // 창이 자리를 잡기 전에 띄우면 시트가 엉뚱한 데 붙거나 안 뜬다(ToolbarPopover 와 같다).
                try? await Task.sleep(for: .seconds(2))
                confirming = true
            }
        }
    }

    // MARK: 머지 전

    private var mainRow: some View {
        let isReady = readiness == .ready
        return HStack(spacing: 10) {
            ApprovalFaces(pr: pr, threshold: threshold)
            VStack(alignment: .leading, spacing: 1) {
                Text(verbatim: "Approve \(pr.approvalCount)/\(threshold)")
                    .font(.system(size: 12.5, weight: .semibold).monospacedDigit())
                    .foregroundStyle(pr.approvalCount >= threshold ? Color.green : Color.primary)
                    .fixedSize()
                if let caption {
                    caption
                        .font(.system(size: 11))
                        .help(captionHelp)
                }
            }
            .lineLimit(1)
            Spacer(minLength: 12)
            // 자리가 모자라면 아래 설명 줄을 먼저 줄인다 — 머지할 수 있을 때 가장 봐야 할 것은 어디서 어디로 가는지다.
            if isReady {
                BranchFlow(head: pr.headRefName, base: pr.baseRefName, tint: MergeButtonStyle.green)
                    .layoutPriority(1)
            }
            Button {
                failure = nil
                confirming = true
            } label: {
                Label("머지", systemImage: isReady ? "arrow.triangle.merge" : "lock.fill")
            }
            .buttonStyle(MergeButtonStyle())
            .disabled(!isReady || merging)
            .fixedSize()
            .help(isReady ? "\(pr.headRefName) 를 \(pr.baseRefName) 에 머지합니다. 누르면 확인 창이 뜹니다." : blockMessage ?? "")
            // 머지할 수 없게 바뀌면(새로 받은 PR 이 막힘) 열려 있던 대화상자도 닫는다. 머지하는 중에는 그대로 둔다.
            .sheet(isPresented: Binding(get: { confirming && (isReady || merging) }, set: { confirming = $0 })) {
                confirmSheet
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(isReady ? Color.green.opacity(0.07) : Color.clear)
    }

    /// "Approve 2/3" 아래 한 줄 — 막힌 이유. 지난 커밋에 한 승인이 섞였으면 뒤에 덧붙인다.
    /// 머지할 수 있을 때는 "머지할 수 있습니다" 를 적지 않는다 — 초록 줄과 버튼이 이미 그 말이고, 그 자리를 브랜치 칩에 준다
    /// (적어 두면 좁은 창에서 "머지할… · 2…" 로 잘렸다). 덧붙일 말이 없으면 줄 자체가 없다.
    private var caption: Text? {
        let stale = pr.approvalCount - pr.approvalCountAtHead
        var parts: [Text] = []
        if let blockMessage {
            parts.append(Text(blockMessage).foregroundColor(.secondary))
        } else if pr.checkOutcome.isProblem {
            parts.append(Text("필수 아닌 CI 실패 있음").foregroundColor(.orange))
        }
        if stale > 0 {
            // 짧게 쓴다 — 머지할 수 있을 때는 브랜치 칩이 자리를 먼저 가져가 "2명은 지난 커…" 로 잘렸다. 긴 말은 툴팁에.
            parts.append(Text("\(stale)명 지난 커밋").foregroundColor(.orange))
        }
        guard let first = parts.first else { return nil }
        return parts.dropFirst().reduce(first) { $0 + Text(" · ").foregroundColor(.secondary) + $1 }
    }

    private var captionHelp: String {
        let stale = pr.approvalCount - pr.approvalCountAtHead
        guard stale > 0 else { return "" }
        return "Approve \(pr.approvalCount)명 중 \(stale)명은 지난 커밋에 승인했습니다. GitHub 이 그 승인을 남겨 두어 수에 넣었습니다."
    }

    private var blockMessage: String? {
        if case .blocked(let block) = readiness { return block.message }
        return nil
    }

    // MARK: 확인 대화상자

    /// 창 위에서 내려오는 시트. Return 은 머지, Esc 는 취소. 머지하는 동안은 닫히지 않는다.
    private var confirmSheet: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "arrow.triangle.merge")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(MergeButtonStyle.green)
                    .frame(width: 34)
                VStack(alignment: .leading, spacing: 6) {
                    (Text(verbatim: pr.baseRefName).font(.headline.monospaced()) + Text(" 에 머지할까요?"))
                        .font(.headline)
                    (Text(verbatim: pr.headRefName).font(.callout.monospaced()) + Text(mergeObject))
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Text("머지는 되돌릴 수 없습니다.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                Text("머지 방식")
                    .font(.callout)
                if let options {
                    Picker("머지 방식", selection: $method) {
                        ForEach(options.allowed) { item in
                            Text(item.label).tag(item)
                        }
                    }
                    .labelsHidden()
                    .pickerStyle(.menu)
                    .fixedSize()
                    .disabled(merging)
                } else {
                    ProgressView()
                        .controlSize(.small)
                }
            }
            .padding(.leading, 48)
            if let failure {
                HStack(alignment: .top, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                    Text(failure)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
                .font(.system(size: 11.5))
                .foregroundStyle(.red)
                .padding(.leading, 48)
            }
            HStack(spacing: 8) {
                Spacer(minLength: 0)
                Button("취소") {
                    confirming = false
                    failure = nil
                }
                .keyboardShortcut(.cancelAction)
                .disabled(merging)
                Button {
                    Task { await performMerge() }
                } label: {
                    if merging {
                        HStack(spacing: 5) {
                            ProgressView()
                                .controlSize(.mini)
                            Text("머지하는 중")
                        }
                    } else {
                        Text("머지")
                    }
                }
                .buttonStyle(MergeButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(merging || options == nil)
                .fixedSize()
            }
        }
        .padding(20)
        .frame(width: 420, alignment: .leading)
        .interactiveDismissDisabled(merging)
        .task {
            if options == nil {
                options = await model.mergeOptions(for: pr.repo)
            }
            // 열 때마다 Merge commit 에서 시작한다(사용자 결정). GitHub 이 기억하는 "마지막에 쓴 방식" 은 따르지 않는다.
            // 레포가 Merge commit 을 막았으면 GitHub 이 고른 기본으로.
            if let options {
                method = options.allowed.contains(.merge) ? .merge : options.preferred
            }
        }
    }

    /// "보내는 브랜치" 뒤에 붙는 말. 커밋은 최근 30개까지만 받으므로 30개면 "이상" 을 붙인다.
    private var mergeObject: String {
        let count = pr.commits.count
        if count == 0 { return " 를 합칩니다." }
        return count >= 30 ? " 의 커밋 30개 이상을 합칩니다." : " 의 커밋 \(count)개를 합칩니다."
    }

    private func failureRow(_ message: String) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "exclamationmark.triangle.fill")
            Text(message)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .font(.system(size: 11.5))
        .foregroundStyle(.red)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    private func performMerge() async {
        merging = true
        failure = nil
        defer { merging = false }
        if DebugLaunch.mergePreview != nil {
            try? await Task.sleep(for: .seconds(1))
            confirming = false
            previewMerged = true
            return
        }
        do {
            try await model.merge(pr, method: method)
            confirming = false
        } catch {
            failure = error.localizedDescription
        }
    }

    // MARK: 머지 뒤

    /// GitHub 웹의 머지됨 색(보라)과 맞춘다.
    private var mergedRow: some View {
        HStack(spacing: 8) {
            Image(systemName: "arrow.triangle.merge")
                .font(.system(size: 13, weight: .semibold))
            Text("머지됨")
                .font(.system(size: 12.5, weight: .semibold))
            BranchFlow(head: pr.headRefName, base: pr.baseRefName, tint: .purple)
            if let by = pr.mergedBy {
                Text("· \(model.settings.displayName(by))")
                    .foregroundStyle(.secondary)
            }
            if let at = pr.mergedAt {
                RelativeTimeText(date: at, style: .ago)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: 0)
        }
        .font(.system(size: 11.5))
        .foregroundStyle(.purple)
        .lineLimit(1)
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
        .background(Color.purple.opacity(0.07))
    }
}

/// Approve 한 사람 얼굴 + 아직 빈 자리(점선 동그라미). 기준 수만큼 자리를 둔다.
/// 지난 커밋에 한 승인은 흐리게 — 목록 행 요약과 같은 뜻이다.
private struct ApprovalFaces: View {
    @Environment(AppModel.self) private var model
    let pr: PullRequestInfo
    let threshold: Int

    var body: some View {
        let approvers = self.approvers
        HStack(spacing: 3) {
            ForEach(Array(approvers.enumerated()), id: \.offset) { _, approver in
                Avatar(login: approver.login, name: model.settings.displayName(approver.login), size: 20)
                    .opacity(approver.fresh ? 1 : 0.4)
                    .help(model.settings.displayName(approver.login) + (approver.fresh ? " — Approve" : " — 지난 커밋에 Approve"))
            }
            ForEach(0..<max(0, threshold - approvers.count), id: \.self) { _ in
                Circle()
                    .strokeBorder(Color.secondary.opacity(0.55), style: StrokeStyle(lineWidth: 1, dash: [2.5, 2]))
                    .frame(width: 20, height: 20)
            }
        }
    }

    /// 사람마다 하나. 지금 커밋에 한 승인이 있으면 그 사람은 지금 것으로 친다. 지금 것 먼저.
    private var approvers: [(login: String, fresh: Bool)] {
        var order: [String] = []
        var fresh: [String: Bool] = [:]
        for approval in pr.approvals {
            if fresh[approval.login] == nil { order.append(approval.login) }
            fresh[approval.login] = (fresh[approval.login] ?? false) || approval.commitOid == pr.headRefOid
        }
        let list = order.map { (login: $0, fresh: fresh[$0] ?? false) }
        return list.filter(\.fresh) + list.filter { !$0.fresh }
    }
}

/// "보내는 브랜치 → 받는 브랜치". 받는 쪽만 색을 칠해 어디로 들어가는지 눈에 먼저 띄게 한다.
/// 자리가 모자라면 보내는 쪽 가운데를 줄인다(받는 쪽은 대개 짧다 — main·develop).
private struct BranchFlow: View {
    let head: String
    let base: String
    let tint: Color

    var body: some View {
        HStack(spacing: 5) {
            chip(head, color: .primary, border: .secondary)
            Image(systemName: "arrow.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(tint)
            chip(base, color: tint, border: tint)
                .fixedSize()
        }
        .help("\(head) → \(base)")
    }

    private func chip(_ name: String, color: Color, border: Color) -> some View {
        Text(verbatim: name)
            .font(.caption.monospaced())
            .lineLimit(1)
            .truncationMode(.middle)
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .background(RoundedRectangle(cornerRadius: 5).fill(Color(nsColor: .controlBackgroundColor)))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(border.opacity(0.45), lineWidth: 0.5))
    }
}

/// 머지 버튼. GitHub 웹 머지 버튼과 같은 초록(#1F883D)에 흰 글자 — 밝은 모드·어두운 모드 둘 다 읽힌다.
/// 막혀 있으면 같은 초록을 옅게 — 무슨 버튼인지는 알아보되 누를 수 없다는 게 보이게.
struct MergeButtonStyle: ButtonStyle {
    static let green = Color(red: 0x1F / 255, green: 0x88 / 255, blue: 0x3D / 255)
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: 12.5, weight: .semibold))
            .foregroundStyle(Color.white.opacity(isEnabled ? 1 : 0.9))
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .background(RoundedRectangle(cornerRadius: 6)
                .fill(Self.green.opacity(isEnabled ? (configuration.isPressed ? 0.8 : 1) : 0.35)))
            .contentShape(RoundedRectangle(cornerRadius: 6))
    }
}
