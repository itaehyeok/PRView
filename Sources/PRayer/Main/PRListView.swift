import SwiftUI
import PRayerCore

struct PRListView: View {
    @Environment(AppModel.self) private var model
    /// 목록이 방향키를 받는가. 행을 누르거나 검색칸에서 ↓ 를 누르면 목록으로 온다.
    @FocusState private var listFocused: Bool
    @FocusState private var searchFocused: Bool
    @AppStorage(MyPRSection.collapsedKey) private var myPRCollapsed = false

    var body: some View {
        @Bindable var model = model
        VStack(spacing: 0) {
            // 레포 탭은 툴바 아래 창 너비 줄로 옮겼다(RepoStrip) — 목록 폭 안에서는 레포 둘만 있어도 넘쳤다.
            scopeTabs
            Divider()
            searchField
            Divider()
            // 건수·갱신 시각·새로고침. 받을 레포가 없으면 셀 것도 받을 것도 없다.
            if !model.settings.enabledRepos.isEmpty {
                ListHeader()
            }
            // 여럿 고른 것은 우클릭해야 쓸 수 있다 — 메뉴는 눈에 안 보이니 고른 사실과 할 일을 목록 위가 말한다.
            // 탭·필터를 바꿔 고른 것이 안 보이게 되면 띠도 내린다(우클릭도 보이는 것만 다룬다 — listTargets).
            let chosenCount = model.listSelection.isMultiple
                ? model.visiblePRs.filter { model.listSelection.ids.contains($0.id) }.count : 0
            if chosenCount > 1 {
                selectionBar(count: chosenCount)
                Divider()
            }
            ScrollViewReader { proxy in
                ScrollView {
                    // 지연 스택(LazyVStack)을 쓰지 않는다 — Approve 칩이 날고 행이 빠지는 사이에 배치가 끝나지 않아 앱이
                    // 멈췄다(2026-10-30 실측, 0.6.2: CPU 100%, 메인 스레드가 `GraphHost.flushTransactions` 안에서
                    // `AllItemsPhaseMutation` → 배치 → `LazyLayoutViewCache.signalPrefetch` 를 끝없이 되풀이). 변경 파일 탭이
                    // 겪은 것과 같은 순환이다(DiffView `rowPageSize` 주석). 행 높이가 활동 목록 유무·제목 줄 수로 크게 달라
                    // 지연 스택의 높이 추정이 배치마다 바뀌는데, 그 사이 행이 애니메이션으로 빠지며 아래 행 자리가 매 프레임
                    // 바뀌었다. 목록은 많아야 탭 하나에 수십 건 + 검색 아래 구역 50건이라 다 그려도 된다.
                    VStack(spacing: 2) {
                        // 내가 올린 것은 맨 위에 따로 묶는다(MyPRSection 주석 참고).
                        MyPRSection(onRowTap: { listFocused = true })
                        ForEach(model.visiblePRs) { pr in
                            PRRow(pr: pr)
                                .padding(.horizontal, 10)
                                .padding(.vertical, 6)
                                .background(rowBackground(pr))
                                // 방금 새로 들어온 행은 옅은 바탕이 잠깐 남는다(AppModel.freshPRs). 고른 행의 바탕 뒤에 깐다.
                                .background {
                                    if model.freshPRs.contains(pr.id) {
                                        RoundedRectangle(cornerRadius: 6)
                                            .fill(Color.accentColor.opacity(0.09))
                                            .transition(.opacity)
                                    }
                                }
                                .overlay(alignment: .leading) {
                                    if isMarked(pr) {
                                        RoundedRectangle(cornerRadius: 1.5)
                                            .fill(Color.accentColor)
                                            .frame(width: 3)
                                            .padding(.vertical, 4)
                                    } else if pr.viewerReviewedWithoutApproval {
                                        RoundedRectangle(cornerRadius: 1.5)
                                            .fill(Color.orange)
                                            .frame(width: 3)
                                            .padding(.vertical, 4)
                                    }
                                }
                                // 처리를 마쳐 곧 빠지는 행은 남은 시간에 걸쳐 흐려진다.
                                // `background`·선택 막대까지 같이 옅어지도록 그 **뒤**에 건다.
                                .leavingFade(deadline: model.leavingDeadline(for: pr))
                                // Approve 칩이 이 행에서 떠나면 행은 바로 감춘다 — 칩이 행에서 빠져나온 것처럼 보이게.
                                .opacity(model.hasLaunchedFlight(pr) ? 0 : 1)
                                .animation(.easeOut(duration: 0.16), value: model.hasLaunchedFlight(pr))
                                .contentShape(Rectangle())
                                // ⌘·⇧ 클릭으로 여러 개를 고른다 — 같이 고른 것을 우클릭해 한꺼번에 리뷰한다.
                                .onTapGesture {
                                    listFocused = true
                                    model.clickListPR(pr)
                                }
                                .contextMenu { menu(for: pr) }
                                .padding(.horizontal, 6)
                                .listRowTransition()
                                .id(pr.id)
                        }
                        // 목록이 비어 있는 채로 받는 중이면 행이 들어올 자리에 빈 행을 깐다(사용자 선택 2026-10-28, 시안 C
                        // "빈 행 자리"). 지난 목록을 다시 받는 동안은 머리 줄(ListHeader)이, 뒤 페이지를 이어 받는 동안은
                        // 맨 아래 줄(ListFooter)이 말한다.
                        if let continuing = loadingSkeleton {
                            LoadingSkeleton(
                                title: "‘\(model.listScope.label)’ \(continuing ? "이어서 " : "")가져오는 중",
                                detail: continuing
                                    ? PRListScope.continuingDescription(hiddenByFilters: model.emptyDiagnosis.allOffCount > 0)
                                    : model.listScope.fetchingDescription)
                        } else if !model.visiblePRs.isEmpty {
                            // 맨 아래 줄("이어서 가져오는 중")은 마지막 행 바로 밑에 와야 목록이 이어지는 것으로
                            // 읽힌다 — 필터 안내가 사이에 끼면 목록과 따로 논다(사용자 지적 2026-10-29). 둘을 한 덩어리로
                            // 둔다 — 따로 두면 행이 펼쳐지는 동안 각자 다른 자리에서 미끄러져 와 잠깐 위아래가 뒤바뀌어 보였다.
                            VStack(spacing: 0) {
                                ListFooter()
                                hiddenByFilterNote
                            }
                        }
                        if showsExtraSearch {
                            extraSearchSection
                        }
                    }
                    .padding(.vertical, 6)
                }
                // ↑↓ 로 PR 을 옮기고 ⇧ 로 같이 고른다 — 클릭과 같은 규칙(RowSelection). 리뷰 대기를 차례로 훑을 때
                // 마우스로 행을 하나씩 찾아 누르지 않게. 행을 누르면 목록이 키를 받는다(누르기만으로는 초점이 안 온다).
                .focusable()
                .focused($listFocused)
                .focusEffectDisabled()
                .onKeyPress(keys: [.upArrow, .downArrow]) { press in
                    let mine = MyPRSection.shown(model.myOpenPRs, collapsed: myPRCollapsed, showsAll: model.myPRShowsAll)
                    if let id = model.moveListCursor(by: press.key == .upArrow ? -1 : 1,
                                                     extend: press.modifiers.contains(.shift), mine: mine,
                                                     extra: showsExtraSearch ? model.extraSearchPRs : []) {
                        // 앵커를 주지 않으면 보일 만큼만 움직인다 — 화면 안에서 옮길 땐 목록이 가만히 있다.
                        proxy.scrollTo(id)
                    }
                    return .handled
                }
            }
        }
        .overlay {
            // 검색으로 아래 구역이 떠 있으면 위가 비어도 빈 화면을 덮지 않는다 — 위 구역 머리가 "… 에는 없음" 을 말한다.
            if model.visiblePRs.isEmpty, loadingSkeleton == nil, !showsExtraSearch {
                emptyState
            }
        }
        // Approve 한 PR 의 칩이 행에서 탭 줄의 Approved 탭으로 날아간다(ApprovalFlight). 탭 줄과 스크롤 목록을 함께 덮어야
        // 스크롤 가장자리에서 잘리지 않는다.
        .overlayPreferenceValue(ApprovalFlightAnchorsKey.self) { anchors in
            ApprovalFlightLayer(anchors: anchors)
        }
        .background {
            // ⌘F 로 검색칸에 간다. 메뉴 편집 › 찾기 의 ⌘F 는 글 칸에 있을 때만 켜지고, 꺼진 메뉴는 키를 가져가지
            // 않아서 겹치지 않는다(리뷰 본문을 고치는 중이면 그 글 안 찾기가 그대로 뜬다).
            Button("PR 검색") { searchFocused = true }
                .keyboardShortcut("f", modifiers: .command)
                .opacity(0)
                .frame(width: 0, height: 0)
                .accessibilityHidden(true)
        }
    }

    /// 보고 있는 PR 이거나 같이 고른 PR. 둘을 같은 모양으로 그린다 — "내가 올린 PR" 과 같다.
    private func isMarked(_ pr: PullRequestInfo) -> Bool {
        pr.id == model.selectedPRID || model.isInListSelection(pr)
    }

    private func selectionBar(count: Int) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.circle.fill")
                .font(.caption)
                .foregroundStyle(Color.accentColor)
            Text("PR \(count)개 고름 · 우클릭으로 한꺼번에 리뷰")
                .font(.caption)
                .foregroundStyle(Color.accentColor)
                .lineLimit(1)
            Spacer(minLength: 0)
            Button("선택 풀기") { model.clearListSelection() }
                .buttonStyle(.link)
                .font(.caption)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
        .background(Color.accentColor.opacity(0.08))
    }

    /// 행 우클릭 메뉴. 같이 고른 것 안에서 누르면 리뷰는 고른 것 전부에, 밖이면 그 PR 하나에 건다(`AppModel.listTargets`).
    /// 사람·라벨 숨기기는 누른 그 행의 것이다 — 이름이 메뉴에 그대로 나와 무엇을 숨기는지 헷갈리지 않는다.
    @ViewBuilder
    private func menu(for pr: PullRequestInfo) -> some View {
        let targets = model.listTargets(for: pr)
        let openCount = targets.filter(\.isOpen).count
        if targets.count > 1, openCount > 1 {
            // 여럿이면 묶음 확인 창이 한 번 묻는다(BatchReviewSheet) — 말줄임표가 "창이 하나 더 뜬다" 를 말한다.
            Button("전체 리뷰 \(openCount)개 (초안만 생성)…") { model.reviewFromList(pr, deep: true) }
            Button("diff 리뷰 \(openCount)개 (초안만 생성)…") { model.reviewFromList(pr, deep: false) }
            let active = targets.compactMap { model.job(for: $0) }.filter(\.isActive)
            if !active.isEmpty {
                Button("리뷰 취소 (\(active.count)개)") {
                    for job in active { model.cancel(jobID: job.id) }
                }
            }
            Button("선택 풀기") { model.clearListSelection() }
        } else {
            // 전체 리뷰를 앞에 둔다 — 더 꼼꼼한 쪽이다(머리 줄 버튼과 같은 순서).
            // 클론이 없어도 늘 된다 — 처음이면 PR 스냅샷을 받을지 먼저 묻는다.
            // 같이 고른 것 중 열린 것이 하나뿐이면 그 하나를 리뷰한다(reviewFromList).
            Button("전체 리뷰 (초안만 생성)") { model.reviewFromList(pr, deep: true) }
            Button("diff 리뷰 (초안만 생성)") { model.reviewFromList(pr, deep: false) }
            if let job = model.job(for: pr), job.isActive {
                Button("리뷰 취소") { model.cancel(jobID: job.id) }
            }
        }
        Divider()
        // "이 사람 것은 안 봐도 되는데" 하는 생각이 드는 자리가 여기다.
        Button(model.settings.isIgnoredAuthor(pr.author)
               ? "\(model.settings.displayName(pr.author)) 다시 보기"
               : "\(model.settings.displayName(pr.author)) 의 PR 안 보기") {
            model.toggleIgnoredAuthor(pr.author)
        }
        // 라벨도 같은 자리에서 고른다. 안 볼 라벨(다른 파트·WIP·보류 등)은 팀마다 다르다.
        if !pr.labels.isEmpty {
            Menu("라벨로 숨기기") {
                ForEach(pr.labels, id: \.self) { label in
                    // 메뉴도 라벨은 태그 아이콘으로(PRLabels). 체크 표시는 메뉴가 그린다.
                    Toggle(isOn: Binding(
                        get: { model.settings.isHiddenLabel(label) },
                        set: { _ in model.toggleHiddenLabel(label) })) {
                        Label(label, systemImage: "tag")
                    }
                }
            }
        }
        Divider()
        Button {
            if let url = pr.htmlURL(host: model.settings.githubHost) { NSWorkspace.shared.open(url) }
        } label: {
            // 메뉴는 뷰를 그리지 않고 이미지만 받는다 — 로고는 에셋 이미지를 바로 넣는다.
            Label { Text(GitHubLink.title) } icon: { Image("GitHubMark") }
        }
    }

    /// 목록이 비어 있는 채로 이 탭의 결과를 받는 중이면 행이 들어올 자리에 빈 행을 깐다(nil 이면 안 깐다). 값은
    /// 이어 받는 중인가 — 받은 것이 다 걸러졌는데 뒤 페이지가 남았다. 이때 "없습니다" 로 단정하면 조금 뒤 목록이
    /// 채워지며 거짓이 된다.
    ///
    /// 받은 지 얼마 안 된 탭·2분마다 다시 받을 때는 깔지 않는다(`isShowingCachedList` 가 거짓) — 이미 받은 "없습니다" 가
    /// 그때마다 빈 행으로 깜빡이면 안 된다. 레포가 하나도 없으면 받을 것이 없다.
    private var loadingSkeleton: Bool? {
        guard !model.settings.enabledRepos.isEmpty, model.visiblePRs.isEmpty else { return nil }
        if model.isRefreshing, model.isShowingCachedList { return false }
        if !model.prs.isEmpty, model.isLoadingMore { return true }
        return nil
    }

    /// 필터로 숨은 PR 이 있으면 몇 건인지, 어느 레포인지 알려 준다.
    /// 레포를 새로 추가했는데 아무것도 안 보이면 원인을 알 수 없어서 넣었다.
    @ViewBuilder
    private var hiddenByFilterNote: some View {
        // 레포 탭에서 뺀 레포의 PR 은 세지 않는다. 그건 위 레포 탭이 이미 보여 주고, 여기 섞으면
        // "필터 완화해서 보기" 를 눌러도(라벨·사람만 푼다) 숫자가 그대로 남는다.
        // 차례를 기다리는 새 행·떠나는 중인 머지된 행은 숨긴 것도 보이는 것도 아니다(AppModel.applyFetched) — 세면
        // 연출하는 1~2초 동안 숫자가 흔들린다.
        let pool = model.prs.filter { model.isRepoShown($0.repo) && !model.heldBackArrivals.contains($0.id) }
        let hidden = pool.count - (model.visiblePRs.count - model.departingRows.count)
        // 목록이 비면 가운데 빈 화면이 같은 숫자를 레포별로 이미 말한다. 둘 다 띄우면
        // 한 화면에 같은 내용이 두 벌 있게 된다(실측: 상단 띠와 "레포별 숨김" 이 동일).
        if hidden > 0, model.listScope.kind == .open, !model.visiblePRs.isEmpty {
            let byRepo = Dictionary(grouping: pool.filter { pr in
                !model.visiblePRs.contains { $0.id == pr.id }
            }, by: { $0.repo.name })
            VStack(alignment: .leading, spacing: 3) {
                // 아직 받는 중이면 이 숫자는 최종이 아니다. 단정하면 스크롤하는 동안 혼자 늘어난다.
                Text("필터로 \(hidden)건\(model.isLoadingMore ? "+" : "") 숨김 — "
                     + byRepo.map { "\($0.key) \($0.value.count)건" }.sorted().joined(separator: " · ")
                     + (model.isLoadingMore ? " · 더 받는 중" : ""))
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Button("필터 완화해서 보기") {
                    model.filter.hideIgnoredAuthors = false
                    model.filter.hideLabels = false
                }
                .buttonStyle(.link)
                .font(.caption2)
            }
            .padding(.horizontal, 16)
            .padding(.top, 2)
            .padding(.bottom, 10)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    // MARK: - 검색: 지금 탭 / 그 밖

    /// 검색어가 있을 때 목록 아래에 지금 탭 밖 구역을 붙이는가(AppModel+Search). 위 구역(지금 탭)의 이름과 건수는 목록
    /// 머리 줄(ListHeader — "To review 3건")이 이미 말해서 따로 머리를 달지 않는다 — 시안에는 있었지만 바로 아래에 같은 말이
    /// 두 번 나왔다. 아래까지 다 찾았는데 둘 다 비면 붙이지 않는다 — 지금의 빈 화면("검색어 지우기")이 그대로 뜬다.
    private var showsExtraSearch: Bool {
        guard model.extraSearchPlan != nil else { return false }
        if !model.searchTopPRs.isEmpty || loadingSkeleton != nil { return true }
        switch model.extraSearch.phase {
        case .searching, .failed, .rateLimited:
            return true
        case .idle, .done:
            return !model.extraSearchPRs.isEmpty
        }
    }

    /// 아래 구역 — 머리 줄, 행, 찾는 동안의 빈 행 자리, 다음 50건 받기.
    /// 행 모양은 위와 같다. 다만 같이 고르기·Approve 칩 연출은 탭 목록의 것이라 여기는 고른 표시만 둔다.
    @ViewBuilder
    private var extraSearchSection: some View {
        let search = model.extraSearch
        let rows = model.extraSearchPRs
        extraSearchHeader(search: search, count: rows.count,
                          name: PRSearchPlan.extraName(scope: model.listScope))
            .padding(.top, 8)
        ForEach(rows) { pr in
            PRRow(pr: pr)
                .padding(.horizontal, 10)
                .padding(.vertical, 6)
                .background(rowBackground(pr))
                .overlay(alignment: .leading) {
                    if isMarked(pr) {
                        RoundedRectangle(cornerRadius: 1.5)
                            .fill(Color.accentColor)
                            .frame(width: 3)
                            .padding(.vertical, 4)
                    }
                }
                .contentShape(Rectangle())
                .onTapGesture {
                    listFocused = true
                    model.clickExtraSearchPR(pr)
                }
                .contextMenu { menu(for: pr) }
                .padding(.horizontal, 6)
                .id(pr.id)
        }
        if search.phase == .searching {
            // 받아 둔 목록에서 찾은 것은 위에 바로 있고, 서버 결과가 올 자리를 빈 행으로 잡아 둔다.
            ForEach(0..<2, id: \.self) { index in
                SkeletonRow(delay: Double(index) * 0.12)
            }
        } else if search.phase == .done, search.hasNextPage {
            extraSearchMore(search)
        }
    }

    @ViewBuilder
    private func extraSearchHeader(search: ExtraSearchState, count: Int, name: String) -> some View {
        switch search.phase {
        case .searching:
            SearchSectionHeader(spinning: true, text: "\(name) 에서 찾는 중…")
        case .failed(let message):
            SearchSectionHeader(systemImage: "exclamationmark.triangle", text: "\(name) 검색 실패") {
                Button("다시 시도") { model.retryExtraSearch() }
                    .buttonStyle(.link)
            }
            .help(message)
        case .rateLimited:
            SearchSectionHeader(systemImage: "hourglass", text: "GitHub 검색 한도에 걸렸습니다") {
                Button("다시 시도") { model.retryExtraSearch() }
                    .buttonStyle(.link)
            }
        case .idle, .done:
            let older = model.listScope.kind == .recentAll
            SearchSectionHeader(systemImage: older ? "clock.arrow.circlepath" : "globe",
                                text: count > 0 ? "\(name) 에서 \(count)건 더" : "\(name) 에는 없음") {
                // All PRs 는 이름("30일 이전 PR")이 범위를 말한다.
                if !older {
                    Text("기간 제한 없음")
                        .foregroundStyle(.tertiary)
                }
            }
        }
    }

    /// 단어 검색이 50건보다 많으면 사용자가 누를 때만 다음 페이지를 받는다 — 흔한 단어는 수백 건이다.
    private func extraSearchMore(_ search: ExtraSearchState) -> some View {
        HStack(spacing: 8) {
            if search.isLoadingMore {
                ProgressView()
                    .controlSize(.mini)
                Text("더 받는 중…")
            } else {
                Button("다음 \(AppModel.extraSearchBatch)건 받기") { model.loadMoreExtraSearch() }
                    .buttonStyle(.link)
            }
            if let total = search.wordsTotal {
                Text("검색 결과 \(total)건 중 \(search.wordsReceived)건 받음")
                    .foregroundStyle(.tertiary)
            }
        }
        .font(.caption)
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
    }

    /// 선택 표시를 List 기본값(전체를 파랗게 칠하고 글자를 흰색으로)에 맡기면
    /// 뱃지·+/-·활동 아이콘 색이 전부 죽는다. 옅은 배경 + 왼쪽 막대로 바꾼다.
    private func rowBackground(_ pr: PullRequestInfo) -> some View {
        RoundedRectangle(cornerRadius: 6)
            .fill(isMarked(pr)
                  ? Color.accentColor.opacity(0.13)
                  // 리뷰했지만 승인 전인 PR 은 옅게 칠해 눈에 띄게 둔다.
                  : (pr.viewerReviewedWithoutApproval ? Color.orange.opacity(0.07) : Color.clear))
            .overlay {
                RoundedRectangle(cornerRadius: 6)
                    .stroke(isMarked(pr) ? Color.accentColor.opacity(0.35) : .clear,
                            lineWidth: 1)
            }
    }

    /// 목록을 무엇으로 채울지 고르는 탭.
    ///
    /// 기간이 있는 탭은 몸통과 화살표가 나뉜다 — 몸통을 누르면 그 탭으로만 옮겨 가고(기간은
    /// 그 탭이 기억하던 값), 화살표를 눌러야 기간 목록이 열린다. 탭을 옮기려다 기간 메뉴가
    /// 열리는 일이 없게 하려고 이렇게 나눴다.
    private var scopeTabs: some View {
        HStack(spacing: 4) {
            ForEach(PRListScopeKind.allCases) { kind in
                ScopeTab(kind: kind)
            }
            Spacer(minLength: 0)
        }
        .padding(.horizontal, 8)
        .padding(.top, 8)
        .padding(.bottom, 6)
    }

    private var searchField: some View {
        @Bindable var model = model
        // 접기 버튼은 여기 있었는데 툴바로 옮겼다. 패널 안에 두면 펼쳤을 때와 접었을 때
        // 버튼이 서로 다른 자리에 나타나서(패널 안 ↔ 툴바), 같은 버튼을 매번 다시 찾게 된다.
        return HStack(spacing: 6) {
            Image(systemName: "magnifyingglass")
                .font(.caption)
                .foregroundStyle(.secondary)
            TextField("번호·제목·작성자·브랜치", text: $model.filter.search)
                .textFieldStyle(.plain)
                .font(model.fonts.ui(delta: -1))
                .focused($searchFocused)
                // 걸러 놓고 ↓ 로 바로 목록에 내려가 고른다.
                .onKeyPress(.downArrow) {
                    listFocused = true
                    return .handled
                }
                .help("⌘F")
            if !model.filter.search.isEmpty {
                Button {
                    model.filter.search = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .foregroundStyle(.tertiary)
                }
                .buttonStyle(.plain)
            }
            FilterButton()
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
    }

    @ViewBuilder
    private var emptyState: some View {
        // 꺼 둔 레포만 남아 있어도 받을 것이 없다 — 체크를 끄면 목록에서 지우지 않고 멈추기만 한다.
        if model.settings.enabledRepos.isEmpty {
            ContentUnavailableView {
                Label("리뷰할 레포가 없습니다", systemImage: "shippingbox")
            } description: {
                Text("위쪽 레포 줄 끝의 ⚙︎ 에서 레포를 찾아 체크하면 열린 PR 을 가져옵니다.")
            } actions: {
                SettingsLink { Text("레포 추가…") }
            }
        } else if model.prs.isEmpty {
            // 받는 중이면 여기 오지 않는다 — 목록 자리에 빈 행이 깔린다(loadingSkeleton).
            if model.consecutiveRefreshFailures > 0 {
                refreshFailedState
            } else {
                nothingFetchedState
            }
        } else {
            let diagnosis = model.emptyDiagnosis
            if diagnosis.allOffCount == 0 {
                // 필터를 다 풀어도 안 나온다. "필터를 풀어 보세요" 는 거짓말이 된다.
                scopeEmptyState
            } else if diagnosis.searchIsOnlyBlocker {
                searchOnlyState(diagnosis)
            } else {
                filteredOutState(diagnosis)
            }
        }
    }

    /// 목록이 빈 네 경우가 **공통으로** 쓰는 제목.
    ///
    /// 탭·필터·검색어를 "조건" 한 단어로 덮는다. 왜 비었는지는 아래 설명 줄이 말한다.
    /// 예전에는 경우마다 제목이 달라서, 같은 빈 화면인데 매번 다른 문장을 읽어야 했다.
    /// 특히 "필터에 걸려 12건이 숨어 있습니다" 는 **필터를 문제로** 읽히게 했는데,
    /// 기본 설정에서 목록이 비는 가장 흔한 이유는 내 몫을 다 끝냈기 때문이다.
    static let emptyTitle = "조건에 맞는 PR 이 없습니다"

    /// ① 받은 PR 이 있는데 전부 필터에 걸린 경우 — 어느 필터가 몇 건을 숨기는지 그대로 보여 준다.
    private func filteredOutState(_ diagnosis: EmptyListDiagnosis) -> some View {
        ContentUnavailableView {
            Label(Self.emptyTitle, systemImage: "line.3.horizontal.decrease.circle")
        } description: {
            // 끄면 아무것도 안 나오는 필터는 아예 빼고, 실제로 뭔가 나오는 것만 남긴다.
            // 예전에는 "끄면 0건" 줄이 버튼도 없이 자리만 차지했다 — 읽어도 할 일이 없는 줄이다.
            // (그 줄들이 왜 0 인지는 아래 "겹쳐 걸린 PR" 안내가 말한다.)
            let actionable = diagnosis.gains.filter { $0.gain > 0 }
            VStack(spacing: 10) {
                Text("필터로 \(diagnosis.hiddenCount)건이 숨어 있습니다")
                VStack(spacing: 4) {
                    ForEach(actionable, id: \.kind) { entry in
                        HStack(spacing: 8) {
                            Text(entry.kind.label)
                                .font(.callout)
                            Spacer(minLength: 12)
                            Text("끄면 +\(entry.gain)건")
                                .font(.caption.monospacedDigit())
                            Button("끄기") { model.turnOff(entry.kind) }
                                .controlSize(.small)
                        }
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .background(.quinary.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
                    }
                }
                .frame(maxWidth: 420)

                if diagnosis.hasOverlap, !actionable.isEmpty {
                    Text("겹쳐 걸린 PR 이 있어 각 줄의 합과 아래 건수가 다릅니다.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                } else if actionable.isEmpty {
                    // 필터마다 하나만 꺼서는 아무것도 안 나온다 — 전부 두 개 이상에 걸려 있다.
                    // 줄이 하나도 없는데 "각 줄의 합" 을 말하면 무슨 줄인지 알 수 없다.
                    Text("한 개만 꺼서는 나오지 않습니다 — 모든 PR 이 필터 두 개 이상에 걸려 있습니다.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
                if !diagnosis.byRepo.isEmpty {
                    Text("레포별 숨김: " + diagnosis.byRepo
                            .map { "\($0.name) \($0.count)건" }.joined(separator: " · "))
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
        } actions: {
            HStack(spacing: 8) {
                Button("필터 모두 끄기") { model.turnOffAllFilters() }
                    .buttonStyle(.borderedProminent)
                Text("\(diagnosis.allOffCount)건 보기")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// ② 검색어만 원인인 경우.
    private func searchOnlyState(_ diagnosis: EmptyListDiagnosis) -> some View {
        let activeFilters = model.filterState.active(in: model.listScope).filter { $0 != .search }.count
        return ContentUnavailableView {
            Label(Self.emptyTitle, systemImage: "magnifyingglass")
        } description: {
            VStack(spacing: 6) {
                Text("\"\(model.filter.search)\" 에 맞는 PR 이 없습니다 — 지우면 \(diagnosis.searchGain)건을 볼 수 있습니다.")
                if activeFilters > 0 {
                    Text("필터도 \(activeFilters)개 켜져 있습니다 — 모두 지우면 \(diagnosis.allOffCount)건")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
        } actions: {
            HStack(spacing: 8) {
                Button("검색어 지우기") { model.filter.search = "" }
                    .buttonStyle(.borderedProminent)
                if activeFilters > 0 {
                    Button("필터도 모두 끄기") { model.turnOffAllFilters() }
                }
            }
        }
    }

    /// ③④ 필터를 풀어도 안 나오는 경우 — 탭을 바꾸도록 안내한다.
    private var scopeEmptyState: some View {
        ContentUnavailableView {
            Label(Self.emptyTitle, systemImage: "checkmark.circle")
        } description: {
            Text(model.listScope.emptyDescription(receivedAny: true))
        } actions: {
            if let next = widerScope {
                Button("\(next.label) 보기") { model.listScope = next }
            }
        }
    }

    /// ③ 아무것도 받지 못한 경우(열린 PR 자체가 없음).
    private var nothingFetchedState: some View {
        ContentUnavailableView {
            Label(Self.emptyTitle, systemImage: "checkmark.circle")
        } description: {
            Text(model.listScope.emptyDescription(receivedAny: false))
        } actions: {
            if let next = widerScope {
                Button("\(next.label) 보기") { model.listScope = next }
            }
        }
    }

    /// ⑤ 갱신 실패로 비어 있는 경우 — 필터 탓으로 오해하지 않게 원인을 적는다.
    private var refreshFailedState: some View {
        ContentUnavailableView {
            Label("PR 목록을 아직 받지 못했습니다", systemImage: "exclamationmark.triangle")
        } description: {
            VStack(spacing: 4) {
                Text("GitHub 호출이 \(model.consecutiveRefreshFailures)회 연속 실패했습니다 — \(model.githubError ?? "원인 불명")")
                    .fixedSize(horizontal: false, vertical: true)
                Text("잠시 뒤 자동으로 다시 시도합니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        } actions: {
            HStack(spacing: 8) {
                Button("지금 새로고침") { Task { await model.refreshByUser() } }
                    .buttonStyle(.borderedProminent)
                Button("로그 열기") { model.openLogFile() }
            }
        }
    }

    /// 더 넓게 볼 수 있는 다음 탭. 기간을 한 칸 늘리고, 더 늘릴 수 없으면 종류를 넓힌다.
    private var widerScope: PRListScope? {
        let scope = model.listScope
        switch scope.kind {
        case .open:
            return .recentAll(model.window(for: .recentAll))
        case .myApprovals:
            // 가장 긴 기간이면 버튼을 내지 않는다(시안 결정). 설명도 "늘려 보세요" 를 말하지 않는다.
            guard let longer = scope.window?.longer else { return nil }
            return .myApprovals(longer)
        case .recentAll:
            guard let longer = scope.window?.longer else { return nil }
            return .recentAll(longer)
        }
    }

}

extension VerticalAlignment {
    /// 목록 행의 상태 칩 줄 + 제목 덩어리 가운데 — 왼쪽 아바타를 여기에 맞춘다(PRRow).
    /// 덩어리가 따로 정하지 않은 자리(다른 행 조각)는 위쪽을 쓴다.
    private enum PRTitleLine: AlignmentID {
        static func defaultValue(in context: ViewDimensions) -> CGFloat { context[.top] }
    }

    static let prTitleLine = VerticalAlignment(PRTitleLine.self)
}

struct PRRow: View {
    @Environment(AppModel.self) private var model
    /// 목록이 좁아지면 덜 중요한 조각을 뺀다.
    @Environment(\.prRowDensity) private var density
    let pr: PullRequestInfo

    var body: some View {
        let badge = model.badge(for: pr)
        // 작성자 아바타를 행의 첫 요소로 둔다 — 이름을 읽지 않아도 색과 머리글자로 잡히게.
        // 높이는 **상태 칩 줄 + 제목을 합친 덩어리의 가운데**에 맞춘다(사용자 결정, 2026-10-20).
        // 제목 첫 줄에만 맞췄을 때는 아바타가 제목 쪽에 붙어 칩 줄이 따로 떠 보였다.
        // 행 세로 중앙은 안 된다 — 활동 목록을 펼치면 행이 길어져서 아바타가 제목에서 떨어져 허공에 뜬다.
        // (셋째 줄 이름 앞으로 옮기고 "by" 를 빼 봤는데 별로라 되돌렸다. 칩 줄을 아바타 열까지 왼쪽으로
        // 넓히는 안도 시안만 보고 접었다 — 사용자 결정)
        HStack(alignment: .prTitleLine, spacing: 8) {
            Avatar(login: pr.author, name: model.settings.displayName(pr.author), size: 22)
                .alignmentGuide(.prTitleLine) { $0[VerticalAlignment.center] }
                .help("작성자 \(pr.author)")
            VStack(alignment: .leading, spacing: 5) {
            // 첫 줄은 상태 칩 · 번호 · 시각만, 제목은 그 아래 혼자 한 줄(넘치면 두 줄)이다(사용자 결정).
            // 예전에는 한 줄에 칩·번호·제목·시각을 다 넣어서, 좁은 목록에서 제목이 폭의 1/3 도 못 받고
            // `[PROJ-1234][...` 처럼 꼬리표만 보이다 잘렸다.
            // 칩 줄과 제목을 한 덩어리로 묶어, 그 가운데를 아바타 정렬 기준(prTitleLine)으로 내보낸다.
            VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 6) {
                // PR 스냅샷을 처음 받는 동안은 Reviewing 대신 "클론 45%" — 왜 오래 걸리는지 목록에서도 보이게.
                if let fraction = model.job(for: pr)?.cloneFraction {
                    CloneProgressChip(fraction: fraction)
                } else {
                    let isFlightSource = model.isFlightSource(pr)
                    BadgeChip(result: badge)
                        // Approve 칩은 이 배지 자리에서 뜬다(ApprovalFlight). 날 차례인 행만 적는다.
                        .anchorPreference(key: ApprovalFlightAnchorsKey.self, value: .bounds) { anchor in
                            isFlightSource ? ApprovalFlightAnchors(sources: [pr.id: anchor]) : ApprovalFlightAnchors()
                        }
                }
                // 자릿수 구분자가 붙지 않게 verbatim(PRDetailView 주석 참고).
                Text(verbatim: "#\(pr.number)")
                    .font(.caption.monospacedDigit())
                    .foregroundStyle(.secondary)
                Spacer(minLength: 4)
                // 마지막 활동 시각은 따로 찍지 않는다 — 아래 Recent activity 첫 줄이 곧 그 시각이다.
                if density.showsCreatedAt {
                    // "최근 승인" 탭은 승인 시각으로 거른다. 그 탭에서 PR 올린 시각을 보여 주면
                    // 거르는 기준과 보이는 값이 달라 "24h 탭인데 1d ago" 로 읽힌다(실측).
                    let approvedAt = model.listScope.requiresMyApproval ? model.viewerApprovedAt(pr) : nil
                    RelativeTimeText(date: approvedAt ?? pr.createdAt,
                                     style: .ago,
                                     prefix: approvedAt == nil ? "Created" : "내가 Approve")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .fixedSize(horizontal: true, vertical: false)
                }
                // 처리를 마쳐 곧 빠지는 PR. 사라질 때까지 줄어드는 고리를 보여 준다.
                if let deadline = model.leavingDeadline(for: pr) {
                    RemovalCountdown(deadline: deadline, total: AppModel.removalGrace)
                }
            }
            // 두 줄에서 자른다 — 세 줄째부터는 행이 너무 길어지고, 앞 두 줄이면 무슨 PR 인지는 알 수 있다.
            // 글자는 UI 기본보다 한 단계 작게 — 제목이 혼자 한 줄을 차지하면서 기본 크기로는 행에서 너무 컸다(사용자).
            // 설정의 UI 글자 크기를 따라가도록 고정값이 아니라 차이로 준다.
            Text(pr.title)
                .font(model.fonts.ui(delta: -1))
                .lineLimit(2)
                .fixedSize(horizontal: false, vertical: true)
                .help(pr.title)
            }
            .alignmentGuide(.prTitleLine) { $0[VerticalAlignment.center] }
            // 셋째 줄: 누가·얼마나·승인, 그리고 PR 이 어떻게 됐나(상태 태그) │ 사람이 붙인 분류(라벨).
            // 다 들어가면 한 줄, 안 들어가면 "상태 태그 │ 라벨" 을 아랫줄 한 줄로, 그래도 안 들어가면 상태 태그와
            // 라벨을 한 줄씩(라벨이 길면 두 줄까지) 내린다 — 잘리지 않게, 세 줄까지는 괜찮다(사용자 결정).
            // 예전에는 한 줄에 몰아넣어 좁은 목록에서 `Co…`·`Re…` 처럼 잘렸고, 라벨은 폭에 따라 아예 뺐다.
            // 어느 배치로 놓을지는 PRRowFactsLayout 이 폭만 보고 고른다(그 주석 참고 — ViewThatFits 를 쓰지 않는 이유).
            PRRowFactsLayout {
                HStack(spacing: PRRowFactsLayout.gap) { whoAndSize }
                    .layoutValue(key: PRRowFactRoleKey.self, value: .who)
                repoChip
                    .layoutValue(key: PRRowFactRoleKey.self, value: .chip)
                ForEach(statusTags, id: \.text) { tag in
                    Tag(text: tag.text, color: tag.color)
                        .layoutValue(key: PRRowFactRoleKey.self, value: .tag)
                }
                if !statusTags.isEmpty, labelText != nil {
                    // 감싸기 배치에서는 레이아웃이 0×0 을 줘서 숨긴다. LabelSeparator 는 1×10 고정이라 틀로 감싸 잘라 낸다 —
                    // 최소값(0)을 같이 줘야 틀이 받은 0×0 으로 줄어든다(최대값만 주면 안쪽 1×10 을 따라가 그대로 그려졌다).
                    LabelSeparator()
                        .frame(minWidth: 0, maxWidth: 1, minHeight: 0, maxHeight: 10)
                        .clipped()
                        .layoutValue(key: PRRowFactRoleKey.self, value: .separator)
                }
                if let labels = labelText {
                    // 한 줄 배치에서는 레이아웃이 폭을 정하지 않고 물어 한 줄 그대로, 감싸기 배치에서는 행 폭을 줘서 두 줄까지.
                    labels
                        .lineLimit(2)
                        .help(pr.labels.joined(separator: ", "))
                        .layoutValue(key: PRRowFactRoleKey.self, value: .labels)
                }
            }
            RecentActivityList(pr: pr)
            }
        }
        .padding(.vertical, 3)
    }

    /// 라벨은 몇 개까지 보이는가. 넘치면 아랫줄로 흐르므로 폭이 아니라 개수로만 막는다.
    private static let labelLimit = 4

    /// 셋째 줄 앞부분 — 작성자·증감·승인 수. 늘 한 줄이고 줄어들지 않는다.
    @ViewBuilder
    private var whoAndSize: some View {
        // 작성자가 이 줄의 첫 자리다. 예전에는 레포 이름이 앞에 있었는데,
        // 레포명과 로그인이 둘 다 회색 소문자 식별자라 어느 쪽이 사람인지
        // 읽어야 알 수 있었다. 레포는 칩으로 바꿔 줄 오른쪽 끝으로 보냈다.
        //
        // 칩이 들어갈 자리가 없는 폭에서는 점만 남긴다.
        if model.settings.enabledRepos.count > 1, !density.showsRepoChip {
            RepoDot(name: pr.repo.name)
        }
        HStack(spacing: 3) {
            Text("by")
                .font(.caption2)
                .foregroundStyle(.tertiary)
            Text(model.settings.displayName(pr.author))
                .font(model.fonts.ui(delta: -2, weight: .medium))
        }
        // 이름과 증감은 넉넉히 짧다. 줄바꿈되면 행 높이가 흔들리고 읽기도 어렵다
        // (좁을 때 다섯 글자 이름이 두 줄로 접혔다).
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        .help(pr.author)
        HStack(spacing: 3) {
            Text("+\(pr.additions)")
                .foregroundStyle(.green)
            Text("−\(pr.deletions)")
                .foregroundStyle(.red)
        }
        .font(.caption2.monospacedDigit())
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
        ApprovalPill(count: pr.approvalCount, threshold: model.settings.approvalThreshold(for: pr),
                     changesRequested: pr.reviewDecision == "CHANGES_REQUESTED")
    }

    private struct StatusTag {
        let text: String
        let color: Color
    }

    /// **PR 이 어떻게 됐나** — 배지(내 리뷰 상태)와 축이 다르다.
    /// 예전에는 이 자리가 "내가 승인"·"변경 요청함" 처럼 내 리뷰 상태를 말해서,
    /// 배지의 "게시됨" 과 같은 사실을 두 번 적고 있었다.
    ///
    /// CI 실패 아이콘(✕)은 뺐다(사용자 결정) — 실패·취소는 상세의 개요 카드 CI 칸이 이름과 함께 말한다.
    private var statusTags: [StatusTag] {
        var tags: [StatusTag] = []
        if pr.isMerged {
            tags.append(StatusTag(text: "Merged", color: .purple))
        } else if !pr.isOpen {
            tags.append(StatusTag(text: "Closed", color: .red))
        }
        if pr.mergeable == .conflicting {
            tags.append(StatusTag(text: "Conflict", color: .red))
        }
        if pr.isDraft {
            tags.append(StatusTag(text: "Draft", color: .secondary))
        }
        if pr.viewerDidAuthor {
            tags.append(StatusTag(text: "내 PR", color: .secondary))
        } else if pr.viewerHasReviewRequest, pr.viewerRequestedAsCodeOwner != true, !pr.viewerHasSubmittedReview {
            // 남이 나에게 요청한 것 — 내가 한 일이 아니므로 배지가 아니라 여기다.
            // CODEOWNERS 가 자동으로 건 요청은 뺀다 — 팀 전원이 코드 소유자면 모든 행에 붙어 구분이 안 됐다.
            // "Review requested" 는 좁은 폭에서 잘린다. 줄 맥락이 PR 리뷰라 짧아도 통한다.
            tags.append(StatusTag(text: "Requested", color: .accentColor))
        }
        return tags
    }

    /// 라벨 줄(PRLabels — 라벨이 나오는 곳은 다 이 모양). 목록은 좁아서 4개까지, 넘치면 "외 N".
    private var labelText: Text? { PRLabels.text(pr.labels, limit: Self.labelLimit) }

    /// 레포 이름 칩. 칩으로 두면 이름처럼 보이지 않는다. 제목 줄에 올리지 않은 이유는
    /// 제목이 이미 한 줄로 잘리는데 폭을 더 빼앗기 때문이다.
    @ViewBuilder
    private var repoChip: some View {
        if model.settings.enabledRepos.count > 1, density.showsRepoChip {
            Tag(text: pr.repo.name, color: .secondary, dot: RepoDot.color(for: pr.repo.name))
                // 자리가 부족하면 접히지 말고 뒤를 자른다. 잘린 이름은 툴팁으로 본다.
                .fixedSize(horizontal: false, vertical: true)
                .help(pr.repo.name)
        }
    }
}

/// 필터는 목록에만 영향을 주므로 툴바가 아니라 목록 헤더에 둔다.
/// 켜진 개수를 숫자로 달아, 무언가 걸러지고 있다는 사실이 항상 보이게 한다
/// (레포를 새로 넣었는데 필터에 다 걸려 빈 화면이 되는 일이 있었다).
struct FilterButton: View {
    @Environment(AppModel.self) private var model
    @State private var isPresented = false
    @State private var isEditingAuthors = false
    @State private var isEditingLabels = false

    private var activeCount: Int {
        var count = 0
        // 목록이 비어 있으면 아무것도 안 거르므로 세지 않는다(PRFilterState.active 와 같은 규칙).
        if model.filter.hideIgnoredAuthors, !model.settings.ignoredAuthors.isEmpty { count += 1 }
        if model.filter.hideLabels, !model.settings.hiddenLabels.isEmpty { count += 1 }
        // 레포는 세지 않는다 — 위쪽 레포 탭이 고른 상태를 늘 보여 주고, 이 팝오버에는 레포 칸이 없다.
        // 세면 "필터 1" 인데 열어 보면 켜진 것이 없는 상태가 된다.
        return count
    }

    var body: some View {
        @Bindable var model = model
        Button {
            isPresented.toggle()
        } label: {
            HStack(spacing: 3) {
                Image(systemName: "line.3.horizontal.decrease.circle")
                Text("필터")
                if activeCount > 0 {
                    Text("\(activeCount)")
                        .font(.caption2.monospacedDigit().weight(.semibold))
                        .padding(.horizontal, 4)
                        .padding(.vertical, 1)
                        .background(Color.accentColor, in: Capsule())
                        .foregroundStyle(.white)
                }
            }
            .font(.caption)
        }
        .buttonStyle(.borderless)
        .help(activeCount > 0 ? "필터 \(activeCount)개가 켜져 있습니다" : "필터")
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            VStack(alignment: .leading, spacing: 8) {
                HStack {
                    Text("필터").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                    Spacer()
                    Button("모두 끄기") {
                        model.filter.hideIgnoredAuthors = false
                        model.filter.hideLabels = false
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                    .disabled(activeCount == 0)
                }

                VStack(alignment: .leading, spacing: 6) {
                    // 목록이 비면 켜 봐야 아무 일도 없다. 무엇이 들어 있는지와 고치는 길을
                    // 토글 **오른쪽**에 붙인다 — 아래 줄로 내리면 다음 토글과 붙어 보여서
                    // 어느 토글에 딸린 설명인지 헷갈린다.
                    listToggle(PRFilterKind.hideLabels.label, isOn: $model.filter.hideLabels,
                               summary: PRLabels.text(model.settings.hiddenLabels)) {
                        isEditingLabels = true
                    }
                    listToggle(PRFilterKind.hideIgnoredAuthors.label, isOn: $model.filter.hideIgnoredAuthors,
                               summary: model.settings.ignoredAuthors.isEmpty ? nil
                                   : Text(model.settings.ignoredAuthors.map { model.settings.displayName($0) }
                                       .joined(separator: " · "))) {
                        isEditingAuthors = true
                    }
                }
                .toggleStyle(.checkbox)

                if model.listScope.kind == .open {
                    Divider()
                    // 끌 수 있는 선택지가 아니라 이 탭의 정의다. 말해 주지 않으면 "왜 안 보이지" 가 된다.
                    Text("'To review' 에는 닫힘·머지, 내가 Approve 한 PR, 초안이 나오지 않습니다 — 'All PRs'·'Approved' 와 맨 위 '내가 올린 PR' 에서 보세요.")
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                        .fixedSize(horizontal: false, vertical: true)
                }

            }
            .padding(14)
            .frame(minWidth: 280)
        }
        .sheet(isPresented: $isEditingAuthors) { IgnoredAuthorsEditor() }
        .sheet(isPresented: $isEditingLabels) { HiddenLabelsEditor() }
    }

    /// 목록을 거르는 토글 한 줄: [토글] … 들어 있는 것 [편집…].
    /// - summary: 들어 있는 것. 라벨은 PRLabels 모양으로 넘긴다(라벨이 나오는 곳은 다 같은 모양).
    private func listToggle(_ title: String, isOn: Binding<Bool>, summary: Text?,
                            edit: @escaping () -> Void) -> some View {
        HStack(spacing: 8) {
            Toggle(title, isOn: isOn)
            Spacer(minLength: 16)
            (summary ?? Text("비어 있음"))
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .lineLimit(1)
                .truncationMode(.tail)
            // 팝오버 위에 시트를 띄우면 둘이 겹친다. 먼저 닫는다.
            Button("편집…") {
                isPresented = false
                edit()
            }
            .buttonStyle(.link)
            .font(.caption2)
            .fixedSize()
        }
    }
}

/// PR 목록 행 아래에 붙는 최근 리뷰 활동.
///
/// **항상 최근 3건이 보인다.** 3건보다 많으면 오른쪽에 "Show all (N)" 이 붙어, 누르면 받아 둔
/// 전체 내역이 뜬다(전체 모드에서는 커밋도 하나씩 나온다 — 3줄만 보일 때는 한 번의 푸시가
/// 줄을 다 먹지 않도록 최근 1건으로 접는다). 활동이 없으면 자리를 차지하지 않는다.
///
/// 조절 수단은 3건 ↔ 전체, 이 하나뿐이다. 활동을 통째로 감추는 접기는 없앴다.
struct RecentActivityList: View {
    @Environment(AppModel.self) private var model
    let pr: PullRequestInfo

    private static let compactLimit = 3

    var body: some View {
        // 두 번 만든다. 접힌 목록은 커밋을 접고, 전체 목록은 펴야 해서 결과가 다르다.
        // 둘 다 이미 받아 둔 PR 데이터만 훑으므로 추가 요청은 없다.
        let compact = PRActivityBuilder.build(from: pr, limit: Self.compactLimit)
        let isFull = model.isActivityFull(pr)
        let all = isFull || compact.count >= Self.compactLimit
            ? PRActivityBuilder.build(from: pr, limit: nil, collapseCommits: false)
            : compact
        let shown = isFull ? all : compact
        let canShowMore = all.count > compact.count

        if !shown.isEmpty {
            VStack(alignment: .leading, spacing: 1) {
                ForEach(shown) { activity in
                    ActivityRow(activity: activity,
                                name: activity.actor.isEmpty ? "" : model.settings.displayName(activity.actor))
                }
                // 이 줄은 셀 맨 아래에 둔다. 가운데 있으면 PR 을 고르려다 잘못 눌린다.
                //
                // 예전에는 왼쪽 "Recent activity" 가 **활동을 통째로 감추는** 접기 버튼이었다.
                // 3건은 접어서 아낄 만큼 길지도 않은데, 접어 두면 그 PR 에 무슨 일이 있었는지
                // 알려면 매번 다시 펴야 했다. 조절은 3건 ↔ 전체 하나로 충분하다.
                HStack(spacing: 3) {
                    Text("Recent activity")
                        .font(.caption2.weight(.semibold))
                        .foregroundStyle(.tertiary)

                    Spacer()

                    if canShowMore || isFull {
                        Button {
                            // 애니메이션을 걸면 셀 높이가 변하는 동안 위쪽 행까지 다시 그려져 흔들린다.
                            model.toggleActivityFull(pr)
                        } label: {
                            Text(isFull ? "Show less" : "Show all (\(all.count))")
                                .font(.caption2.weight(.semibold))
                                .foregroundStyle(Color.accentColor)
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(isFull ? "최근 \(Self.compactLimit)건만 보기" : "받아 둔 전체 내역 보기")
                    }
                }
                .padding(.top, 2)
            }
            .padding(.top, 1)
        }
    }
}

struct ActivityRow: View {
    let activity: PRActivity
    let name: String

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: activity.kind.symbolName)
                .font(.caption2)
                .foregroundStyle(tint)
                .frame(width: 11)
            if !name.isEmpty {
                Text(name)
                    .font(.caption2.weight(.medium))
                    .lineLimit(1)
                    .frame(width: 62, alignment: .leading)
            }
            Text(activity.kind.label)
                .font(.caption2)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            Spacer(minLength: 4)
            RelativeTimeText(date: activity.at)
                .font(.caption2.monospacedDigit())
                .foregroundStyle(.tertiary)
        }
        .help(tooltip)
    }

    private var tint: Color {
        switch activity.kind {
        case .approved: return .green
        case .changesRequested: return .orange
        case .dismissed: return .orange
        case .merged: return .purple
        case .closed: return .red
        case .commented, .pushed, .reopened: return .secondary
        }
    }

    /// 코멘트는 본문 일부까지 보여준다. 본문이 없는 활동(Approve 등)은 한 줄로 끝난다.
    private var tooltip: String {
        let head = [activity.actor.isEmpty ? nil : activity.actor,
                    activity.kind.label,
                    RelativeTime.compact(activity.at)]
            .compactMap { $0 }
            .joined(separator: " · ")
        guard let excerpt = activity.excerpt else { return head }
        return "\(head)\n\n\"\(excerpt)\""
    }
}

/// 목록 행의 "클론 45%". 뱃지와 같은 모양으로 그 자리에 대신 선다.
struct CloneProgressChip: View {
    let fraction: Double

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "arrow.down.circle")
                .font(.caption2)
            Text("클론 \(Int((fraction * 100).rounded()))%")
                .font(.caption2.weight(.medium).monospacedDigit())
                .lineLimit(1)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .foregroundStyle(Color.blue)
        .background(Color.blue.opacity(0.14), in: Capsule())
        .overlay { Capsule().stroke(Color.blue.opacity(0.35), lineWidth: 0.5) }
        .fixedSize(horizontal: true, vertical: false)
        .help("전체 리뷰를 위해 PR 스냅샷을 처음 클론하는 중입니다")
    }
}

struct BadgeChip: View {
    let result: BadgeResult
    /// 좁은 목록에서는 이유 칩을 아이콘(·숫자)만 남긴다. 다 적은 말은 마우스를 올리면 나온다.
    @Environment(\.prRowDensity) private var density

    var body: some View {
        if let followUp = result.followUp {
            // 승인한 PR 이 다시 떴다. Approved 는 승인만 한 PR 과 같은 색·자리 그대로 두고, 왜 다시 떴는지를
            // 오른쪽에 붙여 캡슐 하나로 읽히게 한다(사용자 결정, 시안 A) — 칩 둘을 띄워 두면 서로 다른 상태 둘로 읽혔다.
            HStack(spacing: 0) {
                label
                    .padding(.leading, 6)
                    .padding(.trailing, 5)
                    .padding(.vertical, 2)
                    .foregroundStyle(color)
                    .background(Self.half(leading: true).fill(color.opacity(0.14)))
                    .overlay(Self.half(leading: true).stroke(color.opacity(0.35), lineWidth: 0.5))
                    .help(followUp.detail)
                FollowUpChip(followUp: followUp, compact: density != .full, attached: true)
            }
            .fixedSize(horizontal: true, vertical: false)
        } else if let help = result.help {
            // Blocker·Non-blocker — 중요도별 개수(필수·권장·참고)는 마우스를 올리면 다 보인다.
            withNonBlockingTail(chip)
                .help(help)
        } else {
            chip
        }
    }

    /// 붙은 캡슐의 반쪽 — 바깥쪽만 둥글고 맞닿는 쪽은 곧다. FollowUpChip 이 오른쪽 반을 쓴다.
    static func half(leading: Bool) -> UnevenRoundedRectangle {
        let r: CGFloat = 8
        return leading
            ? UnevenRoundedRectangle(topLeadingRadius: r, bottomLeadingRadius: r)
            : UnevenRoundedRectangle(bottomTrailingRadius: r, topTrailingRadius: r)
    }

    /// Blocker 뒤에 권장·참고 개수를 초록 칩으로 붙인다 — 빨강 칩 밑에 깔려 삐져나온 모양(사용자 결정, 시안 10번 "겹친 칩").
    /// 초록 캡슐을 전체 폭으로 깔고 빨강 칩을 왼쪽에 얹어, 두 칩 높이가 늘 같다.
    @ViewBuilder
    private func withNonBlockingTail(_ chip: some View) -> some View {
        if let count = result.trailingNonBlockingCount {
            HStack(spacing: 4) {
                chip
                    // 빨강 칩 오른쪽 가장자리에 얇은 그늘 — 초록 위에 얹힌 것처럼 보이게.
                    .background(Capsule().fill(.black.opacity(0.22)).offset(x: 1))
                Text("\(count)")
                    .font(.caption2.weight(.medium).monospacedDigit())
                    .lineLimit(1)
                    .foregroundStyle(.white)
                    .padding(.trailing, 6)
            }
            .background(Self.nonBlockerFill, in: Capsule())
            .fixedSize(horizontal: true, vertical: false)
        } else {
            chip
        }
    }

    private var label: some View {
        HStack(spacing: 3) {
            Image(systemName: result.badge.symbolName)
                .font(.caption2)
            Text(result.text)
                .font(.caption2.weight(.medium))
                // 좁아지면 "미리뷰" 가 "미리 / 뷰" 로 접혔다. 뱃지는 늘 한 줄이다.
                .lineLimit(1)
            ForEach(result.overlays, id: \.rawValue) { overlay in
                Image(systemName: overlay.symbolName)
                    .font(.system(size: 8))
                    .help(overlay.label)
            }
        }
    }

    /// 판정(Blocker·Non-blocker·LGTM)은 꽉 채운다 — 진행 상태·GitHub 리뷰 상태(연한 칩)와 달리 리뷰가 끝난 결과라는 표시(사용자 결정).
    private var chip: some View {
        let solid = isVerdict
        return label
            .padding(.horizontal, 6)
            .padding(.vertical, 2)
            .foregroundStyle(solid ? Color.white : color)
            .background(solid ? color : color.opacity(0.14), in: Capsule())
            .overlay {
                if !solid {
                    Capsule().stroke(color.opacity(0.35), lineWidth: 0.5)
                }
            }
            .fixedSize(horizontal: true, vertical: false)
    }

    private var isVerdict: Bool { result.badge.isVerdict }

    // 판정 칩 바탕(사용자 결정 2026-10-29: 빨강 #E5484D · 초록 #30A46C · 하늘 #00A3FF).
    // LGTM 은 예전 아주르(#3D8EE6)가 회색기가 돌아 탁했다 — 채도를 끝까지 올리고 하늘색 쪽으로 옮겼다.
    // 하늘색 쪽이라 Reviewing·You commented 의 시스템 파랑(연한 칩)과도 덜 겹친다. 흰 글자 대비는 2.7 로 낮은 편이다(감수).
    // Non-blocker 초록은 푸른기를 섞어 Approved 의 시스템 초록(연한 칩)과 갈리게 했다.
    // 코드 코멘트 칸의 판정 칩(VerdictChipLabel)도 같은 색을 쓴다.
    static let blockerFill = Color(red: 0.898, green: 0.282, blue: 0.302)
    static let nonBlockerFill = Color(red: 0.188, green: 0.643, blue: 0.424)
    static let lgtmFill = Color(red: 0.0, green: 0.639, blue: 1.0)

    private var color: Color {
        switch result.badge {
        case .reviewing: return .blue
        // Non-blocker 는 승인해도 되는 쪽이라 경고색(주황) 대신 초록 — 막는 것만 빨강이다.
        case .blocker: return Self.blockerFill
        case .nonBlocker: return Self.nonBlockerFill
        // 초안이 깨끗한 것(LGTM)과 실제로 승인한 것(Approved)은 무게가 달라 색도 나눈다.
        // 둘 다 초록이면 "올렸나 안 올렸나" 가 한눈에 안 보인다 — LGTM 은 꽉 찬 하늘색, Approved 는 연한 초록.
        case .lgtm: return Self.lgtmFill
        case .approved: return .green
        case .changesRequested: return .red
        case .commented: return .blue
        case .dismissed: return .secondary
        case .reRequested: return .blue
        case .notReviewed: return .secondary
        }
    }
}

/// AI 리뷰 탭 코드 코멘트 칸 머리 줄·좁은 창 탭의 판정 칩 하나. BadgeChip 의 판정 칩(꽉 채운 캡슐)과 같은 아이콘·글꼴·
/// 여백·색이다 — 목록에서 본 그 칩으로 읽혀야 해서 모양을 따로 두지 않는다(VerdictChip 주석).
struct VerdictChipLabel: View {
    let chip: VerdictChip

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: chip.badge.symbolName)
                .font(.caption2)
            Text(chip.text)
                .font(.caption2.weight(.medium))
                .lineLimit(1)
        }
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .foregroundStyle(Color.white)
        .background(fill, in: Capsule())
        .fixedSize()
    }

    private var fill: Color {
        switch chip {
        case .blocker: return BadgeChip.blockerFill
        case .nonBlocker: return BadgeChip.nonBlockerFill
        case .lgtm: return BadgeChip.lgtmFill
        }
    }
}

/// 승인한 PR 이 다시 뜬 이유 — 재요청(파랑)·새 커밋(주황). BadgeChip 이 Approved 오른쪽에 붙여 캡슐 하나로 만든다.
struct FollowUpChip: View {
    let followUp: PRBadgeFollowUp
    /// 좁은 목록: 아이콘만(재요청) 또는 아이콘 + 숫자(`+2`).
    var compact = false
    /// Approved 오른쪽에 붙은 반쪽 — 왼쪽 모서리를 곧게 그린다.
    var attached = false

    var body: some View {
        let text = compact ? followUp.shortLabel : followUp.label
        let shape = attached ? AnyShape(BadgeChip.half(leading: false)) : AnyShape(Capsule())
        HStack(spacing: 3) {
            Image(systemName: followUp.symbolName)
                .font(.caption2)
            if let text {
                Text(text)
                    .font(.caption2.weight(.medium))
                    .lineLimit(1)
            }
        }
        .padding(.leading, attached ? 5 : (text == nil ? 4 : 6))
        .padding(.trailing, text == nil ? 4 : 6)
        .padding(.vertical, 2)
        .foregroundStyle(color)
        .background(shape.fill(color.opacity(0.14)))
        .overlay(shape.stroke(color.opacity(0.35), lineWidth: 0.5))
        .fixedSize(horizontal: true, vertical: false)
        .help(followUp.detail)
    }

    private var color: Color {
        switch followUp {
        case .reRequested: return .blue
        case .newCommits: return .orange
        }
    }
}

struct ApprovalPill: View {
    let count: Int
    let threshold: Int
    let changesRequested: Bool

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "person.2.fill").font(.system(size: 8))
            Text("\(count)/\(threshold)").font(.caption2.monospacedDigit())
            if changesRequested {
                Circle().fill(Color.red).frame(width: 5, height: 5)
                    .help("변경 요청이 있습니다")
            }
        }
        .foregroundStyle(count >= threshold ? .green : .secondary)
        .lineLimit(1)
        .fixedSize(horizontal: true, vertical: false)
    }
}

struct Tag: View {
    let text: String
    let color: Color
    /// 글자 앞 색점. 레포 칩에서 그 레포의 색(RepoDot.color)을 단다 — 레포 탭·좁은 행의 점과 같은 색이다.
    var dot: Color? = nil

    var body: some View {
        HStack(spacing: 3) {
            if let dot {
                Circle()
                    .fill(dot)
                    .frame(width: 6, height: 6)
            }
            Text(text)
                .font(.caption2)
                // 태그는 항상 한 줄이다. 목록 행이 좁아지면 두 줄로 접혀 행 높이가 흔들렸다.
                .lineLimit(1)
        }
        .padding(.horizontal, 5)
        .padding(.vertical, 1)
        .foregroundStyle(color)
        .background(color.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
    }
}


/// 목록 탭 하나. 기간이 있는 탭은 [몸통 | ⌄] 두 조각이다.
private struct ScopeTab: View {
    @Environment(AppModel.self) private var model
    let kind: PRListScopeKind
    @State private var showPeriods = false
    /// 칩이 닿은 순간(ApprovalFlight) — 잠깐 탭 색으로 커졌다 돌아온다. Approved 는 초록, All PRs 는 파랑.
    @State private var landingHit = false
    @State private var showsPlusOne = false

    private var isSelected: Bool { model.listScope.kind == kind }
    /// 닿은 칩의 색 — 칩과 같다(Approved 배지 초록 · 그 밖은 탭 색).
    private var landingText: Color { kind == .myApprovals ? PostedStatusLabel.text : Color.accentColor }
    private var landingFill: Color { kind == .myApprovals ? PostedStatusLabel.fill : Color.accentColor }
    /// 이 탭을 누르면 될 범위. 선택된 탭이면 지금 보고 있는 범위 그대로다.
    private var target: PRListScope {
        isSelected ? model.listScope : model.scope(for: kind)
    }

    var body: some View {
        HStack(spacing: 0) {
            Button {
                guard model.listScope != target else { return }
                model.listScope = target
            } label: {
                Text(target.label)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    // 목록이 좁으면(320pt) "최근 Approve 24h" 가 두 줄로 접혔다('승인' 을 'Approve' 로 바꾼 뒤 길어져서).
                    // 이름은 그대로 두고, 자리가 모자랄 때만 글자를 조금 줄여 한 줄을 지킨다(사용자 선택).
                    .lineLimit(1)
                    .minimumScaleFactor(0.8)
                    .padding(.leading, 10)
                    .padding(.trailing, kind.usesWindow ? 6 : 10)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(target.help)

            if kind.usesWindow {
                Rectangle()
                    .fill(Color.primary.opacity(isSelected ? 0.18 : 0.12))
                    .frame(width: 1, height: 13)
                Button {
                    showPeriods = true
                } label: {
                    Image(systemName: "chevron.down")
                        .font(.system(size: 8, weight: .bold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 6)
                        .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
                .help("기간 고르기")
                .popover(isPresented: $showPeriods, arrowEdge: .bottom) {
                    periodList
                }
            }
        }
        .foregroundStyle(isSelected ? Color.white : (landingHit ? landingText : Color.primary))
        .background {
            RoundedRectangle(cornerRadius: 6)
                .fill(isSelected ? Color.accentColor : (landingHit ? landingText.opacity(0.2) : Color.primary.opacity(0.06)))
        }
        // 칩이 날아갈 자리(ApprovalFlight).
        .anchorPreference(key: ApprovalFlightAnchorsKey.self, value: .bounds) { anchor in
            ApprovalFlightAnchors(tabs: [kind: anchor])
        }
        // 탭에 개수를 늘 달아 두지는 않는다 — 탭 줄이 보여 주는 정보는 그대로 두고, 닿은 순간에만 "+1" 이 떴다 사라진다.
        .overlay(alignment: .topTrailing) {
            if showsPlusOne {
                Text(verbatim: "+\(model.tabLandings[kind]?.count ?? 1)")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.white)
                    .padding(.horizontal, 4)
                    .padding(.vertical, 1)
                    .background(landingFill, in: Capsule())
                    .offset(x: 5, y: -6)
                    .transition(.scale(scale: 0.4).combined(with: .opacity))
                    .allowsHitTesting(false)
            }
        }
        .scaleEffect(landingHit ? 1.07 : 1)
        .onChange(of: model.tabLandings[kind]) {
            land()
        }
    }

    private func land() {
        withAnimation(.spring(duration: 0.2, bounce: 0.3)) {
            landingHit = true
            showsPlusOne = true
        }
        Task {
            try? await Task.sleep(for: .seconds(0.32))
            withAnimation(.easeOut(duration: 0.25)) { landingHit = false }
            try? await Task.sleep(for: .seconds(0.5))
            withAnimation(.easeOut(duration: 0.25)) { showsPlusOne = false }
        }
    }

    private var periodList: some View {
        VStack(alignment: .leading, spacing: 2) {
            Text("기간")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.top, 6)
            ForEach(PRListWindow.allCases) { window in
                Button {
                    showPeriods = false
                    model.listScope = PRListScope(kind: kind, window: window)
                } label: {
                    HStack(spacing: 6) {
                        Image(systemName: "checkmark")
                            .font(.system(size: 9, weight: .bold))
                            .opacity(model.window(for: kind) == window ? 1 : 0)
                        Text(window.shortLabel)
                            .font(.system(size: 12))
                        Spacer(minLength: 12)
                    }
                    .padding(.horizontal, 10)
                    .padding(.vertical, 4)
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
            Text(kind == .myApprovals
                 ? "내가 그 기간 안에 Approve 한 PR 만 봅니다."
                 : "그 기간 안에 활동이 있었던 PR 전부 — 닫힘·머지 포함.")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .frame(width: 190, alignment: .leading)
                .padding(.horizontal, 10)
                .padding(.top, 4)
                .padding(.bottom, 8)
        }
        .padding(.vertical, 2)
        // 선택된 탭은 흰 글자라, popover 가 그것을 물려받으면 기간 이름이 안 보인다
        // (SplitActionButton.choiceList 와 같은 함정).
        .foregroundStyle(Color.primary)
    }
}

/// 목록에 새로 온 행이 위에서부터 펼쳐지며 들어온다(`AppModel.applyFetched` 가 애니메이션으로 감쌀 때만).
///
/// 행 높이는 처음부터 다 차지하고 아래 행들이 그만큼 미끄러져 내려간다. 그 사이 행 내용을 위에서부터 드러내
/// 벌어지는 틈과 같이 자라게 한다 — `scaleEffect` 로 행 자체를 눌렀다 펴면 글자가 찌그러져 보였다.
private struct RowUnfold: ViewModifier {
    let progress: CGFloat

    func body(content: Content) -> some View {
        content
            .opacity(progress)
            .mask(alignment: .top) {
                Rectangle().scaleEffect(x: 1, y: progress, anchor: .top)
            }
    }
}

extension View {
    /// 빠질 때는 예전처럼 흐려지기만 한다 — 처리를 마친 행이 빠지는 것(`markLeaving`)은 "사라짐" 이라 접히는 모양이 어울리지 않는다.
    func listRowTransition() -> some View {
        transition(.asymmetric(insertion: .modifier(active: RowUnfold(progress: 0), identity: RowUnfold(progress: 1)),
                               removal: .opacity))
    }
}

/// 목록 맨 아래 한 줄 — 뒤 페이지를 이어 받는 동안만 "↻ 이어서 가져오는 중". 아래에 행이 더 올 수 있다는 것을 말하지
/// 않으면 목록이 거기서 끝난 것처럼 보인다.
///
/// 평소 보이던 "23건 · 14:32 갱신" 은 목록 머리 줄(ListHeader)로 올렸다(사용자 선택 2026-10-29, 시안 3-1). 그 전에는
/// 받을 때마다 빈 행 자리 하나가 숨 쉬고 "✓ 새로 2 · 빠짐 1" 을 잠깐 보이기도 했다.
private struct ListFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ZStack {
            if model.isLoadingMore {
                HStack(spacing: 4) {
                    ProgressView()
                        .controlSize(.mini)
                    Text("이어서 가져오는 중")
                }
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.top, 4)
                .padding(.bottom, 10)
                .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity)
        .animation(.easeInOut(duration: 0.25), value: model.isLoadingMore)
    }
}

/// 목록 맨 위 한 줄 — 왼쪽 "To review 24건", 오른쪽 "오후 2:40 갱신 ↻"(사용자 선택 2026-10-29, 시안 3-1). 검색줄
/// 바로 아래, 내가 올린 PR 칸보다 위라 스크롤해도 늘 보이고, 새로고침을 목록 가까이에서 누른다 — 툴바 버튼은 목록에서
/// 멀다. 툴바·⌘R·↻ 로 다시 받을 때는 ↻ 자리에서 돌고, 2분마다 도는 폴링은 시각만 바뀐다(받을 때마다 움직이면 눈에 걸린다).
///
/// 지난 목록을 보이며 다시 받는 동안은 오른쪽이 "가져오는 중 · 오후 2:02 목록" 이 되고, 다 받으면 "최신 · 오후 2:40" 을
/// 잠깐 보인다. 받는 중 표시가 맨 아래에만 있으면 지난 목록을 이번 결과로 오해했고, 목록 위에 띄운 알약(구석 점으로
/// 접히던 것)은 첫 행을 가렸다(사용자 지적 2026-10-29). 줄이 늘 그 자리에 있어 표시가 바뀌어도 목록은 움직이지 않는다.
private struct ListHeader: View {
    @Environment(AppModel.self) private var model

    private enum Phase: Equatable {
        case idle
        /// 지난 목록을 보이며 받는 중. 조용히 다시 받을 때(`isShowingCachedList` 가 거짓 — 받은 지 얼마 안 된 탭·폴링)는
        /// 아니다. 여러 페이지 탭은 첫 페이지를 받으면 끝난다 — 뒤 페이지는 맨 아래 "이어서 가져오는 중" 이 이어 말한다.
        case staleFetching
        /// 지난 목록을 다 받았다 — 잠깐 보이고 걷힌다(AppModel.staleRefreshCheckedAt).
        case checked(Date)
        /// 툴바·⌘R·↻ 로 다시 받는 중.
        case userFetching
    }

    private var phase: Phase {
        // 빈 목록을 처음 채우는 동안은 행 자리에 깐 빈 행들이 "가져오는 중" 을 말한다.
        if model.isRefreshing, model.isShowingCachedList, !model.visiblePRs.isEmpty { return .staleFetching }
        if let at = model.staleRefreshCheckedAt { return .checked(at) }
        return model.isUserRefreshing ? .userFetching : .idle
    }

    var body: some View {
        HStack(spacing: 6) {
            count
                .fontWeight(.medium)
                .foregroundStyle(.secondary)
            Spacer(minLength: 8)
            // 평소의 시각은 흐리게, 받는 중·최신은 한 단계 짙게 — 지난 목록이라는 것은 읽혀야 한다.
            status
                .foregroundStyle(phase == .idle ? .tertiary : .secondary)
            icon
                .frame(width: 18, height: 18)
        }
        .font(.caption)
        .lineLimit(1)
        .padding(.leading, 12)
        .padding(.trailing, 8)
        .frame(height: 24)
        .animation(.easeInOut(duration: 0.25), value: phase)
    }

    /// "To review 24건" — 다 받고 연출이 끝났을 때의 수. 차례를 기다리는 새 행은 세고, 칩이 되어 떠나는 행은 뺀다 — 안
    /// 그러면 행이 날아가고 펼쳐지는 동안 "9건" → "7건" 처럼 숫자가 오르내리며 깜빡인다. 처음 받는 중(빈 행 자리)에는
    /// 셀 것이 없어 탭 이름만.
    private var count: Text {
        let label = model.listScope.label
        if model.visiblePRs.isEmpty, model.isRefreshing, model.isShowingCachedList { return Text(label) }
        let count = model.visiblePRs.filter { !model.isFlightSource($0) }.count + model.heldBackArrivals.count
        return Text("\(label) \(count)건")
    }

    /// "오후 2:40 갱신" — 상태 메뉴의 "갱신" 과 같은 꼴. 이 탭을 받은 적이 없으면 비운다.
    @ViewBuilder private var status: some View {
        switch phase {
        case .idle:
            if let at = model.lastFetched(model.listScope) {
                Text("\(at, style: .time) 갱신")
            }
        case .staleFetching:
            // 목록이 좁으면 언제 받은 목록인지를 뗀다.
            ViewThatFits(in: .horizontal) {
                staleListText
                Text("가져오는 중")
            }
        case .checked(let at):
            // 몇 건이 바뀌었는지는 말하지 않는다 — 행이 날아가고 펼쳐지는 것으로 보인다. 보던 목록이 이제 최신이라는
            // 것만(사용자 선택 2026-10-29 — "새로 2 · 빠짐 1" 이 어색했다).
            Text("최신 · \(at, style: .time)")
        case .userFetching:
            Text("가져오는 중")
        }
    }

    /// "가져오는 중 · 오후 2:02 목록" — 지금 보이는 것이 언제 받은 목록인지. 오늘이 아니면 날짜로, 이 탭을 받은 적이
    /// 없으면(다른 탭에서 본 PR 로 채운 목록) 시각을 뺀다.
    private var staleListText: Text {
        guard let at = model.lastFetched(model.listScope) else { return Text("가져오는 중") }
        guard Calendar.current.isDateInToday(at) else {
            return Text("가져오는 중 · \(at.formatted(.dateTime.month().day())) 목록")
        }
        return Text("가져오는 중 · \(at, style: .time) 목록")
    }

    @ViewBuilder private var icon: some View {
        switch phase {
        case .idle:
            Button {
                Task { await model.refreshByUser() }
            } label: {
                Image(systemName: "arrow.clockwise")
                    .font(.system(size: 10.5, weight: .semibold))
                    .frame(width: 18, height: 18)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.borderless)
            .foregroundStyle(.secondary)
            .help("새로고침 (⌘R)")
        case .staleFetching, .userFetching:
            ProgressView()
                .controlSize(.mini)
        case .checked:
            Image(systemName: "checkmark")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(PostedStatusLabel.text)
        }
    }
}

/// 목록이 비어 있는 채로 이 탭을 받는 동안 행이 들어올 자리에 까는 빈 행들. 받으면 그 자리가 실제 행으로 바뀌어 위치가
/// 튀지 않는다 — 예전에는 가운데의 스피너와 글자가 사라지고 목록이 새로 나타났다(사용자 선택 2026-10-28, 시안 C).
private struct LoadingSkeleton: View {
    let title: String
    var detail: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if let detail {
                    Text(detail)
                        .font(.caption2)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 6)
            ForEach(0..<6, id: \.self) { index in
                SkeletonRow(delay: Double(index) * 0.12)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .transition(.opacity)
    }
}

/// PR 행과 같은 틀의 빈 자리 — 아바타 동그라미, 칩 줄, 제목, 셋째 줄. 숨 쉬듯 옅어졌다 짙어진다(동작 줄이기면 멈춘다).
/// 행 사이에 `delay` 를 조금씩 두어 위에서 아래로 물결처럼 지나간다.
private struct SkeletonRow: View {
    var delay: Double = 0
    @State private var dim = false

    var body: some View {
        HStack(spacing: 8) {
            Circle()
                .frame(width: 22, height: 22)
            VStack(alignment: .leading, spacing: 7) {
                bar(width: 120, height: 14)
                bar(width: nil, height: 13)
                bar(width: 170, height: 11)
            }
        }
        .foregroundStyle(Color.primary.opacity(0.07))
        .frame(maxWidth: .infinity, alignment: .leading)
        // 행과 같은 안쪽·바깥쪽 여백(PRListView 의 ForEach).
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .padding(.horizontal, 6)
        .opacity(dim ? 0.45 : 1)
        .onAppear {
            guard !NSWorkspace.shared.accessibilityDisplayShouldReduceMotion else { return }
            withAnimation(.easeInOut(duration: 0.55).repeatForever(autoreverses: true).delay(delay)) {
                dim = true
            }
        }
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private func bar(width: CGFloat?, height: CGFloat) -> some View {
        if let width {
            RoundedRectangle(cornerRadius: 4)
                .frame(width: width, height: height)
        } else {
            // 제목 줄은 행 폭을 따라 늘되 끝까지 채우지는 않는다 — 실제 제목도 끝이 들쭉날쭉하다.
            RoundedRectangle(cornerRadius: 4)
                .frame(height: height)
                .frame(maxWidth: .infinity)
                .padding(.trailing, 36)
        }
    }
}

/// 검색할 때 두 구역(지금 탭 · 그 밖)을 가르는 머리 줄. 옅은 띠 위에 아이콘·글·오른쪽 덧말.
private struct SearchSectionHeader<Trailing: View>: View {
    var systemImage: String?
    var spinning = false
    let text: String
    @ViewBuilder var trailing: Trailing

    var body: some View {
        HStack(spacing: 6) {
            if spinning {
                ProgressView()
                    .controlSize(.mini)
            } else if let systemImage {
                Image(systemName: systemImage)
            }
            Text(text)
            Spacer(minLength: 8)
            trailing
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 6)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.quinary.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
        .padding(.horizontal, 6)
    }
}

extension SearchSectionHeader where Trailing == EmptyView {
    init(systemImage: String? = nil, spinning: Bool = false, text: String) {
        self.init(systemImage: systemImage, spinning: spinning, text: text) { EmptyView() }
    }
}
