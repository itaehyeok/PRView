import SwiftUI
import AppKit
import PRayerCore

enum DiffViewMode: String, CaseIterable, Identifiable {
    /// 왼쪽 옛 코드 / 오른쪽 새 코드
    case split
    /// 한 줄에 +/- 를 모두 표시
    case unified

    var id: String { rawValue }
    var label: String { self == .split ? "나란히" : "한 줄로" }
    var symbol: String { self == .split ? "rectangle.split.2x1" : "list.bullet" }
}

enum DiffKeys {
    static func key(path: String, side: DiffSide, line: Int) -> String {
        "\(path)#\(side.rawValue)#\(line)"
    }
}

struct DiffTab: View {
    @Environment(AppModel.self) private var model
    let pr: PullRequestInfo
    /// "커밋별로 보기"(DiffCommits). 상세 화면이 들고 있어 탭을 오가도 남는다.
    @Binding var commitBrowse: CommitBrowse
    @Binding var scrollTargetKey: String?
    /// AI 리뷰의 우려사항·질문을 따라가는 중이면 그 항목(ReviewFollow 주석 참고).
    @Binding var follow: ReviewFollow?
    /// ‹ › 로 넘겨 본 항목. AI 리뷰 탭에 "diff 에서 봄" 으로 남는다.
    var onSeen: (String) -> Void = { _ in }

    @State private var selectedPath: String?
    @State private var mode: DiffViewMode = .split
    /// 나란히 보기에서는 열이 3개가 되어 좁다. 파일 목록을 접을 수 있게 한다.
    @AppStorage("diffShowsFileList") private var showFileList = true
    /// 파일 목록이 차지하는 몫(diff 탭 폭 대비). 폭이 아니라 몫을 적어서 창 크기를 바꿔도 같은 비율로 보인다.
    ///
    /// 예전에는 `HSplitView` 였는데, PR 을 바꿀 때마다 끌어 둔 자리를 잃고 최대 폭(340pt)으로 돌아갔다 —
    /// 평소 창에서는 diff 탭의 3분의 1을 파일 목록이 먹었다. 기본 25% 는 사용자가 "이 정도" 로 보여 준
    /// 화면(넓은 창에서 340pt ≈ 24%)에서 왔다.
    @AppStorage("diffFileListFraction") private var fileListFraction = DiffTab.defaultFileListFraction
    /// 드래그를 시작한 순간의 폭. 매 프레임 누적으로 계산하면 값이 튄다.
    @State private var dragStartWidth: CGFloat?
    /// 커밋 표가 차지하는 몫(탭 높이 대비).
    @AppStorage("commitsTableFraction") private var tableFraction = CommitBrowseMetrics.defaultTableFraction
    @State private var dragStartHeight: CGFloat?
    @FocusState private var commitTableFocused: Bool

    static let defaultFileListFraction = 0.25
    /// 작은 창에서 비율만 따르면 파일 이름이 한두 글자만 남는다(실측: 상세 760pt 창에서 190pt).
    private static let minFileListWidth: CGFloat = 200
    private static let maxFileListWidth: CGFloat = 340
    /// 나란히 보기 두 열이 읽힐 만큼은 남긴다.
    private static let minContentWidth: CGFloat = 420

    /// 이 폭의 diff 탭에서 파일 목록이 가질 수 있는 범위.
    private func fileListRange(in total: CGFloat) -> ClosedRange<CGFloat> {
        let upper = min(Self.maxFileListWidth, total - Self.minContentWidth)
        return Self.minFileListWidth...max(Self.minFileListWidth, upper)
    }

    private func fileListWidth(in total: CGFloat) -> CGFloat {
        let range = fileListRange(in: total)
        return min(max(range.lowerBound, total * fileListFraction), range.upperBound)
    }

    var body: some View {
        let state = commitBrowse.isOn ? model.branchGraphState(for: pr) : nil
        let graph = state?.graph
        let reviewedOid = graph.flatMap(reviewedOid(in:))
        GeometryReader { geometry in
            VStack(spacing: 0) {
                // 맨 위 한 줄 — PR 전체 요약(또는 고른 커밋)과 "커밋별로 보기"(시안 E-1).
                DiffTopBar(pr: pr,
                           browse: $commitBrowse,
                           graph: graph,
                           commits: state?.commits,
                           reviewedOid: reviewedOid,
                           onToggle: toggleCommitBrowse,
                           onMove: { step in graph.map { moveCommit(step, extend: false, in: $0) } })
                Divider()
                if commitBrowse.isOn {
                    commitTableSection(state: state, reviewedOid: reviewedOid, total: geometry.size.height)
                }
                if commitBrowse.showsWholePR || graph == nil {
                    wholePRContent
                } else if let graph {
                    CommitDiffContent(pr: pr,
                                      graph: graph,
                                      commits: state?.commits,
                                      browse: $commitBrowse,
                                      selectedPath: $selectedPath,
                                      mode: $mode,
                                      showFileList: $showFileList,
                                      fileListWidth: { fileListWidth(in: $0) },
                                      fileListDivider: { fileListDivider(total: $0, width: $1) })
                }
            }
        }
        // 켜면 그래프를 받고, 받은 뒤 아직 안 골랐으면 이 브랜치의 첫 커밋(분기점 바로 위)을 고른다(사용자 결정).
        .task(id: commitBrowse.isOn ? "\(model.diffKey(for: pr))#\(graph?.rows.count ?? -1)" : "off") {
            guard commitBrowse.isOn else { return }
            await model.loadBranchGraph(for: pr)
            guard let graph = model.branchGraphState(for: pr)?.graph else { return }
            pickDefaultCommit(in: graph)
        }
    }

    // MARK: - 커밋별로 보기

    private func toggleCommitBrowse() {
        if commitBrowse.isOn {
            // 끄면 PR 전체로. 보던 파일이 PR 전체에도 있으면 그 파일을 그대로 연다(선택 경로는 건드리지 않는다).
            commitBrowse = CommitBrowse()
        } else {
            commitBrowse.isOn = true
            commitTableFocused = true
        }
    }

    /// 아직 안 골랐거나 고른 것이 사라졌으면(새 커밋으로 그래프가 바뀜) 브랜치의 첫 커밋을 고른다.
    private func pickDefaultCommit(in graph: CommitGraph) {
        let known = Set(graph.rows.map(\.id)).union([CommitBrowse.wholePR])
        if let rows = DebugLaunch.commitsSelect, commitBrowse.selection.isEmpty {
            let ids = graph.rows.map(\.id).enumerated().filter { rows.contains($0.offset) }.map(\.element)
            if let first = ids.first {
                commitBrowse.selection = Set(ids)
                commitBrowse.anchor = first
                return
            }
        }
        guard commitBrowse.selection.isEmpty || !commitBrowse.selection.isSubset(of: known) else { return }
        let first = graph.commits.last?.oid ?? CommitBrowse.wholePR
        commitBrowse.selection = [first]
        commitBrowse.anchor = first
    }

    /// 리뷰한 커밋. 여러 번 리뷰했으면 마지막 리뷰의 head 다.
    private func reviewedOid(in graph: CommitGraph) -> String? {
        if let row = DebugLaunch.commitsReviewedRow, graph.rows.indices.contains(row) {
            return graph.rows[row].commit?.oid
        }
        return model.record(for: pr)?.headSha
    }

    /// 맨 위 한 줄 아래 커밋 표 + 높이를 바꾸는 가로 선. 받는 중·실패면 그 한 줄만.
    @ViewBuilder
    private func commitTableSection(state: BranchGraphState?, reviewedOid: String?, total: CGFloat) -> some View {
        if let graph = state?.graph {
            let content = CommitTable.contentHeight(graph: graph, reviewedOid: reviewedOid)
            let upper = max(CommitBrowseMetrics.minTableHeight, total - CommitBrowseMetrics.minBottomHeight)
            let height = min(min(max(CommitBrowseMetrics.minTableHeight, total * tableFraction), upper), content)
            CommitTable(pr: pr,
                        graph: graph,
                        commits: state?.commits,
                        reviewedOid: reviewedOid,
                        selection: commitBrowse.selection,
                        focused: $commitTableFocused,
                        onSelect: { id, extend in selectCommit(id, extend: extend, in: graph) },
                        onSelectAfterReview: { selectAfterReview(in: graph, reviewedOid: reviewedOid) },
                        onMove: { step, extend in moveCommit(step, extend: extend, in: graph) })
                .frame(height: height)
            ResizeDivider(help: "드래그로 커밋 표 높이 조절 · 더블클릭하면 기본 높이",
                          horizontal: true,
                          onDrag: { translation in
                              let base = dragStartHeight ?? height
                              if dragStartHeight == nil { dragStartHeight = base }
                              let clamped = min(max(CommitBrowseMetrics.minTableHeight, base + translation), upper)
                              tableFraction = Double(clamped / max(total, 1))
                          },
                          onDragEnd: { dragStartHeight = nil },
                          onReset: { tableFraction = CommitBrowseMetrics.defaultTableFraction })
        } else if let error = state?.error {
            HStack(spacing: 8) {
                Label("커밋을 불러오지 못했습니다: \(error)", systemImage: "exclamationmark.triangle")
                    .foregroundStyle(.secondary)
                    .lineLimit(2)
                Spacer()
                Button("다시 시도") { Task { await model.loadBranchGraph(for: pr, force: true) } }
            }
            .font(.callout)
            .padding(.horizontal, 12)
            .padding(.vertical, 10)
            Divider()
        } else {
            HStack(spacing: 8) {
                ProgressView().controlSize(.small)
                Text("커밋을 불러오는 중").foregroundStyle(.secondary)
            }
            .font(.callout)
            .frame(maxWidth: .infinity)
            .padding(.vertical, 12)
            Divider()
        }
    }

    private func selectCommit(_ id: String, extend: Bool, in graph: CommitGraph) {
        commitTableFocused = true
        if extend, let anchor = commitBrowse.anchor, graph.rows.first(where: { $0.id == id })?.commit != nil {
            let range = graph.oids(between: anchor, and: id)
            if !range.isEmpty {
                commitBrowse.selection = Set(range)
                return
            }
        }
        commitBrowse.selection = [id]
        commitBrowse.anchor = id
    }

    /// ↑↓(표에 초점이 있을 때)·⌥↑⌥↓ — 한 줄씩. ⇧ 를 같이 누르면 시작점부터 범위를 넓힌다.
    /// 맨 위 "PR 전체 변경" 행도 한 줄로 친다.
    private func moveCommit(_ step: Int, extend: Bool, in graph: CommitGraph) {
        let ids = [CommitBrowse.wholePR] + graph.rows.map(\.id)
        let selection = commitBrowse.selection
        // 범위를 고른 채로 움직이면, 위로는 가장 위 줄에서, 아래로는 가장 아래 줄에서 출발한다.
        let indices = ids.indices.filter { selection.contains(ids[$0]) }
        let current = extend
            ? (ids.firstIndex { $0 == commitBrowse.lastMoved } ?? indices.first ?? 0)
            : (step < 0 ? indices.first : indices.last) ?? 0
        let next = min(max(0, current + step), ids.count - 1)
        if extend, let anchor = commitBrowse.anchor, next > 0, graph.rows[next - 1].commit != nil {
            let range = graph.oids(between: anchor, and: ids[next])
            if !range.isEmpty {
                commitBrowse.selection = Set(range)
                commitBrowse.lastMoved = ids[next]
                return
            }
        }
        commitBrowse.selection = [ids[next]]
        commitBrowse.anchor = ids[next]
        commitBrowse.lastMoved = ids[next]
    }

    private func selectAfterReview(in graph: CommitGraph, reviewedOid: String?) {
        let after = graph.commitsAfterReview(reviewedOid: reviewedOid).map(\.oid)
        guard let newest = after.first else { return }
        commitBrowse.selection = Set(after)
        commitBrowse.anchor = newest
        commitTableFocused = true
    }

    private func fileListDivider(total: CGFloat, width: CGFloat) -> ResizeDivider {
        ResizeDivider(help: "드래그로 파일 목록 폭 조절 · 더블클릭하면 기본 폭",
                      onDrag: { translation in
                          let base = dragStartWidth ?? width
                          if dragStartWidth == nil { dragStartWidth = base }
                          let range = fileListRange(in: total)
                          let clamped = min(max(range.lowerBound, base + translation), range.upperBound)
                          fileListFraction = Double(clamped / max(total, 1))
                      },
                      onDragEnd: { dragStartWidth = nil },
                      onReset: { fileListFraction = Self.defaultFileListFraction })
    }

    // MARK: - PR 전체(지금까지의 변경 파일 화면)

    private var wholePRContent: some View {
        Group {
            if let diff = model.parsedDiff(for: pr) {
                let target = followTarget(in: diff)
                VStack(spacing: 0) {
                    // AI 리뷰로 돌아가기는 상세 탭 줄의 돌아가기 버튼(DetailTabRow)이 한다 — 카드마다 있던 "리뷰에서 보기" 를 대신한다.
                    // 따라가기(follow)는 그대로 둔다: 코드에서 보기로 오면 그 줄로 스크롤하고 칠한다.
                    GeometryReader { geometry in
                        let total = geometry.size.width
                        HStack(spacing: 0) {
                            if showFileList {
                                let width = fileListWidth(in: total)
                                DiffFileList(diff: diff,
                                             commentCounts: commentCounts,
                                             commentImportances: commentImportances,
                                             selection: $selectedPath)
                                    .frame(width: width)
                                ResizeDivider(help: "드래그로 파일 목록 폭 조절 · 더블클릭하면 기본 폭",
                                              onDrag: { translation in
                                                  let base = dragStartWidth ?? width
                                                  if dragStartWidth == nil { dragStartWidth = base }
                                                  // 범위 밖으로 끌어도 끝에 붙여 저장한다. 밖의 값을 저장하면
                                                  // 되돌려 끌 때 한동안 안 움직이는 것처럼 보인다.
                                                  let range = fileListRange(in: total)
                                                  let clamped = min(max(range.lowerBound, base + translation), range.upperBound)
                                                  fileListFraction = Double(clamped / max(total, 1))
                                              },
                                              onDragEnd: { dragStartWidth = nil },
                                              onReset: { fileListFraction = Self.defaultFileListFraction })
                            }
                            Group {
                                if let file = file(in: diff) {
                                    DiffFileView(file: file,
                                                 mode: $mode,
                                                 comments: comments(for: file.path),
                                                 threads: threads(for: file.path),
                                                 pr: pr,
                                                 files: diff.files,
                                                 selection: $selectedPath,
                                                 showFileList: $showFileList,
                                                 scrollTargetKey: $scrollTargetKey,
                                                 follow: target?.location.path == file.path ? target : nil,
                                                 issueAnchors: issueAnchors(in: diff, path: file.path))
                                } else {
                                    ContentUnavailableView("파일을 선택하세요", systemImage: "doc.text")
                                }
                            }
                            .frame(maxWidth: .infinity, maxHeight: .infinity)
                        }
                    }
                }
                // 따라갈 항목이 바뀌면(리뷰 탭에서 왔거나 ‹ › 를 눌렀거나) 그 파일·그 줄로 간다.
                // 경로는 diff 의 경로로 바꿔 둔 것을 쓴다 — 모델이 앞 디렉터리를 빼먹은 경로로는 파일을 못 고른다.
                .task(id: follow) {
                    if let key = followTarget(in: diff)?.location.diffKey { scrollTargetKey = key }
                }
                .task(id: diff.files.map(\.path).joined()) {
                    // 제외 목록에 있는 선택도 살아 있는 것으로 본다. 빼면 고르자마자 첫 파일로 튄다.
                    let known = diff.files.contains { $0.path == selectedPath }
                        || diff.excludedFiles.contains { $0.path == selectedPath }
                    if selectedPath == nil || !known {
                        selectedPath = DebugLaunch.diffFile.flatMap { end in diff.files.first { $0.path.hasSuffix(end) }?.path }
                            ?? diff.files.first?.path ?? diff.excludedFiles.first?.path
                    }
                }
                // 다른 탭에서 줄을 정해 두고 넘어오면 이 탭이 그 값을 들고 처음 그려진다. 그때도 파일을 맞춰야
                // 하므로 처음 값에도 반응한다(아니면 첫 파일이 열린 채 다른 파일의 줄을 찾는다).
                .onChange(of: scrollTargetKey, initial: true) { _, newValue in
                    // 다른 파일의 줄로 이동하는 경우 파일부터 바꾼다.
                    guard let newValue, let path = newValue.split(separator: "#").first else { return }
                    if selectedPath != String(path) { selectedPath = String(path) }
                }
            } else if model.loadingDiffKeys.contains(model.diffKey(for: pr)) {
                ProgressView("diff 를 불러오는 중")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                ContentUnavailableView {
                    Text("diff 를 불러오지 않았습니다")
                } actions: {
                    Button("불러오기") { Task { await model.loadDiff(for: pr) } }
                }
            }
        }
    }

    /// 제외된 파일도 고를 수 있다. 제외는 "모델에게 안 보낸다" 는 뜻이지
    /// "사람도 못 본다" 는 뜻이 아니다 — 자동 생성 파일이라도 눈으로 확인할 때가 있다.
    private func file(in diff: ParsedDiff) -> DiffFile? {
        guard let selectedPath else { return diff.files.first }
        return diff.files.first { $0.path == selectedPath }
            ?? diff.excludedFiles.first { $0.path == selectedPath }
            ?? diff.files.first
    }

    private var allComments: [DraftCommentState] {
        model.record(for: pr)?.comments ?? []
    }

    // MARK: - 리뷰 항목 따라가기

    private var followItems: [FollowableItem] {
        guard let record = model.record(for: pr) else { return [] }
        return ReviewFollowList.items(in: record.output)
    }

    /// 지금 따라가는 항목을 그릴 재료. 기록이 바뀌어 항목이 사라졌으면 nil(따라가기 줄도 내린다).
    private func followTarget(in diff: ParsedDiff) -> FollowTarget? {
        guard let follow, let record = model.record(for: pr) else { return nil }
        let items = followItems
        guard let index = items.firstIndex(where: { $0.key == follow.itemKey }) else { return nil }
        var item = items[index]
        // diff 의 경로로 바꿔 둔다. 파일 고르기·줄 찾기가 모두 diff 의 경로를 쓴다.
        item.locations = item.locations.map { location in
            var resolved = location
            if let file = diff.file(matching: location.path) { resolved.path = file.path }
            return resolved
        }
        let locationIndex = min(max(0, follow.locationIndex), item.locations.count - 1)
        let location = item.locations[locationIndex]
        let moved = record.movedDraft(for: item.key)
        let topic = item.title.count <= 50 ? item.title : String(item.title.prefix(50)) + "…"
        return FollowTarget(
            item: item,
            locationIndex: locationIndex,
            position: index + 1,
            total: items.count,
            moved: moved,
            isCleared: record.isCleared(item.key),
            canAttach: ReviewRecord.canAttachInline(at: location, diff: diff),
            hasOtherDraftHere: record.comments.contains { state in
                state.id != moved?.id && state.comment.path == location.path
                    && state.comment.side == location.side && state.comment.line == location.line
            },
            isPosted: record.isPosted,
            onMove: { changeRecord { _ = $0.moveToInline(item, locationIndex: locationIndex, diff: diff) } },
            onUndoMove: { changeRecord { $0.undoMoveToInline(item.key) } },
            onClear: { changeRecord { $0.setCleared(PostBuilder.defaultClearedNote(topic: topic), for: item.key) } },
            onUnclear: { changeRecord { $0.setCleared(nil, for: item.key) } },
            onEditMoved: { text in
                changeRecord { record in
                    guard let draft = moved,
                          let draftIndex = record.comments.firstIndex(where: { $0.id == draft.id }) else { return }
                    record.comments[draftIndex].editedBody = text
                }
            },
            onPickLocation: { picked in
                self.follow = ReviewFollow(itemKey: item.key, locationIndex: picked)
            },
            onNext: { step(1, in: diff) })
    }

    /// ‹ › — 본문 순서대로 다음·이전 항목으로. 끝에서는 처음으로 돌아간다.
    private func step(_ delta: Int, in diff: ParsedDiff) {
        let items = followItems
        guard !items.isEmpty else { return }
        let current = items.firstIndex { $0.key == follow?.itemKey } ?? 0
        let next = (current + delta + items.count) % items.count
        follow = ReviewFollow(itemKey: items[next].key, locationIndex: 0)
        onSeen(items[next].key)
    }

    /// 이 파일에 달 코드 코멘트 카드와 그 자리. 초안이 있으면 초안 자리, 없으면 지적이 가리키는 diff 안 첫 자리.
    /// 자리가 바뀐 줄 밖이면 line 이 nil 이라 파일 맨 위에 모은다.
    private func issueAnchors(in diff: ParsedDiff, path: String) -> [IssueAnchor] {
        guard let record = model.record(for: pr) else { return [] }
        return record.issues.compactMap { issue in
            if let index = record.draftIndex(for: issue) {
                let state = record.comments[index]
                guard diff.file(matching: state.comment.path)?.path == path else { return nil }
                return IssueAnchor(issue: issue,
                                   line: state.anchorStatus == .unresolved ? nil : state.comment.line,
                                   side: state.comment.side)
            }
            guard let spot = record.inlineSpot(for: issue.key, diff: diff) else { return nil }
            let location = spot.item.locations[spot.locationIndex ?? 0]
            guard diff.file(matching: location.path)?.path == path else { return nil }
            return IssueAnchor(issue: issue, line: spot.locationIndex == nil ? nil : location.line, side: location.side)
        }
    }

    private func changeRecord(_ change: (inout ReviewRecord) -> Void) {
        guard var record = model.record(for: pr) else { return }
        change(&record)
        model.update(record: record)
    }

    private func comments(for path: String) -> [DraftCommentState] {
        allComments.filter { $0.comment.path == path }
    }

    /// 사람이 이미 달아 둔 코드 코멘트. AI 초안과 같은 자리에, 색만 다르게 보여준다.
    private func threads(for path: String) -> [PRReviewThread] {
        pr.threads.filter { $0.path == path && $0.line != nil }
    }

    /// 파일 트리 뱃지: AI 초안 + 사람 코멘트를 합쳐 "이 파일에 할 얘기가 있다" 를 표시한다.
    private var commentCounts: [String: Int] {
        var counts = Dictionary(grouping: allComments, by: { $0.comment.path }).mapValues(\.count)
        for thread in pr.threads {
            guard let path = thread.path, !thread.isResolved else { continue }
            counts[path, default: 0] += 1
        }
        return counts
    }

    /// 파일 트리 뱃지 색: 그 파일에 달 AI 코드 코멘트 중 가장 높은 중요도(필수 > 권장 > 참고). 늘 주황이던 뱃지로는
    /// 머지를 막는 코멘트가 어느 파일에 있는지 알 수 없었다. 사람 코멘트만 있는 파일은 없다(nil — 회색).
    /// 경로 키는 `commentCounts` 와 같게 초안의 경로를 쓴다.
    private var commentImportances: [String: ReviewImportance] {
        guard let record = model.record(for: pr) else { return [:] }
        var result: [String: ReviewImportance] = [:]
        for issue in record.issues {
            let path = record.draftIndex(for: issue).map { record.comments[$0].comment.path } ?? issue.path
            guard let path else { continue }
            result[path] = min(result[path] ?? issue.importance, issue.importance)
        }
        return result
    }
}

/// 변경된 파일을 폴더 계층으로 보여준다. Fork 의 변경 파일 트리 수치를 그대로 따른다
/// (행 높이·들여쓰기 16·아이콘 15pt·시스템 폰트 13pt·선택 인셋 10/반경 6).
/// List 대신 LazyVStack 을 쓰는 이유: List 는 행 높이를 강제하기 어렵고,
/// 중첩 구조를 넣으면 트리 전체가 한 행이 되어 개별 파일을 고를 수 없다.
struct DiffFileList: View {
    let diff: ParsedDiff
    let commentCounts: [String: Int]
    var commentImportances: [String: ReviewImportance] = [:]
    @Binding var selection: String?

    @State private var tree: [FileTreeNode] = []
    @State private var expanded: Set<String> = []
    /// 목록이 좁으면 +/− 숫자를 숨겨 이름 자리를 준다. 예전에는 이름·숫자가 같이 줄어 최소 창에서 전부 "…" 였다.
    @State private var showsStats = true
    private static let statsMinWidth: CGFloat = 280

    private var rows: [FlatFileTreeRow] { FileTreeBuilder.flatten(tree, expanded: expanded) }

    var body: some View {
        VStack(spacing: 0) {
            HStack(spacing: 6) {
                Text("파일 \(diff.files.count)")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                Button {
                    expanded = expanded.isEmpty ? FileTreeBuilder.allDirectoryIDs(tree) : []
                } label: {
                    Image(systemName: expanded.isEmpty ? "chevron.down.square" : "chevron.right.square")
                }
                .buttonStyle(.borderless)
                .help(expanded.isEmpty ? "모두 펼치기" : "모두 접기")
            }
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            Divider()

            ScrollViewReader { proxy in
                ScrollView {
                    LazyVStack(alignment: .leading, spacing: 0) {
                        ForEach(rows) { row in
                            ForkFileRow(node: row.node,
                                        depth: row.depth,
                                        isExpanded: expanded.contains(row.node.id),
                                        isSelected: !row.node.isDirectory && selection == row.node.id,
                                        commentCount: commentCounts[row.node.id] ?? 0,
                                        commentImportance: commentImportances[row.node.id],
                                        showsStats: showsStats) {
                                if row.node.isDirectory {
                                    if expanded.contains(row.node.id) {
                                        expanded.remove(row.node.id)
                                    } else {
                                        expanded.insert(row.node.id)
                                    }
                                } else {
                                    selection = row.node.id
                                }
                            }
                            .id(row.node.id)
                        }

                        if !diff.excludedFiles.isEmpty {
                            Text("제외됨 (리뷰 대상 아님)")
                                .font(.caption)
                                .foregroundStyle(.tertiary)
                                .padding(.horizontal, 12)
                                .padding(.top, 10)
                                .padding(.bottom, 2)
                            // 흐리게 두되 **누를 수는 있다**. 리뷰에 안 보낸다는 것과
                            // 사람이 못 본다는 것은 다르다.
                            ForEach(diff.excludedFiles, id: \.path) { entry in
                                ExcludedFileRow(file: entry,
                                                isSelected: selection == entry.path) {
                                    selection = entry.path
                                }
                                .id(entry.path)
                            }
                        }
                    }
                    .padding(.vertical, 4)
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .onChange(of: selection) { _, newValue in
                    guard let newValue else { return }
                    withAnimation(.easeOut(duration: 0.15)) { proxy.scrollTo(newValue, anchor: .center) }
                }
            }
        }
        // 폭이 기준을 넘나들 때만 불린다 — 목록 폭을 끄는 동안 걸음마다 행을 다시 그리지 않는다.
        .onGeometryChange(for: Bool.self) { $0.size.width >= Self.statsMinWidth } action: { showsStats = $0 }
        .task(id: diff.files.map(\.path).joined()) {
            let built = FileTreeBuilder.build(files: diff.files)
            tree = built
            expanded = FileTreeBuilder.allDirectoryIDs(built)
        }
    }
}

/// 제외된 파일 한 줄.
///
/// 트리 행과 달리 폴더 구조·코멘트 수가 없어 `ForkFileRow` 를 그대로 쓰지 않는다.
/// 흐리게 그려 "리뷰에는 안 들어간다" 를 유지하되, 선택은 된다.
struct ExcludedFileRow: View {
    let file: DiffFile
    let isSelected: Bool
    let action: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: ForkTree.gutter)
            Text((file.path as NSString).lastPathComponent)
                .font(ForkTree.font)
                .foregroundStyle(isSelected ? Color.white : Color(nsColor: .tertiaryLabelColor))
                .lineLimit(1)
                .truncationMode(.head)
            Spacer(minLength: 6)
            Text("\(file.changedLines)")
                .font(ForkTree.statFont)
                .foregroundStyle(isSelected ? Color.white.opacity(0.8) : Color(nsColor: .tertiaryLabelColor))
            Spacer().frame(width: 3)
        }
        .frame(height: ForkTree.rowHeight)
        .padding(.vertical, ForkTree.rowSpacing / 2)
        .padding(.horizontal, ForkTree.selectionInset)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: ForkTree.selectionRadius)
                    .fill(Color.accentColor)
                    .padding(.horizontal, ForkTree.selectionInset - 4)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .help(LockFiles.isLockFile(file.path)
              ? "\(file.path) — 잠금 파일이라 리뷰에는 보내지 않습니다(내용은 볼 수 있습니다)"
              : "\(file.path) — 제외 경로라 리뷰에는 보내지 않습니다(내용은 볼 수 있습니다)")
    }
}

/// 트리 한 줄. 폴더면 눌러서 접고 펴고, 파일이면 눌러서 오른쪽 diff 를 바꾼다.
struct ForkFileRow: View {
    let node: FileTreeNode
    let depth: Int
    let isExpanded: Bool
    let isSelected: Bool
    let commentCount: Int
    /// 뱃지 색을 정하는 중요도(DiffTab.commentImportances). 없으면 사람 코멘트뿐이라 회색.
    var commentImportance: ReviewImportance?
    /// 좁은 목록에서는 +/− 숫자를 숨긴다(DiffFileList.showsStats).
    var showsStats = true
    let action: () -> Void

    var body: some View {
        HStack(spacing: 0) {
            Color.clear
                .frame(width: ForkTree.gutter + CGFloat(depth) * ForkTree.indentPerLevel)

            // 디스클로저 자리는 파일 행에서도 비워 둔다(이름 시작점이 어긋나지 않게).
            ZStack {
                if node.isDirectory {
                    Image(systemName: isExpanded ? "chevron.down" : "chevron.right")
                        .font(.system(size: 10, weight: .semibold))
                        .foregroundStyle(isSelected ? Color.white : Color(nsColor: .secondaryLabelColor))
                }
            }
            .frame(width: ForkTree.disclosureWidth)

            Spacer().frame(width: ForkTree.iconLeading)

            if node.isDirectory {
                SystemIconView(image: SystemIcon.folder)
                Spacer().frame(width: ForkTree.iconToTextFolder)
            } else {
                statusBadge
                Spacer().frame(width: ForkTree.statusToIcon)
                // 좁으면 파일 종류 아이콘도 뺀다 — 이름 끝의 확장자와 같은 말이라 이름 자리가 낫다.
                if showsStats {
                    SystemIconView(image: SystemIcon.file(node.name))
                    Spacer().frame(width: ForkTree.iconToTextFile)
                } else {
                    Spacer().frame(width: 2)
                }
            }

            // 좁아지면 이름이 먼저 자리를 갖고, 뱃지·숫자는 줄지 않는다 — 예전에는 셋이 같이 줄어 전부 "…" 가 됐다.
            // 앞을 줄인다. 한 폴더의 파일은 앞이 같은 일이 많아(LoginView·LoginViewModel) 가운데를 줄이면 전부
            // "Logi…swift" 로 같아졌다(최소 창 실측). 합친 폴더도 깊은 쪽이 남는다.
            Text(node.name)
                .font(ForkTree.font)
                .lineLimit(1)
                .truncationMode(.head)
                .foregroundStyle(isSelected ? Color.white : Color(nsColor: .controlTextColor))
                .layoutPriority(1)

            Spacer(minLength: 8)

            if commentCount > 0 {
                Label("\(commentCount)", systemImage: "text.bubble.fill")
                    .font(.system(size: 10))
                    .foregroundStyle(isSelected ? Color.white : commentImportance.map(importanceColor) ?? Color.secondary)
                    .padding(.trailing, showsStats ? 4 : 0)
                    .fixedSize()
                    .help(commentImportance.map { "코멘트 \(commentCount)개 · 가장 높은 중요도 \($0.label)" } ?? "코멘트 \(commentCount)개")
            }

            if showsStats {
                if node.isDirectory {
                    Text("\(node.fileCount)")
                        .font(ForkTree.statFont)
                        .foregroundStyle(isSelected ? Color.white.opacity(0.8) : Color(nsColor: .tertiaryLabelColor))
                        .fixedSize()
                } else {
                    Text("+\(node.additions)")
                        .font(ForkTree.statFont)
                        .foregroundStyle(isSelected ? Color.white : Color.green)
                        .fixedSize()
                    Text("−\(node.deletions)")
                        .font(ForkTree.statFont)
                        .foregroundStyle(isSelected ? Color.white.opacity(0.85) : Color.red)
                        .padding(.leading, 4)
                        .fixedSize()
                }
            }

            Spacer().frame(width: 3)
        }
        .frame(height: ForkTree.rowHeight)
        .padding(.vertical, ForkTree.rowSpacing / 2)
        .padding(.horizontal, ForkTree.selectionInset)
        .background {
            if isSelected {
                RoundedRectangle(cornerRadius: ForkTree.selectionRadius)
                    .fill(Color.accentColor)
                    .padding(.horizontal, ForkTree.selectionInset - 4)
            }
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .help(node.id)
    }

    /// 새 파일·삭제·바이너리를 Fork 처럼 작은 배지로 구분한다.
    @ViewBuilder
    private var statusBadge: some View {
        Group {
            if let file = node.file {
                if file.isNew {
                    Image(systemName: "plus.circle.fill").foregroundStyle(isSelected ? Color.white : .green)
                } else if file.isDeleted {
                    Image(systemName: "minus.circle.fill").foregroundStyle(isSelected ? Color.white : .red)
                } else if file.isBinary {
                    Image(systemName: "doc.badge.gearshape").foregroundStyle(isSelected ? Color.white : .secondary)
                } else {
                    Image(systemName: "pencil.circle.fill").foregroundStyle(isSelected ? Color.white : .orange)
                }
            }
        }
        .font(.system(size: 10))
        .frame(width: ForkTree.statusSize, height: ForkTree.statusSize)
    }
}

struct DiffFileView: View {
    let file: DiffFile
    @Binding var mode: DiffViewMode
    let comments: [DraftCommentState]
    let threads: [PRReviewThread]
    let pr: PullRequestInfo
    let files: [DiffFile]
    @Binding var selection: String?
    @Binding var showFileList: Bool
    @Binding var scrollTargetKey: String?
    /// 이 파일 안에서 따라가는 리뷰 항목. 그 줄을 칠하고 바로 아래에 항목 카드를 펼친다.
    var follow: FollowTarget? = nil
    /// 이 파일의 코드 코멘트 카드 자리(DiffTab.issueAnchors).
    var issueAnchors: [IssueAnchor] = []

    /// 행 페어링은 파일이 바뀔 때만 계산한다. body 에서 매번 계산하면 스크롤이 버벅인다.
    @State private var loadedRows: [DiffRow] = []
    /// `loadedRows` 가 어느 파일의 행인가.
    @State private var loadedPath: String?
    /// 앞에서부터 몇 줄까지 그리는가(`rowPageSize`). "더 보기" 와 뒤쪽 줄로 가는 스크롤이 늘린다.
    @State private var shownRowLimit = DiffFileView.rowPageSize
    @Environment(AppModel.self) private var model

    /// 지금 파일의 행. 파일을 바꾸면 행은 비동기로 다시 만드는데, 그사이 옛 파일의 행이 새 파일의 색칠 규칙
    /// (`syntax`)으로 그려졌다 — 마크다운 줄이 Swift 규칙으로 칠해지다 스캐너가 멈춘 실측이 있다. 옛 행은 내놓지 않는다.
    private var rows: [DiffRow] { loadedPath == file.path ? loadedRows : [] }

    /// 나란히 보기에서 왼쪽이 차지하는 비율.
    ///
    /// PR 이나 파일이 아니라 **앱 전체**가 하나를 쓴다. 파일마다 따로 두면 파일을 옮길 때마다
    /// 폭이 튀고, PR 마다 따로 두면 PR 을 열 때마다 다시 끌어야 한다. 한쪽을 넓게 보는 것은
    /// 그 파일의 성질이 아니라 **읽는 사람의 습관**이라, 한 번 정하면 계속 가는 편이 맞다.
    @AppStorage("diffSplitRatio") private var splitRatio = 0.5
    /// 끌기 시작할 때의 비율. 끄는 동안 누적 오차가 생기지 않게 기준점을 잡아 둔다.
    @State private var dragStartRatio: Double?
    @State private var pushedResizeCursor = false

    /// 한쪽이 0 이 되면 그 안의 내용도, 되돌릴 손잡이도 같이 사라진다.
    private static let minSideWidth = 140.0

    private func splitLeftWidth(in total: CGFloat) -> CGFloat {
        guard total > Self.minSideWidth * 2 else { return total / 2 }
        return min(max(Self.minSideWidth, total * splitRatio), total - Self.minSideWidth)
    }

    /// 좌우를 가르는 선. 화면 높이만큼 **한 줄**로 그린다.
    /// 줄마다 그리면 어느 한 줄이 폭을 다르게 계산할 때 선이 톱니처럼 어긋난다.
    private func splitGuide(leftWidth: CGFloat) -> some View {
        Rectangle()
            .fill(.separator)
            .frame(width: 1)
            .frame(maxHeight: .infinity)
            .offset(x: leftWidth)
            .allowsHitTesting(false)
    }

    private func splitHandle(totalWidth: CGFloat, leftWidth: CGFloat) -> some View {
        Rectangle()
            .fill(.clear)
            .frame(width: 10)
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .offset(x: leftWidth - 5)
            // push/pop 은 짝이 맞아야 한다. 깃발 없이 부르면 나가는 이벤트를 놓쳤을 때
            // 커서 스택이 쌓여 다른 곳에서도 좌우 화살표가 남는다(MainWindow 와 같은 처리).
            .onHover { inside in
                if inside, !pushedResizeCursor {
                    NSCursor.resizeLeftRight.push()
                    pushedResizeCursor = true
                } else if !inside, pushedResizeCursor {
                    NSCursor.pop()
                    pushedResizeCursor = false
                }
            }
            .gesture(
                DragGesture(minimumDistance: 1)
                    .onChanged { value in
                        guard totalWidth > 0 else { return }
                        let base = dragStartRatio ?? splitRatio
                        if dragStartRatio == nil { dragStartRatio = base }
                        splitRatio = min(0.9, max(0.1, base + value.translation.width / totalWidth))
                    }
                    .onEnded { _ in dragStartRatio = nil })
            // 더블클릭으로 반반 — 메인 창 분할선과 같은 몸짓이다.
            .onTapGesture(count: 2) { splitRatio = 0.5 }
            .help("드래그로 좌우 폭 조절 · 더블클릭하면 반반")
    }

    private var syntax: SyntaxProfile? { CodeSyntax.profile(forPath: file.path) }

    /// 추가만 되었거나 삭제만 된 파일은 반대쪽 열이 통째로 비어 있다.
    /// 나란히 보기라도 한 열로 꽉 채워 보여주는 편이 읽기 쉽다.
    private var isOneSided: Bool { file.isNew || file.isDeleted }
    private var effectiveMode: DiffViewMode { isOneSided ? .unified : mode }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            if ImageFiles.isImage(file.path) {
                ImageDiffView(file: file, pr: pr)
            } else if file.isBinary {
                ContentUnavailableView("바이너리 파일", systemImage: "doc.badge.gearshape")
            } else if rows.isEmpty {
                ProgressView().frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                // 나란히 보기의 좌우 폭을 사용자가 정한다. 반반 고정이면 한쪽 줄이 길 때
                // 그쪽이 잘려서, 읽으려는 줄을 끝까지 볼 방법이 없었다.
                GeometryReader { geometry in
                    let width = geometry.size.width
                    let left = splitLeftWidth(in: width)
                    ScrollViewReader { proxy in
                        ScrollView {
                            // 지연 스택(LazyVStack)을 쓰지 않는다 — 배치가 끝나지 않아 앱이 멈췄다(`rowPageSize` 주석).
                            // 대신 한 번에 그리는 줄을 `rowPageSize` 씩으로 묶고, 나머지는 사람이 펼친다.
                            VStack(alignment: .leading, spacing: 0) {
                                // 바뀐 줄 밖을 가리키는 코드 코멘트. 펼칠 줄이 없어 파일 맨 위에 모은다.
                                let outside = issueAnchors.filter { anchor in !rows.contains { anchor.matches($0) } }
                                if !outside.isEmpty, !rows.isEmpty {
                                    VStack(alignment: .leading, spacing: 0) {
                                        Label("바뀐 줄 밖을 가리키는 코드 코멘트 — 파일 맨 위에 모았습니다.", systemImage: "eye.slash")
                                            .font(.caption)
                                            .foregroundStyle(.secondary)
                                            .padding(.horizontal, 12)
                                            .padding(.top, 6)
                                        ForEach(outside) { anchor in
                                            IssueCard(pr: pr, issue: anchor.issue, showsLocation: false)
                                                .diffCommentChrome()
                                        }
                                    }
                                    .background(Color(nsColor: .textBackgroundColor))
                                    .id(Self.outsideFollowID)
                                }
                                ForEach(rows.prefix(shownRowLimit)) { row in
                                    DiffRowView(row: row,
                                                mode: effectiveMode,
                                                path: file.path,
                                                comments: comments,
                                                threads: threads,
                                                pr: pr,
                                                syntax: syntax,
                                                leftWidth: effectiveMode == .split ? left : nil,
                                                follow: follow.flatMap { $0.matches(row) ? $0 : nil },
                                                issues: issueAnchors.filter { $0.matches(row) })
                                        .id(rowID(row))
                                }
                                if rows.count > shownRowLimit {
                                    moreRowsBar
                                }
                            }
                            .padding(.vertical, 4)
                            // 가운데 선은 내용 **뒤**에 그린다. 위에 얹으면 코드 코멘트 카드 위로도 지나갔다(사용자 피드백).
                            // 코드 줄은 바탕이 비치거나 옅어서 선이 그대로 보이고, 코멘트 카드는 바탕이 불투명해 가린다.
                            .background(alignment: .topLeading) {
                                if effectiveMode == .split, width > 0 { splitGuide(leftWidth: left) }
                            }
                        }
                        .task(id: scrollTargetKey) { await scroll(proxy: proxy) }
                        .onChange(of: file.path) { _, _ in Task { await scroll(proxy: proxy) } }
                    }
                    // 줄마다 있는 Divider 는 짧은 선이 이어 붙은 것이라 끌 수 없다.
                    // 그 자리에 화면 높이만큼의 손잡이를 따로 얹는다.
                    .overlay(alignment: .topLeading) {
                        if effectiveMode == .split, width > 0 {
                            // 둘을 왼쪽 맞춤으로 겹친다. 그냥 나열하면 가운데 맞춤으로 겹쳐져 1pt 선이 10pt 손잡이 한가운데
                            // (4.5pt 오른쪽)로 밀렸다 — 선이 오른쪽 칸 색보다 그만큼 오른쪽에 그어졌다(사용자 제보, 확대 실측 5pt).
                            // 선은 내용 뒤(위 background)에 있고, 여기엔 끄는 손잡이만 얹는다.
                            splitHandle(totalWidth: width, leftWidth: left)
                        }
                    }
                }
            }
        }
        .task(id: file.path) {
            // 파일을 바꿔도 이 뷰는 그대로라 펼친 줄 수가 남는다. 새 파일은 첫 묶음부터 그린다.
            shownRowLimit = Self.rowPageSize
            let target = file
            let built = await Task.detached(priority: .userInitiated) { DiffPairing.rows(for: target) }.value
            loadedRows = built
            loadedPath = target.path
        }
    }

    private var header: some View {
        HStack(spacing: 10) {
            Button {
                showFileList.toggle()
            } label: {
                Image(systemName: showFileList ? "sidebar.leading" : "sidebar.left")
            }
            .buttonStyle(.borderless)
            .help(showFileList ? "파일 목록 접기 (나란히 보기에서 폭 확보)" : "파일 목록 펼치기")

            if !showFileList {
                Menu {
                    ForEach(files) { candidate in
                        Button {
                            selection = candidate.path
                        } label: {
                            Text("\((candidate.path as NSString).lastPathComponent)  +\(candidate.additions) −\(candidate.deletions)")
                        }
                    }
                } label: {
                    Label("파일 \(files.count)", systemImage: "list.bullet.indent")
                        .font(.caption)
                }
                .menuStyle(.borderlessButton)
                .fixedSize()
            }

            Text(file.path)
                .font(.callout.monospaced())
                .lineLimit(1)
                .truncationMode(.head)
                .textSelection(.enabled)
            Text("+\(file.additions) −\(file.deletions)")
                .font(.caption.monospacedDigit())
                .foregroundStyle(.secondary)
            if !comments.isEmpty {
                Label("코멘트 \(comments.count)", systemImage: "text.bubble.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
            Spacer()
            if isOneSided {
                // 반대쪽이 비어 있어 나란히 볼 것이 없다. 왜 토글이 잠겼는지 알려 준다.
                Text(file.isNew ? "추가된 파일 — 한 열로 표시" : "삭제된 파일 — 한 열로 표시")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            } else if !ImageFiles.isImage(file.path) {
                Picker("", selection: $mode) {
                    ForEach(DiffViewMode.allCases) { option in
                        Label(option.label, systemImage: option.symbol).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 170)
                .help("나란히: 옛 코드 / 새 코드를 양쪽에 · 한 줄로: +/− 를 한 줄에")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }



    private func rowID(_ row: DiffRow) -> String {
        if let line = row.right?.newLine {
            return DiffKeys.key(path: file.path, side: .right, line: line)
        }
        if let line = row.left?.oldLine {
            return DiffKeys.key(path: file.path, side: .left, line: line)
        }
        return "row-\(row.id)"
    }

    private static let outsideFollowID = "follow-outside-diff"

    /// 한 번에 그리는 줄 수. 넘는 파일은 맨 아래 "더 보기" 로 이만큼씩 펼친다.
    ///
    /// 지연 스택(LazyVStack)에서 앱이 멈췄다(2026-10-21 실측, 베타 8: 화면은 그대로인데 CPU 100%, 메인 스레드가
    /// `GraphHost.flushTransactions` 한 번 안에서 `LazySubviewPlacements.placeSubviews` → `AllItemsPhaseMutation` 을
    /// 끝없이 되풀이했다). 줄 높이가 코드 한 줄부터 코드 코멘트 카드까지 열 배 넘게 달라 높이 추정이 배치마다 바뀌는데,
    /// 그 배치 도중에 줄 안의 AppKit 뷰(카드의 입력칸·버튼, 텍스트 선택)가 창이 키를 얻고 잃을 때 모양을 다시 정하며
    /// 무효화를 내면 SwiftUI 가 같은 배치로 다시 들어가 수렴하지 못한다. 앱 코드가 막을 수 있는 무효화가 아니라 지연 배치를
    /// 아예 쓰지 않는다. `PRAYER_DEBUG_SCROLL_SWEEP` + `PRAYER_DEBUG_SWEEP_TOGGLE_KEY` 로 재현했다(7번 중 1번).
    ///
    /// 그렇다고 다 그리면 처음 열 때 메인 스레드가 막히고 메모리가 문서 높이만큼 는다(디버그 빌드 실측: 짧은 줄 300~400행은
    /// 0.3초·+50MB, 줄이 접히는 1,000행은 1.6초·+700MB, 2,000행은 3초·+700MB). 캐시된 실제 파일 684개는 중간 29줄,
    /// 상위 1% 426줄, 가장 큰 것 637줄이라 500줄이면 거의 다 한 번에 보인다. 큰 파일은 GitHub 처럼 사람이 더 펼친다.
    static let rowPageSize = 500

    /// `index` 번째 줄을 그리려면 몇 줄까지 펼쳐야 하는가. 묶음 단위로 펼치고, 그 줄 아래로 카드·문맥이 보이게
    /// 끝에 걸리면 한 묶음 더 펼친다.
    private static func rowLimit(covering index: Int) -> Int {
        ((index + 50) / rowPageSize + 1) * rowPageSize
    }

    /// 줄 키(`DiffKeys`)가 가리키는 줄. 키는 한쪽 면의 줄 번호라, 양쪽이 다 있는 줄은 두 키 모두 그 줄이다.
    /// (줄 id 는 오른쪽 번호를 먼저 쓰므로 왼쪽 키로는 `scrollTo` 가 그 줄을 못 찾았다.)
    private func rowIndex(forKey key: String) -> Int? {
        rows.firstIndex { row in
            row.right?.newLine.map { DiffKeys.key(path: file.path, side: .right, line: $0) } == key
                || row.left?.oldLine.map { DiffKeys.key(path: file.path, side: .left, line: $0) } == key
        }
    }

    /// 아직 그리지 않은 줄이 있을 때 맨 아래에 다는 줄.
    private var moreRowsBar: some View {
        let hidden = rows.count - shownRowLimit
        let hiddenCards = issueAnchors.filter { anchor in rows.dropFirst(shownRowLimit).contains { anchor.matches($0) } }.count
        return HStack(spacing: 10) {
            VStack(alignment: .leading, spacing: 2) {
                Text("\(rows.count)줄 중 \(shownRowLimit)줄까지 보여 줍니다. 아래 \(hidden)줄은 아직 그리지 않았습니다.")
                if hiddenCards > 0 {
                    Text("가려진 줄에 코드 코멘트 \(hiddenCards)개")
                        .foregroundStyle(.orange)
                }
            }
            .font(.caption)
            .foregroundStyle(.secondary)
            Spacer()
            Button("다음 \(min(Self.rowPageSize, hidden))줄 더 보기") {
                shownRowLimit += Self.rowPageSize
            }
            .help("큰 파일은 한 번에 다 그리면 앱이 한동안 멈춰서 \(Self.rowPageSize)줄씩 펼칩니다")
            Button {
                if let url = pr.filesURL(host: model.settings.githubHost, path: file.path) {
                    NSWorkspace.shared.open(url)
                }
            } label: {
                Label("GitHub 에서 보기", systemImage: "arrow.up.right.square")
            }
            .help("GitHub 의 변경 파일 탭에서 이 파일을 엽니다")
        }
        .controlSize(.small)
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .frame(maxWidth: .infinity, alignment: .leading)
        // 나란히 보기의 가운데 선이 내용 뒤로 지나가므로 바탕을 채워 가린다(코드 코멘트 카드와 같은 처리).
        .background(Color(nsColor: .textBackgroundColor))
        .overlay(alignment: .top) { Divider() }
    }

    /// 따라가는 줄이 이 파일 diff 에 없다. 질문 근거는 전체 리뷰가 읽은 파일의 어느 줄이든 가리킬 수 있어서
    /// 바뀐 줄 밖(두 hunk 사이)일 때가 있다(실측). 펼칠 줄이 없으니 파일 맨 위에 펼친다 — 안 그러면 따라가기 줄만
    /// 뜨고 카드는 아무 데도 안 보인다.
    private var followOutsideDiff: FollowTarget? {
        guard let follow, !rows.isEmpty, !rows.contains(where: follow.matches) else { return nil }
        return follow
    }

    private func scroll(proxy: ScrollViewProxy) async {
        guard let scrollTargetKey, scrollTargetKey.hasPrefix(file.path + "#") else { return }
        var target = scrollTargetKey
        if followOutsideDiff != nil {
            target = Self.outsideFollowID
        } else if let index = rowIndex(forKey: scrollTargetKey) {
            target = rowID(rows[index])
            // 코드에서 보기·따라가기가 아직 안 그린 뒤쪽 줄을 가리킨다. 그 줄까지 펼친 다음 간다.
            if index >= shownRowLimit {
                shownRowLimit = Self.rowLimit(covering: index)
                // 펼친 줄이 그려진 뒤라야 scrollTo 가 그 id 를 찾는다. 상태를 바꾼 그 자리에서 부르면 아무 일도 안 한다.
                try? await Task.sleep(for: .milliseconds(50))
                guard !Task.isCancelled else { return }
            }
        }
        // 가운데가 아니라 조금 위에 둔다. 그 줄 아래로 코멘트·항목 카드가 펼쳐져서, 가운데에 두면 카드가 화면 밖으로 밀린다.
        withAnimation { proxy.scrollTo(target, anchor: UnitPoint(x: 0.5, y: 0.2)) }
        self.scrollTargetKey = nil
    }
}

struct DiffRowView: View {
    @Environment(AppModel.self) private var model
    let row: DiffRow
    let mode: DiffViewMode
    let path: String
    let comments: [DraftCommentState]
    let threads: [PRReviewThread]
    let pr: PullRequestInfo
    /// 파일 종류에 맞는 색칠 규칙. 모르는 확장자면 nil 이라 평문으로 그린다.
    let syntax: SyntaxProfile?
    /// 나란히 보기에서 왼쪽 칸의 폭. 파일 뷰가 정한 값을 모든 줄이 **같이** 받아야
    /// 줄마다 경계가 어긋나지 않는다. nil 이면 예전처럼 반반.
    var leftWidth: CGFloat?
    /// 이 줄이 따라가는 리뷰 항목의 자리면 그 항목. 파일 뷰가 맞는 줄에만 넘긴다(그 줄을 칠할 때 쓴다).
    var follow: FollowTarget? = nil
    /// 이 줄에 다는 코드 코멘트 카드. 파일 뷰가 맞는 줄에만 넘긴다.
    var issues: [IssueAnchor] = []

    /// 이 줄에 달린 사람 코멘트. GitHub 스레드의 line 은 새 코드(오른쪽) 기준이다.
    private var attachedThreads: [PRReviewThread] {
        guard let newLine = row.right?.newLine else { return [] }
        return threads.filter { $0.line == newLine }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if row.kind == .hunk {
                let raw = row.left?.raw ?? ""
                if mode == .split {
                    // 한 줄로 그리면 폭 전체를 먹어 오른쪽 열을 덮는다. 원래 양쪽 정보를
                    // 한 줄에 담고 있는 줄이라, 나란히 볼 때는 나눠 두는 편이 맞다.
                    let parts = DiffParser.hunkDisplayParts(raw)
                    HStack(spacing: 0) {
                        hunkText(parts.left, full: raw)
                            .frame(width: leftWidth)
                        hunkText(parts.right, full: raw)
                    }
                    .background(.quaternary.opacity(0.35))
                } else {
                    hunkText(raw, full: raw)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .background(.quaternary.opacity(0.35))
                }
            } else if mode == .split {
                // 줄이 접혀 여러 줄이 되면 높이가 달라진다. 가운데 정렬이면 짧은 쪽이
                // 허공에 떠서 같은 행끼리 눈으로 못 맞춘다. 위에 붙인다.
                // 가운데 선은 **줄마다 그리지 않는다.** 줄마다 Divider 를 두면 그 선은
                // 실제로는 짧은 선 수백 개라, 어느 한 줄이 폭을 다르게 계산하는 순간
                // 선이 톱니처럼 어긋난다(실측 보고). 파일 뷰가 화면 높이만큼 **한 줄**을
                // 그리므로(splitGuide) 여기서는 칸만 나눈다 — 어긋날 수가 없다.
                HStack(alignment: .top, spacing: 0) {
                    // leftWidth 가 nil 이면 예전처럼 반반이다(파일 뷰 밖에서 쓰는 경우).
                    cell(line: row.left, side: .left)
                        .frame(width: leftWidth)
                    cell(line: row.right, side: .right)
                }
            } else {
                unifiedCells
            }

            // 사람이 이미 단 코멘트가 먼저(파랑), 그다음 내 코드 코멘트 카드(AI 리뷰 탭 오른쪽과 같은 카드).
            // 예전엔 주황 초안 칸과 보라 항목 칸(‹ › 로 하나씩 따라가기)이 따로였다 — 이제 줄마다 다 펼쳐 둔다.
            ForEach(attachedThreads) { thread in
                InlineThreadPreview(thread: thread, pr: pr)
            }
            ForEach(issues) { anchor in
                IssueCard(pr: pr, issue: anchor.issue, showsLocation: false)
                    .diffCommentChrome()
            }
        }
    }

    /// hunk 머리글 한 조각. 잘려도 원문은 툴팁으로 남긴다.
    private func hunkText(_ text: String, full: String) -> some View {
        Text(text)
            .font(model.fonts.code())
            .foregroundStyle(.secondary)
            .lineLimit(1)
            .truncationMode(.tail)
            .padding(.horizontal, 10)
            .padding(.vertical, 3)
            .frame(maxWidth: .infinity, alignment: .leading)
            .help(full)
    }

    @ViewBuilder
    private var unifiedCells: some View {
        if row.kind == .context {
            unifiedLine(row.left, kind: .context)
        } else {
            if let left = row.left { unifiedLine(left, kind: .deletion) }
            if let right = row.right { unifiedLine(right, kind: .addition) }
        }
    }

    private func unifiedLine(_ line: DiffLine?, kind: DiffLine.Kind) -> some View {
        HStack(spacing: 8) {
            Text(line?.oldLine.map(String.init) ?? "")
                .frame(width: 40, alignment: .trailing)
            Text(line?.newLine.map(String.init) ?? "")
                .frame(width: 40, alignment: .trailing)
            HStack(spacing: 0) {
                Text(marker(for: kind))
                CodeLineText(text: line?.text ?? "", profile: syntax,
                             font: model.fonts.code(),
                             dimmed: kind == .context)
                    .textSelection(.enabled)
                Spacer(minLength: 0)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .font(model.fonts.code())
        .foregroundStyle(kind == .context ? Color.secondary : Color.primary)
        .padding(.horizontal, 10)
        .padding(.vertical, 1)
        .background(background(for: kind, marked: isMarked(line, kind: kind),
                               followed: follow?.highlights(line, kind: kind) == true))
    }

    private func cell(line: DiffLine?, side: DiffSide) -> some View {
        let kind = line?.kind ?? .context
        let marked = isMarked(line, kind: kind)
        let followed = follow?.highlights(line, kind: kind) == true
        // 줄 번호는 접힌 줄의 **첫 줄** 옆에 있어야 한다. 가운데 정렬이면 3줄짜리 옆에서
        // 번호가 가운데 떠서 어느 줄의 번호인지 알 수 없다.
        return HStack(alignment: .firstTextBaseline, spacing: 6) {
            Text(number(for: line, side: side))
                .font(model.fonts.code(size: max(9, model.settings.codeFontSize - 1)))
                .frame(width: 40, alignment: .trailing)
                .foregroundStyle(.tertiary)
            CodeLineText(text: line?.text ?? "", profile: syntax,
                         font: model.fonts.code(),
                         dimmed: kind == .context)
                // 한 줄로 자르면 긴 줄을 끝까지 볼 방법이 없다. 세 줄까지는 접어 내려가고,
                // 그보다 길면 그때 자른다(전체 내용은 아래 help 툴팁에 그대로 있다).
                // 무제한으로 두지 않는 이유: 1,900자짜리 한 줄이 화면을 스무 줄쯤 먹는다.
                // 단, 코드 코멘트가 달린 줄(주황)과 코멘트에서 건너온 줄(노랑)은 끝까지 편다 —
                // 코멘트가 바로 그 줄 이야기라 잘린 뒷부분을 읽어야 할 때가 많다(사용자 피드백).
                .lineLimit(marked || followed ? nil : 3)
                .truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
                .textSelection(.enabled)
                .help(line?.text ?? "")
        }
        .font(.system(size: 11.5, design: .monospaced))
        .padding(.horizontal, 8)
        .padding(.vertical, 1)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(line == nil ? AnyShapeStyle(.quaternary.opacity(0.25))
                                : AnyShapeStyle(background(for: kind, marked: marked, followed: followed)))
    }

    private func number(for line: DiffLine?, side: DiffSide) -> String {
        guard let line else { return "" }
        switch side {
        case .left: return line.oldLine.map(String.init) ?? ""
        case .right: return line.newLine.map(String.init) ?? ""
        }
    }

    private func marker(for kind: DiffLine.Kind) -> String {
        switch kind {
        case .addition: return "+ "
        case .deletion: return "− "
        default: return "  "
        }
    }

    /// 코드 코멘트 카드가 달린 줄인가. 예전엔 AI 초안이 있는 줄만 칠해서, 초안 없는 질문이 단 줄은 칠해지지 않아
    /// 카드가 어느 줄 것인지 안 보였다(사용자 피드백). 이제 카드가 달린 줄이면 다 칠한다.
    private func isMarked(_ line: DiffLine?, kind: DiffLine.Kind) -> Bool {
        guard let line else { return false }
        return issues.contains { anchor in
            guard let at = anchor.line else { return false }
            switch anchor.side {
            case .right: return line.newLine == at && kind != .deletion
            case .left: return line.oldLine == at && kind != .addition
            }
        }
    }

    private func background(for kind: DiffLine.Kind, marked: Bool, followed: Bool = false) -> AnyShapeStyle {
        // 따라온 줄이 먼저다. 이 줄을 보러 왔다는 표시라 초안 표시(주황)보다 앞선다.
        if followed { return AnyShapeStyle(Color.yellow.opacity(0.32)) }
        if marked { return AnyShapeStyle(Color.orange.opacity(0.28)) }
        switch kind {
        case .addition: return AnyShapeStyle(Color.green.opacity(0.14))
        case .deletion: return AnyShapeStyle(Color.red.opacity(0.14))
        default: return AnyShapeStyle(Color.clear)
        }
    }
}

/// diff 안에서 "여기에 이 코멘트가 달린다" 를 그대로 보여준다.
/// 사람이 단 코드 코멘트. AI 초안(주황)과 구분되게 파랑으로 그린다.
struct InlineThreadPreview: View {
    @Environment(AppModel.self) private var model
    let thread: PRReviewThread
    let pr: PullRequestInfo
    @State private var showAllReplies = false

    private var visibleComments: [ReviewThreadComment] {
        showAllReplies ? thread.comments : Array(thread.comments.prefix(1))
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: thread.isResolved ? "checkmark.bubble.fill" : "bubble.left.fill")
                .font(.caption)
                .foregroundStyle(thread.isResolved ? Color.secondary : Color.accentColor)
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 6) {
                    Tag(text: "사람 리뷰", color: .accentColor)
                    if thread.isResolved { Tag(text: "해결됨", color: .secondary) }
                    if thread.isOutdated { Tag(text: "옛 코드", color: .secondary) }
                }
                ForEach(Array(visibleComments.enumerated()), id: \.offset) { _, comment in
                    VStack(alignment: .leading, spacing: 1) {
                        HStack(spacing: 5) {
                            Text(model.settings.displayName(comment.author))
                                .font(.caption.weight(.semibold))
                                .help(comment.author)
                            if let at = PRActivityBuilder.isoDate(comment.createdAt) {
                                RelativeTimeText(date: at, style: .ago)
                                    .font(.caption2)
                                    .foregroundStyle(.tertiary)
                            }
                        }
                        MarkdownText(text: comment.body)
                    }
                }
                if thread.comments.count > 1 {
                    Button(showAllReplies ? "답글 접기" : "답글 \(thread.comments.count - 1)개 더 보기") {
                        showAllReplies.toggle()
                    }
                    .buttonStyle(.link)
                    .font(.caption2)
                }
                ExplainBox(target: ExplainTarget(thread: thread), pr: pr)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.accentColor.opacity(thread.isResolved ? 0.05 : 0.09))
        .overlay(alignment: .leading) {
            Rectangle()
                .fill(thread.isResolved ? Color.secondary : Color.accentColor)
                .frame(width: 3)
        }
        .opacity(thread.isResolved ? 0.7 : 1)
        // 불투명한 바탕 — 나란히 보기의 가운데 선이 코멘트 뒤로 비치지 않게.
        .background(Color(nsColor: .textBackgroundColor))
    }
}

/// 변경 파일 탭에서 코드 코멘트 카드를 달 자리.
struct IssueAnchor: Identifiable {
    let issue: ReviewIssue
    /// nil 이면 이 파일의 바뀐 줄 밖이다.
    let line: Int?
    let side: DiffSide

    var id: String { issue.id }

    func matches(_ row: DiffRow) -> Bool {
        guard let line, row.kind != .hunk else { return false }
        switch side {
        case .right: return row.right?.newLine == line && row.right?.kind != .deletion
        case .left: return row.left?.oldLine == line && row.left?.kind != .addition
        }
    }
}

extension View {
    /// 변경 파일 탭의 코드 코멘트 카드 틀. 바탕이 불투명해 나란히 보기의 가운데 선이 카드 뒤로 비치지 않는다.
    func diffCommentChrome() -> some View {
        background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 8))
            .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color(nsColor: .separatorColor)))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(Color(nsColor: .textBackgroundColor))
    }
}
