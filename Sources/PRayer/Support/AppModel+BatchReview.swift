import AppKit
import PRayerCore

/// 여러 PR 에 한꺼번에 거는 리뷰 — 묶음 확인 창(BatchReviewSheet)이 PR 마다 미리 잰 것.
struct BatchReviewCheck: Sendable {
    /// 지금 제외 규칙을 뺀 뒤의 변경 줄 수. diff 를 못 받았으면 PR 목록의 줄 수(어림).
    let lines: Int
    /// 한 파일이 1,000줄 넘게 바뀌어 "빼고 리뷰" 를 물을 파일(SkippableFiles).
    let skippable: [DiffFile]
    /// diff 를 받아 잰 값인가. 못 받았으면 줄 수가 어림이고 큰 파일을 모른다.
    let measured: Bool

    var skippedLines: Int { skippable.reduce(0) { $0 + $1.changedLines } }
}

/// 묶음 확인 창에 넘기는 것 — 어느 PR 들을 어떤 리뷰로 거나.
struct PendingBatchReview: Identifiable {
    let id = UUID()
    /// 목록 순서(위에서 아래). 큐에도 이 순서로 들어간다.
    let prs: [PullRequestInfo]
    let deep: Bool
    /// 같이 골랐지만 닫혀서 뺀 PR 수 — 창에 한 줄 알린다.
    var closedCount = 0
}

/// 리뷰 목록에서 ⌘·⇧ 클릭으로 여러 개 골라 우클릭 → 한꺼번에 리뷰.
///
/// 한 개일 때의 확인 창(스냅샷 클론·큰 파일 빼기·변경 많음)은 PR 마다 따로 떠서, 여러 개면 창이 연달아 뜬다.
/// 그래서 둘 이상이면 늘 묶음 창 하나로 모아 한 번만 묻는다(2026-10-23 사용자 결정 — 시안 A, "2개 이상이면 늘").
/// 여러 개는 토큰을 그만큼 쓰니 합계를 보고 누르게 한다. 하나만 우클릭하면 지금 흐름 그대로다.
extension AppModel {
    // MARK: - 고르기

    /// 행 클릭을 그 목록의 고르기 규칙(RowSelection)으로 처리한다.
    func click(_ pr: PullRequestInfo, in list: [PullRequestInfo],
               selection keyPath: ReferenceWritableKeyPath<AppModel, RowSelection>) {
        var selection = self[keyPath: keyPath]
        let next = selection.click(pr.id, in: list.map(\.id), current: selectedPRID, modifier: .current)
        // 고른 것을 먼저 바꾼다 — selectedPRID 를 먼저 바꾸면 "고른 것 밖으로 옮겨 갔다" 로 읽혀 방금 고른 것이 풀린다.
        self[keyPath: keyPath] = selection
        if let next { selectedPRID = next }
    }

    /// 리뷰 목록 행 클릭.
    func clickListPR(_ pr: PullRequestInfo) {
        click(pr, in: visiblePRs, selection: \.listSelection)
    }

    /// 목록에서 방향키로 한 칸 옮긴다(PRListView). 위의 "내가 올린 PR" 과 아래 리뷰 목록을 한 줄로 이어 오가고,
    /// ⇧ 로 늘이는 것은 보고 있는 PR 이 있는 목록 안에서만 한다 — 두 목록은 고른 것을 따로 둔다(RowSelection 주석).
    ///
    /// - Parameter mine: "내가 올린 PR" 에 지금 보이는 행(접혀 있으면 빈 배열).
    /// - Parameter extra: 검색 아래 구역(지금 탭 밖)의 행. 리뷰 목록 끝에서 이어 내려간다 — 같이 고르기는 하지 않는다.
    /// - Returns: 새로 보게 된 PR — 목록이 그 행까지 스크롤한다. 끝이라 못 옮겼으면 nil.
    @discardableResult
    func moveListCursor(by delta: Int, extend: Bool, mine: [PullRequestInfo], extra: [PullRequestInfo] = []) -> String? {
        let mineIDs = mine.map(\.id)
        let reviewIDs = visiblePRs.map(\.id)
        let all = mineIDs + reviewIDs + extra.map(\.id)
        guard let current = selectedPRID, all.contains(current) else {
            // 고른 것이 없거나 지금 목록에 안 보이면(탭·필터를 바꿨다) ↓ 는 맨 위, ↑ 는 맨 아래부터.
            guard let first = delta > 0 ? all.first : all.last else { return nil }
            setCursor(first, mineIDs: mineIDs, extra: extra)
            return first
        }
        let inMine = mineIDs.contains(current)
        let inExtra = extra.contains { $0.id == current }
        if extend, !inExtra {
            var selection = inMine ? myPRSelection : listSelection
            guard let next = selection.move(by: delta, in: inMine ? mineIDs : reviewIDs,
                                            current: current, extend: true) else { return nil }
            // 고른 것을 먼저 바꾼다 — click(_:in:selection:) 과 같은 이유.
            if inMine { myPRSelection = selection } else { listSelection = selection }
            selectedPRID = next
            return next
        }
        guard let index = all.firstIndex(of: current), all.indices.contains(index + delta) else { return nil }
        let next = all[index + delta]
        setCursor(next, mineIDs: mineIDs, extra: extra)
        return next
    }

    private func setCursor(_ id: String, mineIDs: [String], extra: [PullRequestInfo]) {
        if let pr = extra.first(where: { $0.id == id }) {
            clickExtraSearchPR(pr)
        } else {
            setSingleSelection(id, inMine: mineIDs.contains(id))
        }
    }

    private func setSingleSelection(_ id: String, inMine: Bool) {
        if inMine { myPRSelection = RowSelection(ids: [id], anchor: id) } else { listSelection = RowSelection(ids: [id], anchor: id) }
        selectedPRID = id
    }

    func isInListSelection(_ pr: PullRequestInfo) -> Bool {
        listSelection.isMarked(pr.id)
    }

    /// 같이 고른 것을 푼다. 보고 있는 PR 은 그대로 둔다.
    func clearListSelection() {
        listSelection = RowSelection()
    }

    /// 우클릭한 PR 로 다룰 PR 들 — 같이 고른 것 안이면 고른 것 전부(목록 순서), 밖이면 그것 하나.
    func listTargets(for pr: PullRequestInfo) -> [PullRequestInfo] {
        let shown = visiblePRs
        let ids = Set(listSelection.targets(for: pr.id, in: shown.map(\.id)))
        let chosen = shown.filter { ids.contains($0.id) }
        return chosen.isEmpty ? [pr] : chosen
    }

    // MARK: - 한꺼번에 리뷰

    /// 우클릭 "diff 리뷰 / 전체 리뷰". 하나면 지금 흐름(reviewNow), 열린 것이 둘 이상이면 묶음 확인 창을 띄운다.
    func reviewFromList(_ pr: PullRequestInfo, deep: Bool) {
        let targets = listTargets(for: pr)
        let open = targets.filter(\.isOpen)
        guard open.count > 1 else {
            // 닫힌 것을 빼고 하나만 남으면 그 하나를, 하나도 안 남으면 누른 것으로 — reviewNow 가 "닫힌 PR" 을 알린다.
            reviewNow(pr: open.first ?? pr, deep: deep)
            return
        }
        pendingBatchReview = PendingBatchReview(prs: open, deep: deep, closedCount: targets.count - open.count)
    }

    /// 묶음 창이 PR 하나를 잰다. diff 를 아직 안 받았으면 받는다(받는 중이면 기다린다, 10초까지).
    func batchCheck(for pr: PullRequestInfo) async -> BatchReviewCheck {
        guard let diff = await waitForDiff(for: pr) else {
            return BatchReviewCheck(lines: pr.changedLines, skippable: [], measured: false)
        }
        // 데모 diff 는 작아서 큰 파일 모양을 볼 수 없다 — 디버그 값이 있으면 한 개일 때 창처럼 기준을 낮춘다(DebugLaunch).
        let skippable = DebugLaunch.skipSheetMinLines.map { minLines in
            diff.files.filter { !$0.isBinary && !$0.isDeleted && $0.changedLines >= minLines }
        } ?? SkippableFiles.find(in: diff)
        return BatchReviewCheck(lines: diff.changedLines, skippable: skippable, measured: true)
    }

    /// 묶음 창에서 "N개 리뷰 시작" 을 누른 뒤. 고른 순서(목록 위에서 아래)대로 큐 맨 앞에 넣는다 — 한 번에 하나씩 돈다.
    ///
    /// - Parameters:
    ///   - chosen: 창에서 체크를 남긴 PR.
    ///   - skipLargeFiles: 1,000줄 넘게 바뀐 파일을 이번 리뷰에서 뺀다(한 개일 때의 "빼고 리뷰").
    ///   - remember: 그 파일들을 제외 규칙에도 넣어 다음부터 묻지 않는다.
    func confirmBatchReview(_ request: PendingBatchReview, chosen: [PullRequestInfo],
                            checks: [String: BatchReviewCheck], skipLargeFiles: Bool, remember: Bool) {
        pendingBatchReview = nil
        guard !chosen.isEmpty else { return }
        if request.deep {
            // 사라진 폴더의 연결은 거둔다 — 한 개일 때 스냅샷 확인 창과 같다(confirmPendingSnapshotClone).
            var changed = false
            for repo in Set(chosen.map(\.repo)) {
                if case .needsSnapshot(let missing?) = reviewSource(for: repo),
                   settings.deepReviewRepoPaths[repo.full] == missing {
                    settings.deepReviewRepoPaths[repo.full] = nil
                    Log.info("사라진 클론 폴더 연결을 거둠 \(repo.full): \(missing)", "snapshot")
                    changed = true
                }
            }
            if changed { Task { await save() } }
        }
        if skipLargeFiles, remember {
            let rules = Set(chosen.flatMap { checks[$0.id]?.skippable ?? [] }.map { ExclusionPattern.file($0.path) })
            for rule in rules.sorted() { addExclusion(rule) }
        }
        // 맨 앞에 하나씩 넣으면 순서가 뒤집힌다(enqueue 는 첫 대기 잡 앞에 넣는다) — 거꾸로 넣어 목록 순서를 지킨다.
        for pr in chosen.reversed() {
            let choice = reviewModelChoice(for: pr)
            let skip = skipLargeFiles ? (checks[pr.id]?.skippable ?? []).map { ExclusionPattern.file($0.path) } : []
            enqueue(pr: pr, trigger: .manual, front: true,
                    modelOverride: choice.model, effortOverride: choice.effort, deep: request.deep, skipPaths: skip)
        }
        Log.info("한꺼번에 리뷰 \(chosen.count)개\(request.deep ? " (전체 리뷰)" : "")"
                 + (skipLargeFiles ? " · 큰 파일 빼고" : "") + ": " + chosen.map { "#\($0.number)" }.joined(separator: " "),
                 "queue")
        banner = Banner(kind: .info,
                        message: "PR \(chosen.count)개를 리뷰 큐에 넣었습니다 — 하나씩 차례로 돕니다."
                            + (skipLargeFiles && remember ? " 큰 파일은 다음부터 묻지 않고 뺍니다(설정 › 대상 제외)." : ""))
    }

    func cancelPendingBatchReview() {
        pendingBatchReview = nil
    }
}

extension RowSelection.Modifier {
    /// 지금 처리 중인 클릭에 눌려 있던 키. ⌘ 가 ⇧ 보다 앞선다(둘 다 누르면 하나씩 더하기).
    @MainActor static var current: Self {
        let flags = NSApp.currentEvent?.modifierFlags ?? []
        if flags.contains(.command) { return .command }
        if flags.contains(.shift) { return .shift }
        return .none
    }
}
