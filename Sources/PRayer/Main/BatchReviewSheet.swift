import SwiftUI
import PRayerCore

/// PR 여러 개에 한꺼번에 거는 리뷰의 확인 창(AppModel+BatchReview).
///
/// 한 개일 때 따로 뜨던 확인 — 스냅샷 클론(SnapshotCloneConfirm)·큰 파일 빼기(SkipFilesSheet)·변경 많음(LargeReviewConfirm) —
/// 을 한 화면에 모아 한 번만 묻는다. 줄마다 체크를 빼면 그 PR 은 안 건다. 이미 리뷰 중인 PR 은 큐가 다시 받지 않으므로
/// 체크를 끄고 막아 둔다. Esc 는 아무것도 걸지 않고 닫는다.
struct BatchReviewSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: PendingBatchReview

    /// PR id → 잰 값. 창을 띄운 뒤 diff 를 받아 채운다(받아 둔 것은 바로).
    @State private var checks: [String: BatchReviewCheck] = [:]
    /// 체크를 뺀 PR.
    @State private var excluded: Set<String> = []
    /// 한 개일 때 창의 기본 단추가 "빼고 리뷰" 라 여기도 켠 채로 연다.
    @State private var skipLargeFiles = true
    @State private var remember = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            header
            rows
            if !largeFiles.isEmpty { skipSection }
            if request.deep, !reposNeedingClone.isEmpty { cloneSection }
            Divider()
            totals
            buttons
        }
        .padding(18)
        .frame(width: 520)
        .task { measure() }
        .onExitCommand { cancel() }
    }

    // MARK: - 머리

    private var header: some View {
        VStack(alignment: .leading, spacing: 4) {
            Text("PR \(request.prs.count)개를 \(request.deep ? "전체 리뷰" : "diff 리뷰")합니다")
                .font(.headline)
            Text("하나씩 차례로 돌며 초안만 만듭니다. 게시는 PR 마다 읽어 보고 합니다."
                 + (request.closedCount > 0 ? " 같이 고른 닫힌 PR \(request.closedCount)개는 뺐습니다." : ""))
                .font(.callout)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
    }

    // MARK: - PR 줄

    private var rows: some View {
        ScrollView {
            VStack(spacing: 0) {
                ForEach(request.prs) { pr in
                    row(pr)
                        .padding(.vertical, 5)
                    Divider()
                }
            }
        }
        // 많이 고르면 창이 화면을 넘지 않게 목록만 민다.
        .frame(maxHeight: min(CGFloat(request.prs.count) * 31, 280))
    }

    private func row(_ pr: PullRequestInfo) -> some View {
        let active = isActive(pr)
        return HStack(spacing: 8) {
            Toggle(isOn: Binding(get: { !active && !excluded.contains(pr.id) },
                                 set: { on in
                                     if on { excluded.remove(pr.id) } else { excluded.insert(pr.id) }
                                 })) {
                HStack(spacing: 6) {
                    Text(verbatim: "#\(pr.number)")
                        .font(.callout.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Text(pr.title)
                        .font(.callout)
                        .lineLimit(1)
                        .truncationMode(.tail)
                }
            }
            .toggleStyle(.checkbox)
            .disabled(active)
            .help(pr.title)
            Spacer(minLength: 8)
            status(pr, active: active)
                .fixedSize()
        }
        .opacity(active || excluded.contains(pr.id) ? 0.55 : 1)
    }

    @ViewBuilder
    private func status(_ pr: PullRequestInfo, active: Bool) -> some View {
        if active {
            Text("이미 리뷰 중")
                .font(.caption)
                .foregroundStyle(.secondary)
        } else if let check = checks[pr.id] {
            HStack(spacing: 6) {
                if !check.skippable.isEmpty {
                    Text("큰 파일 \(check.skippable.count)")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(skipLargeFiles ? Color.secondary : Color.orange)
                        .padding(.horizontal, 5)
                        .padding(.vertical, 1)
                        .background(Capsule().strokeBorder(skipLargeFiles ? Color.secondary.opacity(0.4)
                                                                            : Color.orange.opacity(0.6),
                                                           lineWidth: 0.5))
                        .help((skipLargeFiles ? "빼고 리뷰합니다:\n" : "그대로 리뷰합니다:\n")
                              + check.skippable.map { "\($0.path) (\($0.changedLines.formatted())줄)" }.joined(separator: "\n"))
                }
                let lines = linesToReview(check)
                let large = lines > model.settings.manualSizeWarnLines
                Text("\(check.measured ? "" : "약 ")\(lines.formatted())줄 · \(tokens(PromptBuilder.estimatedTokens(changedLines: lines)))")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(large ? Color.orange : Color.secondary)
                    .help(check.measured
                          ? (large ? "변경이 많습니다 — 한 개일 때 확인 창을 띄우는 기준(\(model.settings.manualSizeWarnLines.formatted())줄)을 넘습니다." : "")
                          : "diff 를 받지 못해 PR 목록의 줄 수로 어림했습니다. 큰 파일이 있는지는 모릅니다.")
            }
        } else {
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text("변경 확인 중")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 큰 파일

    private var skipSection: some View {
        let files = largeFiles
        let names = files.prefix(3).map { ($0.path as NSString).lastPathComponent }.joined(separator: ", ")
            + (files.count > 3 ? " 외 \(files.count - 3)" : "")
        return VStack(alignment: .leading, spacing: 4) {
            Toggle("한 파일에 \(SkippableFiles.minLines.formatted())줄 넘게 바뀐 파일 \(files.count)개는 빼고 리뷰",
                   isOn: $skipLargeFiles)
                .toggleStyle(.checkbox)
            Text(names)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
                .padding(.leading, 20)
                .help(files.map(\.path).joined(separator: "\n"))
            Toggle("다음부터 이 파일들은 묻지 않고 빼기", isOn: $remember)
                .toggleStyle(.checkbox)
                .disabled(!skipLargeFiles)
                .padding(.leading, 20)
        }
    }

    // MARK: - 스냅샷 클론

    private var cloneSection: some View {
        let repos = reposNeedingClone
        let missing = repos.compactMap { repo -> String? in
            if case .needsSnapshot(let path?) = model.reviewSource(for: repo) { return path }
            return nil
        }
        return HStack(alignment: .top, spacing: 10) {
            Image(systemName: "arrow.triangle.branch")
                .foregroundStyle(Color.accentColor)
                .frame(width: 18)
            VStack(alignment: .leading, spacing: 3) {
                Text("처음 클론: \(repos.map(\.name).joined(separator: ", "))")
                    .font(.callout.weight(.medium))
                Text("전체 리뷰는 프로젝트 전체를 읽어서 레포마다 처음 한 번 클론이 필요합니다(몇십 초). 다음 리뷰부터는 달라진 파일만 받습니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !missing.isEmpty {
                    Text("전에 연결한 클론 폴더(\(missing.map { ($0 as NSString).abbreviatingWithTildeInPath }.joined(separator: ", ")))를 찾을 수 없어 새로 클론합니다.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - 합계·단추

    private var totals: some View {
        let estimate = chosen.reduce(0) { sum, pr in
            sum + PromptBuilder.estimatedTokens(changedLines: checks[pr.id].map(linesToReview) ?? pr.changedLines)
        }
        let over = model.settings.fiveHourTokenCap > 0
            && model.fiveHourTokens + estimate > model.settings.fiveHourTokenCap
        return VStack(alignment: .leading, spacing: 5) {
            line("예상 소모", isMeasuring ? "확인 중…" : "약 \(tokens(estimate))",
                 note: chosen.isEmpty ? nil : "PR \(chosen.count)개 · \(modelNote)")
            line("최근 5시간 사용", tokens(model.fiveHourTokens),
                 note: model.settings.fiveHourTokenCap > 0 ? "상한 \(tokens(model.settings.fiveHourTokenCap))" : nil,
                 warning: over && !isMeasuring)
            if over, !isMeasuring {
                Label("이 리뷰들까지 더하면 5시간 상한을 넘습니다.", systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
    }

    private var buttons: some View {
        HStack {
            Button("취소", role: .cancel) { cancel() }
                .keyboardShortcut(.cancelAction)
            Spacer()
            Button(startTitle) {
                model.confirmBatchReview(request, chosen: chosen, checks: checks,
                                         skipLargeFiles: skipLargeFiles && !largeFiles.isEmpty,
                                         remember: remember)
                dismiss()
            }
            .keyboardShortcut(.defaultAction)
            // 다 재기 전에 시작하면 그 PR 의 큰 파일을 빼지 못한다. 길어야 몇 초다.
            .disabled(chosen.isEmpty || isMeasuring)
        }
        .padding(.top, 2)
    }

    private var startTitle: String {
        let count = chosen.count
        guard count > 0 else { return "리뷰 시작" }
        return request.deep && !reposNeedingClone.isEmpty ? "클론하고 \(count)개 리뷰 시작" : "\(count)개 리뷰 시작"
    }

    private func line(_ title: String, _ value: String, note: String? = nil, warning: Bool = false) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(title)
                .font(.callout)
                .foregroundStyle(.secondary)
                .frame(width: 96, alignment: .leading)
            Text(value)
                .font(.callout.monospacedDigit().weight(.medium))
                .foregroundStyle(warning ? Color.orange : Color.primary)
            if let note {
                Text("· \(note)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: 0)
        }
    }

    // MARK: - 셈

    private func isActive(_ pr: PullRequestInfo) -> Bool {
        model.job(for: pr)?.isActive ?? false
    }

    /// 체크가 남아 있고 이미 도는 중이 아닌 PR — 큐에 넣을 것.
    private var chosen: [PullRequestInfo] {
        request.prs.filter { !excluded.contains($0.id) && !isActive($0) }
    }

    private var isMeasuring: Bool {
        chosen.contains { checks[$0.id] == nil }
    }

    private var largeFiles: [DiffFile] {
        chosen.flatMap { checks[$0.id]?.skippable ?? [] }
    }

    private var reposNeedingClone: [RepoID] {
        var seen = Set<RepoID>()
        return chosen.map(\.repo).filter { repo in
            guard seen.insert(repo).inserted else { return false }
            if case .needsSnapshot = model.reviewSource(for: repo) { return true }
            return false
        }
    }

    private func linesToReview(_ check: BatchReviewCheck) -> Int {
        skipLargeFiles ? check.lines - check.skippedLines : check.lines
    }

    /// 고른 PR 이 모두 같은 모델이면 그 이름, 다르면 PR 마다 고른 것으로 돈다고만 말한다.
    private var modelNote: String {
        let labels = Set(chosen.map { model.reviewModelLabel(model.reviewModelChoice(for: $0)) })
        if labels.count == 1, let label = labels.first { return "\(label) 로 리뷰" }
        return "모델은 PR 마다 고른 것"
    }

    /// AI 리뷰 탭·한 개일 때 창과 같은 표기(1,000 으로 나눈 몫).
    private func tokens(_ value: Int) -> String {
        value >= 1_000 ? "\(value / 1_000)k 토큰" : "\(value) 토큰"
    }

    /// PR 마다 따로 잰다 — 하나가 늦어도(diff 를 처음 받는 PR) 다른 줄은 먼저 채워진다. 창을 닫아도 받던 diff 는
    /// 마저 받아 두지만(다음에 그 PR 을 열 때 쓴다) 창에는 더 쓰지 않는다.
    private func measure() {
        for pr in request.prs where checks[pr.id] == nil {
            Task {
                let check = await model.batchCheck(for: pr)
                checks[pr.id] = check
            }
        }
    }

    private func cancel() {
        model.cancelPendingBatchReview()
        dismiss()
    }
}
