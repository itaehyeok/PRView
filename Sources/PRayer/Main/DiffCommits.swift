import SwiftUI
import AppKit
import PRayerCore

/// 변경 파일 탭의 "커밋별로 보기".
///
/// 시안 E-1(2026-10-22 사용자 선택): 커밋 탭을 따로 두지 않고(시험판 0.7.0 베타 1 의 네 번째 탭은 뺐다), 변경 파일 탭 맨 위
/// 한 줄 오른쪽에 버튼을 둔다. 누르면 그 줄 아래에 이 브랜치의 커밋 표(GitLane 같은 그래프)가 펼쳐지고 **브랜치의 첫
/// 커밋(분기점 바로 위)** 이 골라진다(사용자 결정). 고른 커밋은 표의 그 줄이 말한다 — 맨 위 줄에 같은 제목을 또 두지 않는다
/// (2026-10-26, 여러 커밋을 고른 범위의 요약만 남김). 표 맨 위 "PR 전체 변경" 을
/// 고르거나 버튼을 다시 누르면 지금까지의 변경 파일 화면이다. 다른 탭에서 코드 줄로 넘어오면 PR 전체로 돌아간다 —
/// 그 줄 번호는 PR 전체 diff 의 것이다.
///
/// 목록은 PR 의 커밋만이다(BranchCommits 주석). develop 을 받아온 머지는 한 줄과 오른쪽에서 들어오는 회색 선으로만
/// 보이고, 그 diff 는 GitHub 이 첫 부모 기준으로 줘서 develop 쪽 변경이라 누를 때만 받는다.
/// 커밋을 고르면 AI 리뷰 카드·코멘트는 그리지 않는다 — 리뷰는 head 기준 줄 번호라 커밋 diff 의 줄과 맞지 않는다.
struct CommitBrowse: Equatable {
    /// 표 맨 위 "PR 전체 변경" 행의 id.
    static let wholePR = "pr:whole"

    var isOn = false
    /// 고른 행 id. 비었으면 아직 안 고른 것이다 — 켠 뒤 그래프가 오면 첫 커밋을 고른다.
    var selection: Set<String> = []
    /// ⇧클릭·⇧화살표로 범위를 넓힐 때의 시작점.
    var anchor: String?
    var lastMoved: String?
    /// diff 를 보기로 한 base 머지. 큰 develop 머지는 파일이 수백 개라 누를 때만 받는다.
    var revealedMerges: Set<String> = []

    /// 아래에 PR 전체 diff(지금까지의 변경 파일 화면)를 그리는가.
    var showsWholePR: Bool { !isOn || selection.isEmpty || selection == [Self.wholePR] }

    /// 다른 탭에서 코드 줄로 넘어올 때 — 켜 둔 채 PR 전체를 고른다.
    mutating func showWholePR() {
        guard isOn else { return }
        selection = [Self.wholePR]
        anchor = Self.wholePR
    }
}

enum CommitBrowseMetrics {
    static let rowHeight: CGFloat = 24
    static let headerHeight: CGFloat = 24
    static let markerHeight: CGFloat = 20
    static let defaultTableFraction = 0.32
    static let minTableHeight: CGFloat = 96
    static let minBottomHeight: CGFloat = 240
}

// MARK: - 맨 위 한 줄

/// 변경 파일 탭 맨 위 한 줄 — 커밋별로 보기 버튼(켜면 나가기 ×)과, 켠 동안 GitHub 링크·여러 커밋 범위의 요약.
///
/// 한 커밋·분기점·"PR 전체 변경" 을 골랐을 때는 왼쪽을 비운다. 예전에는 고른 커밋의 해시·제목·작성자·시각·줄 수를
/// 여기에 또 적었는데 바로 아래 표의 고른 줄과 같은 말이었고, 긴 제목이 나가기 버튼까지 밀어 "…" 로 잘랐다
/// (2026-10-26 사용자 피드백). ↑↓ 버튼도 뺐다 — 표가 ↑↓ 를 받고, ⌥↑↓ 는 보이지 않게 남겨 둔다.
struct DiffTopBar: View {
    @Environment(AppModel.self) private var model
    let pr: PullRequestInfo
    @Binding var browse: CommitBrowse
    let graph: CommitGraph?
    let commits: BranchCommits?
    let reviewedOid: String?
    let onToggle: () -> Void
    let onMove: (Int) -> Void

    private var baseRefName: String { commits?.baseRefName ?? pr.baseRefName }

    var body: some View {
        HStack(spacing: 8) {
            // 커밋별로 보기를 끈 동안에는 PR 전체 요약(파일 수·줄 수)을 뺀다 — 탭 부제와 같은 숫자였다
            // (2026-10-23 사용자 결정). 커밋 수는 버튼 옆에 남긴다.
            if browse.isOn, !browse.showsWholePR, let graph {
                rangeSummary(in: graph)
            }
            Spacer(minLength: 8)
            if browse.isOn, let url = githubURL {
                Link(destination: url) { Image(systemName: "arrow.up.right.square") }
                    .help("GitHub 에서 이 커밋 보기")
            }
            toggle
                // 왼쪽 글이 길어도 나가기 버튼은 줄지 않는다.
                .fixedSize()
                .layoutPriority(2)
        }
        .font(.system(size: 12.5))
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background {
            if browse.isOn {
                // ⌥↑↓ 로 커밋을 옮긴다(표에 초점이 없어도). 버튼은 표의 고른 줄과 겹쳐 뺐다.
                Group {
                    Button("더 새 커밋") { onMove(-1) }
                        .keyboardShortcut(.upArrow, modifiers: .option)
                    Button("더 오래된 커밋") { onMove(1) }
                        .keyboardShortcut(.downArrow, modifiers: .option)
                }
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
            }
        }
    }

    private var toggle: some View {
        Button(action: onToggle) {
            HStack(spacing: 4) {
                Image(systemName: "arrow.triangle.branch")
                Text(browse.isOn ? "커밋별로 보는 중" : "커밋별로 보기")
                if !browse.isOn {
                    Text(commitCountText).foregroundStyle(.secondary)
                }
                if browse.isOn {
                    Image(systemName: "xmark")
                        .font(.system(size: 9, weight: .semibold))
                }
            }
        }
        .tint(browse.isOn ? .accentColor : nil)
        .buttonStyle(.bordered)
        .help(browse.isOn ? "커밋 표를 닫고 PR 전체 변경으로 돌아갑니다"
                          : "이 브랜치의 커밋을 표로 펼쳐 커밋마다 diff 를 봅니다(브랜치의 첫 커밋부터)")
    }

    /// 그래프를 받았으면 그 수(최대 250), 아니면 PR 단건 조회의 수(최근 30개까지).
    private var commitCountText: String {
        if let commits { return "커밋 \(commits.totalCount)개" }
        let count = pr.commits.count
        return count >= 30 ? "커밋 \(count)개+" : "커밋 \(count)개"
    }

    /// 여러 커밋을 고른 범위의 요약 — 표에는 커밋마다의 줄만 있어 합친 변경은 여기서만 보인다.
    @ViewBuilder
    private func rangeSummary(in graph: CommitGraph) -> some View {
        let picked = graph.rows.filter { browse.selection.contains($0.id) }
        if picked.count > 1, case .range(let base, let head) = graph.diffSpec(for: browse.selection) {
            let afterReview = Set(graph.commitsAfterReview(reviewedOid: reviewedOid).map(\.oid))
            let isAfterReview = !afterReview.isEmpty && afterReview == browse.selection
            Tag(text: isAfterReview ? "AI 리뷰 이후" : "커밋 \(picked.count)개",
                color: isAfterReview ? .orange : .accentColor)
            Text("\(base.prefix(7))..\(head.prefix(7)) 합친 변경")
                .fontWeight(.medium)
                .lineLimit(1)
            if let stats = diffStats(.range(base: base, head: head)) {
                Text(stats).foregroundStyle(.secondary).lineLimit(1)
            }
            // 범위 diff 는 compare 라, 사이에 base 를 받아온 머지가 있으면 받아온 변경까지 섞인다
            // (실측: 커밋 12개 PR 에서 첫 커밋부터 고르니 파일 3,130개).
            if picked.contains(where: \.mergesFromBase) {
                Label("\(baseRefName) 변경 섞임", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.orange)
                    .lineLimit(1)
                    .help("고른 범위에 \(baseRefName) 를 받아온 머지가 있어, 그때 들어온 \(baseRefName) 쪽 변경도 diff 에 섞입니다.")
            }
        }
    }

    /// 받은 diff 로 센 파일 수·줄 수(제외 파일 포함).
    private func diffStats(_ spec: CommitDiffSpec) -> String? {
        guard let diff = model.commitDiff(for: pr, spec: spec) else { return nil }
        let files = diff.files + diff.excludedFiles
        guard !files.isEmpty else { return nil }
        let added = files.reduce(0) { $0 + $1.additions }
        let removed = files.reduce(0) { $0 + $1.deletions }
        return "파일 \(files.count)개 · +\(added) −\(removed)"
    }

    private var githubURL: URL? {
        guard let graph, !browse.showsWholePR else { return nil }
        let picked = graph.rows.filter { browse.selection.contains($0.id) }
        guard picked.count == 1, let commit = picked[0].commit else { return nil }
        return URL(string: "https://\(model.settings.githubHost)/\(pr.repo.full)/pull/\(pr.number)/commits/\(commit.oid)")
    }
}

// MARK: - 커밋을 고른 뒤 아래쪽

/// 커밋(범위)을 고른 뒤의 아래쪽 — 안내(분기점·base 머지) 또는 그 diff 의 파일 목록 | diff.
/// 파일 목록·diff 보기는 PR 전체와 같은 것을 쓰고, AI 리뷰 카드·코멘트는 넘기지 않는다.
struct CommitDiffContent: View {
    @Environment(AppModel.self) private var model
    let pr: PullRequestInfo
    let graph: CommitGraph
    let commits: BranchCommits?
    @Binding var browse: CommitBrowse
    @Binding var selectedPath: String?
    @Binding var mode: DiffViewMode
    @Binding var showFileList: Bool
    let fileListWidth: (CGFloat) -> CGFloat
    let fileListDivider: (CGFloat, CGFloat) -> ResizeDivider

    @State private var scrollTargetKey: String?

    private var baseRefName: String { commits?.baseRefName ?? pr.baseRefName }

    var body: some View {
        let picked = graph.rows.filter { browse.selection.contains($0.id) }
        let hidden = commits.map { max(0, $0.totalCount - $0.commits.count) } ?? 0
        if picked.count == 1, case .base = picked[0].kind, hidden > 0 {
            note(symbol: "ellipsis.circle",
                 title: "이전 커밋 \(hidden)개",
                 text: "커밋이 250개를 넘는 PR 이라 GitHub 이 최신 250개만 줍니다. 그 앞의 커밋은 GitHub 에서 보세요.")
        } else if picked.count == 1, case .base(let oid) = picked[0].kind {
            note(symbol: "arrow.triangle.branch",
                 title: "\(baseRefName) 분기점",
                 text: "이 브랜치가 갈라져 나온 \(baseRefName) 커밋(\(oid.prefix(7)))입니다. 브랜치 커밋이 아니라 diff 가 없습니다.")
        } else if picked.count == 1, picked[0].mergesFromBase, let commit = picked[0].commit,
                  !browse.revealedMerges.contains(commit.oid) {
            // PR 안의 가지를 합친 머지는 그 가지의 변경이라 바로 보여 준다. base 를 받아온 머지만 묻는다.
            note(symbol: "arrow.triangle.merge",
                 title: "\(baseRefName) 을 받아온 머지",
                 text: """
                     GitHub 은 머지 커밋을 첫 부모 기준으로 보여 줍니다. 그래서 이 diff 는 이 브랜치에서 고친 것이 아니라 \
                     \(baseRefName) 에서 들어온 변경이 대부분이고, 충돌을 고친 줄이 섞여 있을 수 있습니다.
                     """,
                 action: ("diff 보기\(commit.changedFiles.map { " (파일 \($0)개)" } ?? "")", {
                     browse.revealedMerges.insert(commit.oid)
                 }))
        } else if let spec = graph.diffSpec(for: browse.selection) {
            diffArea(spec: spec)
                .task(id: spec) { await model.loadCommitDiff(for: pr, spec: spec) }
        } else {
            note(symbol: "questionmark.circle", title: "diff 를 만들 수 없습니다",
                 text: "고른 커밋 중 가장 오래된 것에 부모가 없어 범위를 정할 수 없습니다. 커밋을 하나씩 골라 보세요.")
        }
    }

    @ViewBuilder
    private func diffArea(spec: CommitDiffSpec) -> some View {
        let key = model.commitDiffKey(for: pr, spec: spec)
        if let diff = model.commitDiff(for: pr, spec: spec) {
            if diff.files.isEmpty && diff.excludedFiles.isEmpty {
                note(symbol: "doc", title: "바뀐 파일 없음", text: "이 범위에는 바뀐 파일이 없습니다.")
            } else {
                VStack(spacing: 0) {
                    if hasReviewCards {
                        Label("AI 코멘트 카드는 \"PR 전체 변경\" 에서만 보입니다 — 커밋 diff 와 줄 번호가 달라서",
                              systemImage: "info.circle")
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(.horizontal, 12)
                            .padding(.vertical, 4)
                        Divider()
                    }
                    filesAndDiff(diff)
                }
                .task(id: diff.files.map(\.path).joined() + diff.excludedFiles.map(\.path).joined()) {
                    // 커밋을 넘겨도 보던 파일이 그 커밋에 있으면 그대로 둔다 — 한 파일이 커밋마다 어떻게 바뀌었나 따라가기 좋다.
                    let known = diff.files.contains { $0.path == selectedPath }
                        || diff.excludedFiles.contains { $0.path == selectedPath }
                    if selectedPath == nil || !known {
                        selectedPath = diff.files.first?.path ?? diff.excludedFiles.first?.path
                    }
                }
            }
        } else if let error = model.commitDiffErrors[key] {
            note(symbol: "exclamationmark.triangle", title: "diff 를 불러오지 못했습니다", text: error,
                 action: ("다시 시도", {
                     model.commitDiffErrors[key] = nil
                     Task { await model.loadCommitDiff(for: pr, spec: spec) }
                 }))
        } else {
            ProgressView("diff 를 불러오는 중")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// 이 PR 에 AI 리뷰 카드가 있는가 — 있을 때만 "여기서는 안 보인다" 를 알린다.
    private var hasReviewCards: Bool {
        guard let record = model.record(for: pr) else { return false }
        return !record.issues.isEmpty || !record.comments.isEmpty
    }

    private func filesAndDiff(_ diff: ParsedDiff) -> some View {
        GeometryReader { geometry in
            let total = geometry.size.width
            HStack(spacing: 0) {
                if showFileList {
                    let width = fileListWidth(total)
                    DiffFileList(diff: diff, commentCounts: [:], selection: $selectedPath)
                        .frame(width: width)
                    fileListDivider(total, width)
                }
                Group {
                    if let file = diff.files.first(where: { $0.path == selectedPath })
                        ?? diff.excludedFiles.first(where: { $0.path == selectedPath })
                        ?? diff.files.first {
                        DiffFileView(file: file,
                                     mode: $mode,
                                     comments: [],
                                     threads: [],
                                     pr: pr,
                                     files: diff.files,
                                     selection: $selectedPath,
                                     showFileList: $showFileList,
                                     scrollTargetKey: $scrollTargetKey)
                    } else {
                        ContentUnavailableView("파일을 선택하세요", systemImage: "doc.text")
                    }
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
        }
    }

    private func note(symbol: String, title: String, text: String,
                      action: (String, () -> Void)? = nil) -> some View {
        ContentUnavailableView {
            Label(title, systemImage: symbol)
        } description: {
            Text(text)
        } actions: {
            if let action {
                Button(action.0, action: action.1)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }
}

// MARK: - 커밋 표

/// 맨 위 한 줄 아래에 펼쳐지는 커밋 표. 맨 위 행은 "PR 전체 변경"(끄면 보는 화면), 그 아래가 이 브랜치 커밋.
struct CommitTable: View {
    let pr: PullRequestInfo
    let graph: CommitGraph
    let commits: BranchCommits?
    let reviewedOid: String?
    let selection: Set<String>
    var focused: FocusState<Bool>.Binding
    let onSelect: (String, Bool) -> Void
    let onSelectAfterReview: () -> Void
    let onMove: (Int, Bool) -> Void

    private var graphWidth: CGFloat { CommitGraphCanvas.width(for: graph) }
    private var hiddenCount: Int { commits.map { max(0, $0.totalCount - $0.commits.count) } ?? 0 }

    /// 표가 다 보이는 높이 — 커밋이 적으면 이만큼만 쓴다(빈 줄로 아래 diff 를 깎지 않는다).
    static func contentHeight(graph: CommitGraph, reviewedOid: String?) -> CGFloat {
        let marker = graph.reviewedRowIndex(reviewedOid: reviewedOid) == nil ? 0 : CommitBrowseMetrics.markerHeight
        return CommitBrowseMetrics.headerHeight + CGFloat(graph.rows.count + 1) * CommitBrowseMetrics.rowHeight + marker + 2
    }

    var body: some View {
        let reviewedIndex = graph.reviewedRowIndex(reviewedOid: reviewedOid)
        VStack(spacing: 0) {
            header
            Divider()
            ScrollViewReader { proxy in
                ScrollView(.vertical) {
                    LazyVStack(spacing: 0) {
                        WholePRRow(pr: pr, graphWidth: graphWidth,
                                   isSelected: selection.contains(CommitBrowse.wholePR),
                                   isFocused: focused.wrappedValue)
                            .id(CommitBrowse.wholePR)
                            .onTapGesture { onSelect(CommitBrowse.wholePR, false) }
                        ForEach(Array(graph.rows.enumerated()), id: \.element.id) { index, row in
                            if index == reviewedIndex {
                                ReviewMarkerRow(graph: graph, index: index, graphWidth: graphWidth,
                                                afterCount: index, onSelect: onSelectAfterReview)
                            }
                            CommitRow(row: row,
                                      graph: graph,
                                      graphWidth: graphWidth,
                                      baseRefName: commits?.baseRefName ?? pr.baseRefName,
                                      hiddenCount: hiddenCount,
                                      isHead: index == 0,
                                      isReviewed: index == reviewedIndex,
                                      isSelected: selection.contains(row.id),
                                      isFocused: focused.wrappedValue)
                                .id(row.id)
                                .onTapGesture {
                                    onSelect(row.id, NSEvent.modifierFlags.contains(.shift))
                                }
                        }
                    }
                }
                .onChange(of: selection, initial: true) { _, newValue in
                    // 처음 펼칠 때(첫 커밋이 맨 아래에 있다)·키보드로 넘길 때 고른 줄이 화면 밖에 있지 않게.
                    let ids = [CommitBrowse.wholePR] + graph.rows.map(\.id)
                    if let top = ids.first(where: { newValue.contains($0) }) {
                        proxy.scrollTo(top)
                    }
                }
            }
        }
        .focusable()
        .focused(focused)
        .focusEffectDisabled()
        .onKeyPress(keys: [.upArrow, .downArrow]) { press in
            onMove(press.key == .upArrow ? -1 : 1, press.modifiers.contains(.shift))
            return .handled
        }
    }

    private var header: some View {
        HStack(spacing: CommitRow.columnSpacing) {
            Color.clear.frame(width: graphWidth)
            HStack(spacing: 5) {
                Image(systemName: "arrow.triangle.branch")
                    .foregroundStyle(Color.accentColor)
                Text(commits?.headRefName ?? pr.headRefName)
                    .fontWeight(.medium)
                    .foregroundStyle(.primary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                Text(hiddenCount > 0
                     ? "의 커밋 \(graph.commits.count + hiddenCount)개 중 최신 \(graph.commits.count)개 · ⇧클릭 범위"
                     : "의 커밋 \(graph.commits.count)개 · ⇧클릭 범위")
                    .lineLimit(1)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            Text("작성자").frame(width: CommitRow.authorWidth, alignment: .leading)
            Text("시각").frame(width: CommitRow.timeWidth, alignment: .leading)
            Text("증감").frame(width: CommitRow.statWidth, alignment: .trailing)
            Text("해시").frame(width: CommitRow.hashWidth, alignment: .leading)
        }
        .font(.system(size: 11))
        .foregroundStyle(.secondary)
        .padding(.trailing, 12)
        .frame(height: CommitBrowseMetrics.headerHeight)
    }
}

/// 표 맨 위 "PR 전체 변경" 행 — 고르면 지금까지의 변경 파일 화면(AI 카드 포함)이다.
private struct WholePRRow: View {
    let pr: PullRequestInfo
    let graphWidth: CGFloat
    let isSelected: Bool
    let isFocused: Bool

    var body: some View {
        HStack(spacing: CommitRow.columnSpacing) {
            Image(systemName: "rectangle.stack")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .frame(width: graphWidth)
            HStack(spacing: 6) {
                Text("PR 전체 변경")
                    .fontWeight(.medium)
                Text("· 끄면 보는 화면")
                    .foregroundStyle(.secondary)
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
            HStack(spacing: 4) {
                Text("+" + LineCount.compact(pr.additions)).foregroundStyle(Color.green)
                Text("−" + LineCount.compact(pr.deletions)).foregroundStyle(Color.red)
            }
            .font(.system(size: 11).monospacedDigit())
            .frame(width: CommitRow.statWidth, alignment: .trailing)
            .padding(.leading, CommitRow.authorWidth + CommitRow.timeWidth + CommitRow.columnSpacing * 2)
            Text("파일 \(pr.changedFiles)")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .frame(width: CommitRow.hashWidth, alignment: .leading)
        }
        .font(.system(size: 12.5))
        .padding(.trailing, 12)
        .frame(height: CommitBrowseMetrics.rowHeight)
        .background(isSelected ? Color.accentColor.opacity(isFocused ? 0.22 : 0.12) : Color.clear)
        .contentShape(Rectangle())
    }
}

private struct CommitRow: View {
    @Environment(AppModel.self) private var model
    let row: CommitGraph.Row
    let graph: CommitGraph
    let graphWidth: CGFloat
    let baseRefName: String
    /// 받지 못한 오래된 커밋 수 — 있으면 맨 아래 줄이 분기점이 아니라 "이전 커밋 N개" 다.
    let hiddenCount: Int
    let isHead: Bool
    let isReviewed: Bool
    let isSelected: Bool
    let isFocused: Bool

    static let columnSpacing: CGFloat = 10
    static let authorWidth: CGFloat = 90
    static let timeWidth: CGFloat = 52
    static let statWidth: CGFloat = 82
    static let hashWidth: CGFloat = 60

    var body: some View {
        HStack(spacing: Self.columnSpacing) {
            CommitGraphCanvas(row: row, graph: graph)
                .frame(width: graphWidth, height: CommitBrowseMetrics.rowHeight)
            switch row.kind {
            case .commit(let commit):
                commitColumns(commit)
            case .base(let oid):
                HStack(spacing: 6) {
                    if hiddenCount > 0 {
                        Text("이전 커밋 \(hiddenCount)개 — 최신 250개만 받았습니다")
                            .foregroundStyle(.secondary)
                    } else {
                        Tag(text: baseRefName, color: .secondary)
                        Text("분기점")
                            .foregroundStyle(.secondary)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                Spacer().frame(width: Self.authorWidth + Self.timeWidth + Self.statWidth + Self.columnSpacing * 2)
                Text(String(oid.prefix(7)))
                    .font(.caption.monospaced())
                    .foregroundStyle(.tertiary)
                    .frame(width: Self.hashWidth, alignment: .leading)
            }
        }
        .font(.system(size: 12.5))
        .padding(.trailing, 12)
        .frame(height: CommitBrowseMetrics.rowHeight)
        .background(isSelected ? Color.accentColor.opacity(isFocused ? 0.22 : 0.12) : Color.clear)
        .contentShape(Rectangle())
    }

    @ViewBuilder
    private func commitColumns(_ commit: BranchCommit) -> some View {
        HStack(spacing: 6) {
            if isHead { Tag(text: "head", color: .accentColor) }
            if commit.isMerge { Tag(text: "머지", color: .secondary) }
            Text(commit.headline)
                .foregroundStyle(commit.isMerge ? .secondary : .primary)
                .lineLimit(1)
                .truncationMode(.tail)
            if isReviewed {
                Image(systemName: "sparkles")
                    .font(.system(size: 10))
                    .foregroundStyle(.orange)
                    .help("AI 리뷰한 커밋")
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        Text(author(commit))
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .frame(width: Self.authorWidth, alignment: .leading)
        RelativeTimeText(date: commit.date)
            .foregroundStyle(.secondary)
            .frame(width: Self.timeWidth, alignment: .leading)
        HStack(spacing: 4) {
            Text("+" + LineCount.compact(commit.additions)).foregroundStyle(Color.green)
            Text("−" + LineCount.compact(commit.deletions)).foregroundStyle(Color.red)
        }
        .font(.system(size: 11).monospacedDigit())
        .frame(width: Self.statWidth, alignment: .trailing)
        Text(commit.abbreviatedOid)
            .font(.caption.monospaced())
            .foregroundStyle(.secondary)
            .frame(width: Self.hashWidth, alignment: .leading)
    }

    private func author(_ commit: BranchCommit) -> String {
        if let login = commit.authorLogin { return model.settings.displayName(login) }
        return commit.authorName
    }
}

/// 리뷰한 커밋 바로 위에 끼우는 줄 — 그 위가 리뷰 뒤에 올라온 커밋이다. 누르면 그 커밋들을 한꺼번에 고른다.
private struct ReviewMarkerRow: View {
    let graph: CommitGraph
    let index: Int
    let graphWidth: CGFloat
    let afterCount: Int
    let onSelect: () -> Void

    var body: some View {
        HStack(spacing: CommitRow.columnSpacing) {
            CommitGraphCanvas.passThrough(above: index > 0 ? graph.rows[index - 1] : nil)
                .frame(width: graphWidth, height: CommitBrowseMetrics.markerHeight)
            HStack(spacing: 6) {
                dashes.frame(width: 14)
                Label(afterCount > 0 ? "AI 리뷰한 지점 · 이후 커밋 \(afterCount)개 고르기" : "AI 리뷰한 지점 · 이후 새 커밋 없음",
                      systemImage: "sparkles")
                    .font(.system(size: 11))
                    .foregroundStyle(.orange)
                    .fixedSize()
                dashes
            }
        }
        .padding(.trailing, 12)
        .frame(height: CommitBrowseMetrics.markerHeight)
        .contentShape(Rectangle())
        .onTapGesture { if afterCount > 0 { onSelect() } }
        .help(afterCount > 0 ? "리뷰 뒤에 올라온 커밋만 합쳐서 봅니다" : "리뷰한 커밋이 지금 head 입니다")
    }

    private var dashes: some View {
        Line()
            .stroke(Color.orange.opacity(0.6), style: StrokeStyle(lineWidth: 1, dash: [3, 3]))
            .frame(height: 1)
    }

    private struct Line: Shape {
        func path(in rect: CGRect) -> Path {
            var path = Path()
            path.move(to: CGPoint(x: rect.minX, y: rect.midY))
            path.addLine(to: CGPoint(x: rect.maxX, y: rect.midY))
            return path
        }
    }
}

// MARK: - 그래프 그리기

/// 한 행의 그래프. 선 모양은 GitLane `GraphGeometry` 와 같다 — 같은 열이면 직선, 다르면 가장자리에서 조금 떨어진
/// 제어점을 둔 베지어.
private struct CommitGraphCanvas: View {
    let row: CommitGraph.Row
    let graph: CommitGraph

    static let columnWidth: CGFloat = 12
    static let leftMargin: CGFloat = 10
    static let edgeInset: CGFloat = 5
    /// develop 을 받아온 머지의 짧은 선이 들어올 자리.
    static let stubWidth: CGFloat = 12
    static let colors: [Color] = [.blue, .orange, .green, .purple, .pink, .teal, .yellow, .indigo, .brown, .mint]

    static func color(_ lane: Int) -> Color { colors[lane % colors.count] }
    static func x(_ column: Int) -> CGFloat { leftMargin + CGFloat(column) * columnWidth }

    static func width(for graph: CommitGraph) -> CGFloat {
        let stub = graph.rows.contains(where: \.mergesFromBase) ? stubWidth : 0
        return x(graph.columnCount - 1) + leftMargin + stub
    }

    /// 리뷰 표시 줄처럼 점 없이 지나가는 선만 그리는 행.
    static func passThrough(above: CommitGraph.Row?) -> some View {
        Canvas { context, size in
            guard let above else { return }
            for line in above.lines {
                guard let bottom = line.bottom else { continue }
                var path = Path()
                path.move(to: CGPoint(x: x(bottom), y: 0))
                path.addLine(to: CGPoint(x: x(bottom), y: size.height))
                context.stroke(path, with: .color(color(line.lane)), lineWidth: 1.6)
            }
        }
    }

    var body: some View {
        Canvas { context, size in
            let height = size.height
            let middle = height / 2
            for line in row.lines {
                guard let path = path(for: line, height: height, middle: middle) else { continue }
                context.stroke(path, with: .color(Self.color(line.lane)), lineWidth: 1.6)
            }
            let cx = Self.x(row.column)
            if row.mergesFromBase {
                // 오른쪽 위에서 점으로 들어오는 짧은 회색 선 — 받아온 쪽 커밋은 목록에 없다.
                var stub = Path()
                stub.move(to: CGPoint(x: cx + Self.stubWidth + 4, y: 0))
                stub.addCurve(to: CGPoint(x: cx + 4, y: middle),
                              control1: CGPoint(x: cx + Self.stubWidth + 4, y: middle - 2),
                              control2: CGPoint(x: cx + 9, y: middle))
                context.stroke(stub, with: .color(.gray.opacity(0.8)), lineWidth: 1.6)
            }
            switch row.kind {
            case .base:
                let ring = CGRect(x: cx - 4, y: middle - 4, width: 8, height: 8)
                context.fill(Path(ellipseIn: ring), with: .color(Color(nsColor: .textBackgroundColor)))
                context.stroke(Path(ellipseIn: ring), with: .color(.gray), lineWidth: 1.6)
            case .commit(let commit):
                let color = Self.color(row.lane)
                if commit.isMerge {
                    let ring = CGRect(x: cx - 5, y: middle - 5, width: 10, height: 10)
                    context.fill(Path(ellipseIn: ring), with: .color(Color(nsColor: .textBackgroundColor)))
                    context.stroke(Path(ellipseIn: ring), with: .color(color), lineWidth: 1.6)
                    context.fill(Path(ellipseIn: CGRect(x: cx - 2, y: middle - 2, width: 4, height: 4)), with: .color(color))
                } else {
                    context.fill(Path(ellipseIn: CGRect(x: cx - 3.5, y: middle - 3.5, width: 7, height: 7)), with: .color(color))
                }
            }
        }
    }

    private func path(for line: CommitGraph.Line, height: CGFloat, middle: CGFloat) -> Path? {
        let inset = Self.edgeInset
        var path = Path()
        if let top = line.top {
            let xt = Self.x(top)
            path.move(to: CGPoint(x: xt, y: 0))
            if let bottom = line.bottom {
                let xb = Self.x(bottom)
                if top == bottom {
                    path.addLine(to: CGPoint(x: xb, y: height))
                } else {
                    path.addCurve(to: CGPoint(x: xb, y: height),
                                  control1: CGPoint(x: xt, y: height - inset),
                                  control2: CGPoint(x: xb, y: inset))
                }
            } else {
                let xm = Self.x(line.middle)
                if top == line.middle {
                    path.addLine(to: CGPoint(x: xm, y: middle))
                } else {
                    path.addCurve(to: CGPoint(x: xm, y: middle),
                                  control1: CGPoint(x: xt, y: middle),
                                  control2: CGPoint(x: xm + inset, y: middle))
                }
            }
        } else {
            guard let bottom = line.bottom else { return nil }
            let xm = Self.x(line.middle)
            let xb = Self.x(bottom)
            path.move(to: CGPoint(x: xm, y: middle))
            if line.middle == bottom {
                path.addLine(to: CGPoint(x: xb, y: height))
            } else {
                path.addCurve(to: CGPoint(x: xb, y: height),
                              control1: CGPoint(x: xb, y: middle),
                              control2: CGPoint(x: xb, y: middle + inset))
            }
        }
        return path
    }
}
