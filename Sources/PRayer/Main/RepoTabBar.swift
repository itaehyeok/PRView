import SwiftUI
import AppKit
import UniformTypeIdentifiers
import PRayerCore

/// 툴바 바로 아래 창 너비 한 줄. 왼쪽에 레포 탭, 그 바로 뒤에 "│ ⚙︎"(레포 관리).
///
/// 예전에는 탭이 목록 맨 위(목록 폭 320~420pt)에 있고 레포 관리는 툴바의 "레포 N개" 메뉴였다. 목록이 좁으면
/// 레포 둘만 있어도 탭이 넘쳤고, 레포 목록이 두 군데라 무엇이 무엇인지 헷갈렸다. 시안 여러 벌(탭 줄 끝 ⚙︎ ·
/// 색점만 · 툴바 가운데 · 툴바 제목 자리 · 창 너비 띠 …) 중 사용자가 창 너비 띠(W4)를 골랐다 — 창 너비라 이름이
/// 다 들어가고, 볼 레포(탭)와 조회할 레포(⚙︎)가 한 줄에 모인다. ⚙︎ 는 레포가 없어도 늘 있다(레포를 더하는 길).
///
/// ⚙︎ 는 처음에 창 오른쪽 끝에 두었는데, 레포가 둘뿐이면 탭과 창 폭만큼 떨어져 있었다(사용자 피드백). 그래서 탭이
/// 다 들어가면 마지막 탭 바로 뒤에, 넘쳐서 밀어야 볼 때만 오른쪽 끝에 둔다. 앞에 얇은 구분선을 둬서 탭이 하나 더
/// 있는 것처럼 보이지 않게 한다(시안 (a) 아이콘만 · (b) 구분선 │ ⚙︎ · (c) ⚙︎ 관리 중 (b) — 사용자 선택).
/// 넘치는지 따로 묻지 않는다 — 탭 줄이 제 폭까지만 늘어나므로(RepoTabBar), 다 들어가면 ⚙︎ 가 바로 뒤에 붙고,
/// 넘치면 탭 줄이 남은 폭을 다 써서 ⚙︎ 가 저절로 오른쪽 끝에 간다.
struct RepoStrip: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        let repos = model.settings.enabledRepos
        HStack(alignment: .center, spacing: 0) {
            if repos.count > 1 {
                RepoTabBar()
                    // 뒤의 빈칸(Spacer)보다 먼저 폭을 받는다. 같은 순위면 HStack 이 남은 폭을 둘에 나눠 주므로,
                    // 자리가 남는데도 탭 줄이 좁게 잡혀 넘칠 수 있다.
                    .layoutPriority(1)
            } else {
                // 켜 둔 레포가 하나뿐이거나 없으면 고를 것이 없다 — 이름만 적고, 레포는 ⚙︎ 에서 더한다.
                Group {
                    if let only = repos.first {
                        HStack(spacing: 4) {
                            Circle().fill(RepoDot.color(for: only.repo.name)).frame(width: 7, height: 7)
                            Text(only.repo.name)
                        }
                    } else {
                        Text("볼 레포가 없습니다 — ⚙︎ 에서 찾아 체크하세요")
                    }
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                // 탭 글자 자리(줄 여백 9 + 탭 안쪽 9)와 높이(위 6 · 아래 밑줄 자리 7)에 맞춘다.
                .padding(.leading, 18)
                .padding(.top, 6)
                .padding(.bottom, 7)
                // 글자 끝과 구분선 사이를 탭일 때(탭 안쪽 9 + RepoTabBar.gearGap 4)와 맞춘다.
                .padding(.trailing, 13)
            }
            RepoManageGroup()
                // 탭 글자 줄에 맞춘다(아래 2pt 밑줄 자리만큼 올린다 — RepoTabBar 의 › 와 같은 높이).
                .padding(.bottom, 4)
            // 넘칠 때 ⚙︎ 와 창 끝 사이 여백.
            Spacer(minLength: 8)
        }
        .frame(maxWidth: .infinity)
    }
}

/// "│ ⚙︎" — 레포 관리 버튼 앞에 얇은 구분선. 탭 바로 뒤에 붙어도 탭이 하나 더 있는 것처럼 보이지 않게 한다.
private struct RepoManageGroup: View {
    var body: some View {
        HStack(spacing: 6) {
            Divider()
                .frame(height: 14)
            RepoManageButton()
        }
        .fixedSize()
    }
}

/// 레포 줄의 탭: [전체] [레포1] [레포2] … 누르면 그 레포만 보인다.
///
/// 받아 둔 목록을 가리기만 한다 — 조회·알림은 그대로다(그건 ⚙︎ 레포 관리의 켜기·끄기다).
/// 바로 아래 범위 탭(리뷰 대기·승인·전체 PR)과 모양을 다르게 둔다. 둘 다 알약이면 어느 줄이
/// 무엇을 고르는지 섞여 보인다 — 레포는 "어디를" 보느냐라 밑줄 탭, 범위는 "무엇을" 보느냐라 알약이다.
/// ⌘-클릭하면 여러 레포를 같이 본다.
///
/// 레포 이름 앞에 그 레포의 색점을 달고, 고른 탭의 밑줄·건수도 그 색으로 칠한다(RepoDot.color).
/// 글자만으로는 탭끼리 잘 갈리지 않았고(사용자 피드백), 같은 색이 목록 행의 점·레포 칩에도 있어서
/// 고른 레포와 행이 색으로 이어진다. '전체' 는 레포가 아니라 강조색(파랑)을 쓴다.
/// (시안 다섯 가지 중 "색점 + 레포 색 밑줄" — 사용자 선택.)
///
/// 레포가 많으면 옆으로 넘친다. 스크롤 막대를 감춘 줄이라 넘친 쪽 가장자리를 흐리게 하고, 그쪽 끝에
/// "›"(왼쪽이면 "‹")를 띄운다 — 누르면 그쪽으로 민다(마우스 휠은 세로라 옆으로 안 밀린다). 몇 개가 더 있는지는
/// 도움말에 적는다. 예전에는 "+N ›" 알약이었는데 길고 탭 이름을 덮어서, 화살표만 배경 없이 흐림 위에 얹고
/// 화살표 자리는 탭 글자를 아예 비웠다 — 이름이 화살표 앞에서 흐려져 사라진다(시안 다섯 가지 중 B — 사용자 선택).
/// 고른 탭이 밖에 있으면 보이는 곳으로 끌어온다.
/// (필터 팝오버 안 체크 목록과 견줘 보고 이 모양으로 정했다 — 사용자 선택.)
///
/// 레포 탭은 끌어서 순서를 바꾼다(사용자 요청). 끄는 동안 다른 탭 위로 지나가면 그 자리로 바로 옮겨 보이고,
/// 순서는 설정의 레포 목록 순서로 저장된다. '전체' 는 맨 앞에 둔다. 탭이 넘쳐 끌어서 닿지 않는 자리는
/// 우클릭 "왼쪽으로·오른쪽으로 옮기기" 로 간다. 끼울 자리 표시를 따로 그리지 않는다 — 줄 폭이 바뀌면 뒤의
/// "│ ⚙︎" 가 같이 흔들린다(RepoStrip 은 이 줄의 폭을 재서 ⚙︎ 자리를 정한다).
struct RepoTabBar: View {
    @Environment(AppModel.self) private var model
    /// 지금 끌고 있는 레포 탭. 끌기가 줄 밖에서 끝나면 그대로 남지만, 다음 끌기가 시작될 때 바뀐다.
    @State private var draggingRepo: RepoID?

    /// 탭마다 줄 밖으로 잘렸는가. 넘침 표시(›·‹)와 가장자리 흐림이 이걸 본다.
    /// 밀린 거리 대신 탭마다 이 값만 들고 있는다 — 거리를 들고 있으면 미는 동안 매 프레임 다시 그려진다
    /// (그래서 밀던 중에 멈춘 적이 있다). 이 값은 탭이 줄 끝을 넘나들 때만 바뀐다.
    @State private var cuts: [String: Cut] = [:]
    /// 탭들이 줄보다 넓은가. 넓으면 오른쪽 끝에 "›" 자리를 비워 둔다 — 안 비우면 그 표시가 마지막 탭을 덮어
    /// 끝까지 밀어도 그 탭 이름이 안 보였다(실측). 미는 위치와 상관없는 값이라 밀 때마다 바뀌지 않는다.
    @State private var overflows = false

    private enum Cut: Equatable { case none, left, right }
    private enum Side { case left, right }

    private static let space = "repoTabs"
    private static let allTabID = "repo-tab:all"
    /// 화살표 앞에서 탭 이름이 흐려지는 폭.
    private static let fadeWidth: CGFloat = 30
    /// 화살표가 앉는 끝 자리. 여기는 탭 글자를 아예 비운다 — 배경 없는 화살표가 이름 글자와 부딪치지 않게.
    private static let arrowWidth: CGFloat = 18
    /// 줄 양끝의 안쪽 여백. 아래 범위 탭의 글자와 첫 글자 자리를 맞춘다(그쪽은 줄 8 + 알약 안쪽 10, 여기는 9 + 9).
    private static let edgePadding: CGFloat = 9
    /// 오른쪽 "›" 가 차지하는 폭(화살표 자리 + 여백). 그 밑에 깔린 탭은 가려졌으니 잘린 것으로 센다.
    /// 끝까지 밀면 이만큼 비어 있다(예전 "+N ›" 알약은 36 이었다).
    private static let moreZone: CGFloat = 22
    /// 다 들어갈 때 마지막 탭과 뒤의 "│ ⚙︎"(RepoStrip) 사이. 탭 안쪽 9 와 더해 글자에서 구분선까지 13 이다(시안 (b)).
    private static let gearGap: CGFloat = 4
    /// 탭들이 실제로 차지하는 폭. 줄을 이 폭까지만 늘려서, 다 들어가면 뒤의 ⚙︎ 가 마지막 탭 바로 뒤에 붙게 한다.
    /// 처음 재기 전에는 끝없이 둔다(예전처럼 남은 폭을 다 쓴다).
    @State private var contentWidth: CGFloat = .infinity

    var body: some View {
        let repos = model.settings.enabledRepos
        let allShown = model.hiddenRepoKeys.isEmpty
        // 이름만 보이되, 오너만 다른 같은 이름이 있으면 헷갈리지 않게 전체 이름을 쓴다.
        let names = repos.map(\.repo.name)
        let duplicated = Set(names.filter { name in names.filter { $0 == name }.count > 1 })
        let rightZone = overflows ? Self.moreZone : 0
        // 넘치면 끝까지 밀었을 때 마지막 탭이 줄 끝에 붙지 않게 여백 + "›" 자리, 다 들어가면 ⚙︎ 와의 간격만.
        // 넘칠 때가 더 넓어서, 한 번 넘치면 줄 폭이 그만큼 늘어날 때까지 넘친 채로 있다(왔다 갔다 하지 않는다).
        let trailing = overflows ? Self.edgePadding + rightZone : Self.gearGap
        ScrollViewReader { proxy in
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 0) {
                    tab(title: "전체",
                        count: model.visibleCount(showing: nil),
                        isSelected: allShown,
                        dot: nil,
                        tint: .accentColor,
                        help: "모든 레포 보기") {
                        model.turnOff(.repos)
                    }
                    .id(Self.allTabID)
                    .onGeometryChange(for: Cut.self) { Self.cut(of: $0, rightZone: rightZone) } action: { cuts[Self.allTabID] = $0 }
                    ForEach(repos) { config in
                        let color = RepoDot.color(for: config.repo.name)
                        tab(title: duplicated.contains(config.repo.name) ? config.repo.full : config.repo.name,
                            count: model.visibleCount(showing: config.repo),
                            isSelected: !allShown && model.isRepoShown(config.repo),
                            dot: color,
                            tint: color,
                            help: "\(config.repo.full) 만 보기 — ⌘-클릭하면 여러 레포를 같이 봅니다") {
                            // SwiftUI 버튼은 눌린 키를 알려 주지 않는다. 누른 순간의 키보드 상태를 직접 본다.
                            if NSEvent.modifierFlags.contains(.command) {
                                model.toggleRepoInSelection(config.repo)
                            } else {
                                model.showOnly(config.repo)
                            }
                        }
                        .id(Self.tabID(config.repo))
                        .onGeometryChange(for: Cut.self) { Self.cut(of: $0, rightZone: rightZone) } action: {
                            cuts[Self.tabID(config.repo)] = $0
                        }
                        .onDrag {
                            draggingRepo = config.repo
                            return NSItemProvider(object: config.repo.full as NSString)
                        }
                        .onDrop(of: [.plainText],
                                delegate: RepoTabDropDelegate(target: config.repo, dragging: $draggingRepo) { from, to in
                                    withAnimation(.easeInOut(duration: 0.15)) { model.moveRepo(from, to: to) }
                                })
                        .contextMenu {
                            Button("왼쪽으로 옮기기") { model.moveRepo(config.repo, by: -1) }
                                .disabled(repos.first?.repo == config.repo)
                            Button("오른쪽으로 옮기기") { model.moveRepo(config.repo, by: 1) }
                                .disabled(repos.last?.repo == config.repo)
                        }
                    }
                }
                .padding(.leading, Self.edgePadding)
                .padding(.trailing, trailing)
                .onGeometryChange(for: Bool.self) { proxy in
                    // 비워 둔 자리까지 넣어 잰다 — 비우면 더 넓어질 뿐이라 한 번 넘치면 계속 넘친 채로 있다(왔다 갔다 하지 않는다).
                    proxy.size.width > (proxy.bounds(of: .named(Self.space))?.width ?? .infinity) + 1
                } action: { overflows = $0 }
                .onGeometryChange(for: CGFloat.self) { $0.size.width } action: { contentWidth = $0 }
            }
            // 다 들어가면 탭 폭까지만(뒤에 ⚙︎ 가 붙는다), 넘치면 받은 폭을 다 쓴다(⚙︎ 는 오른쪽 끝).
            .frame(maxWidth: contentWidth, alignment: .leading)
            .coordinateSpace(.named(Self.space))
            .mask(edgeFade)
            // 흐림 밖(위)에 얹어야 표시 자체가 흐려지지 않는다.
            .overlay(alignment: .leading) {
                if let target = cutLeft.last {
                    moreButton(count: cutLeft.count, toward: .left) { proxy.scrollTo(target, anchor: .center) }
                }
            }
            .overlay(alignment: .trailing) {
                if let target = cutRight.first {
                    moreButton(count: cutRight.count, toward: .right) { proxy.scrollTo(target, anchor: .center) }
                }
            }
            // 고른 탭이 밖에 있으면 끌어온다 — 툴바에서 다시 보이게 했거나, 지난번에 고른 채 켰을 때.
            .onAppear { reveal(selectedTabID, with: proxy) }
            .onChange(of: selectedTabID) { _, id in reveal(id, with: proxy) }
        }
        .padding(.top, 6)
    }

    /// 지금 고른 탭. 여러 개를 골랐으면 맨 앞의 것.
    private var selectedTabID: String {
        guard !model.hiddenRepoKeys.isEmpty,
              let first = model.settings.enabledRepos.first(where: { model.isRepoShown($0.repo) }) else {
            return Self.allTabID
        }
        return Self.tabID(first.repo)
    }

    private static func tabID(_ repo: RepoID) -> String { "repo-tab:" + PRFilterState.repoKey(repo) }

    private var tabIDs: [String] { [Self.allTabID] + model.settings.enabledRepos.map { Self.tabID($0.repo) } }
    /// 줄 밖으로(반쯤이라도) 잘린 탭들, 줄 순서대로.
    private var cutLeft: [String] { tabIDs.filter { cuts[$0] == .left } }
    private var cutRight: [String] { tabIDs.filter { cuts[$0] == .right } }

    /// 탭 하나가 줄(스크롤 영역) 밖으로 잘렸는가. 반쯤 잘린 것도, 오른쪽 "›" 밑에 깔린 것도 잘린 것으로 친다 —
    /// 다 안 보이면 밀 일이 있다.
    nonisolated private static func cut(of proxy: GeometryProxy, rightZone: CGFloat) -> Cut {
        let frame = proxy.frame(in: .named(space))
        guard let visible = proxy.bounds(of: .named(space))?.width else { return .none }
        if frame.maxX > visible - rightZone + 1 { return .right }
        if frame.minX < -1 { return .left }
        return .none
    }

    /// 줄 밖에 레포가 더 있다는 표시. 누르면 가장 가까운 잘린 탭을 가운데로 끌어온다 — 스크롤 막대가 없고
    /// 마우스 휠(세로)로는 옆으로 밀리지 않아서, 눌러서 넘길 길이 있어야 한다(사용자 피드백).
    /// 미는 데 애니메이션은 걸지 않는다(reveal 주석과 같은 이유).
    private func moreButton(count: Int, toward side: Side, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: side == .left ? "chevron.left" : "chevron.right")
                .font(.system(size: 11, weight: .semibold))
                .foregroundStyle(.secondary)
                // 글자 하나 크기라 누를 자리를 화살표 칸 전체로 넓힌다.
                .frame(width: Self.arrowWidth, height: 18)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        // 탭 글자 줄에 맞춘다(아래 2pt 밑줄 자리만큼 올린다).
        .padding(.bottom, 4)
        .help(side == .left ? "왼쪽에 레포 \(count)개 더 — 누르면 보이게 밉니다"
                            : "오른쪽에 레포 \(count)개 더 — 누르면 보이게 밉니다")
    }

    private func reveal(_ id: String, with proxy: ScrollViewProxy) {
        // '전체' 는 맨 앞이라 밀 일이 없다. 켤 때는 필터를 읽기 전(전체)과 읽은 뒤(고른 탭) 두 번 불리는데,
        // 앞의 것까지 밀면 둘이 겹쳐 고른 탭까지 못 갔다(실측).
        guard id != Self.allTabID else { return }
        // 이미 다 보이는 탭은 그대로 둔다 — 눌러서 고른 탭이 가운데로 튀지 않게. 가려져 있으면(모르면 — 켜자마자)
        // 가운데로 끌어온다. 보일 만큼만 밀면 오른쪽 넘침 표시 밑에 걸쳐 반쯤 가린 채 멈췄다(실측).
        if cuts[id] == Cut.none { return }
        // 첫 배치가 끝나기 전에 밀면 헛돈다. 한 박자 늦춘다.
        // 애니메이션은 걸지 않는다. 걸었더니 몇 초가 지나도 고른 탭까지 못 가고 조금씩만 움직였다(실측).
        DispatchQueue.main.async { proxy.scrollTo(id, anchor: .center) }
    }

    /// 넘친 쪽만 흐리게 하고, 그 끝의 화살표 자리는 탭 글자를 비운다. 넘치지 않으면 양쪽 다 또렷하다.
    private var edgeFade: some View {
        HStack(spacing: 0) {
            Color.clear.frame(width: cutLeft.isEmpty ? 0 : Self.arrowWidth)
            LinearGradient(colors: [.clear, .black], startPoint: .leading, endPoint: .trailing)
                .frame(width: cutLeft.isEmpty ? 0 : Self.fadeWidth)
            Rectangle().fill(.black)
            LinearGradient(colors: [.black, .clear], startPoint: .leading, endPoint: .trailing)
                .frame(width: cutRight.isEmpty ? 0 : Self.fadeWidth)
            Color.clear.frame(width: cutRight.isEmpty ? 0 : Self.arrowWidth)
        }
    }

    /// - Parameters:
    ///   - dot: 이름 앞 색점. '전체' 는 nil.
    ///   - tint: 고른 탭의 밑줄·건수 색.
    ///
    /// 버튼(Button)이 아니라 탭 제스처로 받는다. macOS 의 버튼은 누른 채 끄는 움직임을 제가 먹어서, 탭을 끌어
    /// 순서를 바꿀 수가 없었다. 대신 VoiceOver 가 버튼으로 읽고 누를 수 있게 접근성 정보를 따로 단다.
    private func tab(title: String, count: Int, isSelected: Bool, dot: Color?, tint: Color, help: String,
                     action: @escaping () -> Void) -> some View {
        VStack(spacing: 5) {
            HStack(spacing: 4) {
                if let dot {
                    Circle()
                        .fill(dot)
                        .frame(width: 7, height: 7)
                }
                Text(title)
                    .font(.system(size: 12, weight: isSelected ? .semibold : .regular))
                    .lineLimit(1)
                Text("\(count)")
                    .font(.system(size: 10).monospacedDigit())
                    .foregroundStyle(isSelected ? tint : Color.secondary)
            }
            .padding(.horizontal, 9)
            // 고른 탭 밑줄. 안 고른 탭도 같은 높이를 차지해야 글자가 위아래로 흔들리지 않는다.
            Rectangle()
                .fill(isSelected ? tint : Color.clear)
                .frame(height: 2)
        }
        .contentShape(Rectangle())
        .onTapGesture(perform: action)
        .foregroundStyle(isSelected ? Color.primary : Color.secondary)
        .help(help)
        .accessibilityElement(children: .combine)
        .accessibilityAddTraits(isSelected ? [.isButton, .isSelected] : .isButton)
        .accessibilityAction(.default, action)
    }
}

/// 레포 탭 끌어 옮기기. 끄는 탭이 다른 탭 위에 들어서면 그 자리로 옮긴다 — 놓기 전에 자리가 바뀌어 보인다.
/// 이 줄에서 시작한 끌기만 받는다(다른 앱에서 끌어온 글자가 탭 위를 지나가도 순서가 바뀌지 않게).
private struct RepoTabDropDelegate: DropDelegate {
    let target: RepoID
    @Binding var dragging: RepoID?
    let move: (RepoID, RepoID) -> Void

    func validateDrop(info: DropInfo) -> Bool { dragging != nil }

    func dropEntered(info: DropInfo) {
        guard let dragging, dragging != target else { return }
        move(dragging, target)
    }

    func dropUpdated(info: DropInfo) -> DropProposal? { DropProposal(operation: .move) }

    func performDrop(info: DropInfo) -> Bool {
        dragging = nil
        return true
    }
}
