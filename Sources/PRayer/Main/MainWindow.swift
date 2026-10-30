import SwiftUI
import PRayerCore

struct MainWindow: View {
    @Environment(AppModel.self) private var model
    /// PR 목록을 접었는지. 앱을 다시 켜도 유지된다.
    /// (.all = 셋 다 / .doubleColumn = 목록+상세 / .detailOnly = 상세만)
    /// PR 목록 열을 펼쳐 두었는가.
    @AppStorage("showPRList") private var showPRList = true
    @AppStorage("dismissedNotificationPrompt") private var dismissedNotificationPrompt = false
    /// PR 목록 폭. 드래그로 바꾼 값을 그대로 유지한다.
    @AppStorage("prListWidth") private var listWidth = 420.0
    /// 드래그 시작 시점의 폭. 매 프레임 누적으로 계산하면 값이 튄다.
    @State private var dragStartWidth: Double?

    var body: some View {
        // 알림 켜기·새 버전 안내는 할 일을 알려 주는 것이라 위에 자리를 차지해도 된다.
        // 반면 결과·오류 배너는 뜰 때마다 화면을 밀어내 위쪽 내용이 잘렸다.
        // 그래서 아래쪽에 떠 있는 토스트로 바꾸고, 오류가 아니면 스스로 사라지게 한다.
        VStack(spacing: 0) {
            updatePrompt
            notificationPrompt
            // 볼 레포(탭)와 레포 관리(⚙︎)는 창 너비 한 줄에(RepoStrip 주석). 안내 띠 아래, 목록·상세 바로 위에 둔다 —
            // 안내가 떠도 탭이 거르는 목록과 붙어 있다.
            RepoStrip()
            Divider()
            splitView
        }
        .overlay(alignment: .bottom) { bannerToast }
        .sheet(isPresented: Binding(get: { model.showOnboarding }, set: { model.showOnboarding = $0 })) {
            OnboardingView()
                .interactiveDismissDisabled()
        }
        // 변경이 많은 PR 은 큐에 넣기 전에 묻는다. 창을 닫는 길이 취소밖에 없으면
        // 실수로 바깥을 눌렀을 때 요청이 사라진 건지 취소된 건지 알 수 없으므로,
        // 어느 쪽으로 닫히든 요청을 비운다.
        .sheet(item: Binding(get: { model.pendingLargeReview },
                             set: { if $0 == nil { model.cancelPendingLargeReview() } })) { request in
            LargeReviewConfirm(request: request)
        }
        // 한 파일이 1,000줄 넘게 바뀌었으면 "빼고 리뷰할까요?" 를 묻는다. 닫히는 길이 어느 쪽이든 요청을 비운다(위와 같은 이유).
        .sheet(item: Binding(get: { model.pendingSkipFiles },
                             set: { if $0 == nil { model.cancelPendingSkipFiles() } })) { request in
            SkipFilesSheet(request: request)
        }
        // 전체 리뷰를 처음 누르면 PR 스냅샷을 받을지 묻는다. 닫히는 길이 어느 쪽이든 요청을 비운다(위와 같은 이유).
        .sheet(item: Binding(get: { model.pendingSnapshotClone },
                             set: { if $0 == nil { model.cancelPendingSnapshotClone() } })) { request in
            SnapshotCloneConfirm(request: request)
        }
        // 목록에서 여러 개 골라 우클릭 → 리뷰. 위 세 확인을 한 창에 모아 한 번만 묻는다. 닫히는 길이 어느 쪽이든 요청을 비운다.
        .sheet(item: Binding(get: { model.pendingBatchReview },
                             set: { if $0 == nil { model.cancelPendingBatchReview() } })) { request in
            BatchReviewSheet(request: request)
        }
        // 내 PR 우클릭 → 슬랙 리뷰 요청 글 만들기(보내기는 그 창에서).
        .sheet(item: Binding(get: { model.slackRequest }, set: { model.slackRequest = $0 })) { draft in
            SlackRequestSheet(draft: draft)
        }
        // 레포 관리 팝오버에서 누른 "지우기"·"연결 끊기" 의 확인. 팝오버 안에서 띄우면 같이 닫혀 버릴 수 있다.
        .alert(model.pendingCloneAction?.title ?? "",
               isPresented: Binding(get: { model.pendingCloneAction != nil },
                                    set: { if !$0 { model.pendingCloneAction = nil } }),
               presenting: model.pendingCloneAction) { action in
            Button(action.confirmTitle, role: .destructive) { model.performPendingCloneAction() }
            Button("취소", role: .cancel) {}
        } message: { action in
            Text(action.message)
        }
    }

    private func toggleList() {
        showPRList.toggle()
    }

    private static let minListWidth = 320.0
    private static let minDetailWidth = 460.0
    private static let defaultListWidth = 420.0

    /// 창이 좁아지면 상세가 최소 폭을 지킬 수 있게 목록 폭을 줄인다.
    private func clampedListWidth(in totalWidth: Double) -> Double {
        guard totalWidth > 0 else { return listWidth }
        let upper = max(Self.minListWidth, totalWidth - Self.minDetailWidth - 1)
        return min(max(Self.minListWidth, listWidth), upper)
    }

    /// 드래그로 목록 폭을 바꾸는 구분선(ResizeDivider 주석 참고).
    private var listDivider: some View {
        ResizeDivider(help: "드래그로 목록 폭 조절 · 더블클릭하면 기본 폭",
                      onDrag: { translation in
                          let base = dragStartWidth ?? listWidth
                          if dragStartWidth == nil { dragStartWidth = base }
                          listWidth = max(Self.minListWidth, base + translation)
                      },
                      onDragEnd: { dragStartWidth = nil },
                      onReset: { listWidth = Self.defaultListWidth })
    }

    @ViewBuilder
    private var detailPane: some View {
        if model.showingTeamStats {
            TeamStatsView()
        } else if let pr = model.selectedPR {
            // PR 을 바꿀 때 스크롤 위치·렌더 캐시가 초기화되도록 식별자를 준다.
            // 탭 선택만은 여기서 초기화되면 안 되므로 모델에 있다(AppModel.detailTab).
            // 이 id 는 HStack 안에 있어 폭에는 영향을 주지 않는다.
            PRDetailView(pr: pr)
                .id(pr.id)
        } else {
            ContentUnavailableView("PR 을 선택하세요",
                                   systemImage: "sidebar.right",
                                   description: Text("왼쪽 목록에서 PR 을 고르면 리뷰 스레드와 AI 리뷰 결과를 볼 수 있습니다."))
        }
    }

    private var splitView: some View {
        // 사이드바를 없애고 레포·필터·상태·큐를 툴바와 목록 헤더로 옮겼다.
        // 목록 폭이 220~320pt 넓어지고, 필터가 걸려 있다는 사실은 헤더의 숫자로 항상 보인다.
            // HSplitView 를 쓰지 않는다. Group 은 분할뷰 안에서 투명해서 두 번째 자식이
            // 곧 `PRDetailView().id(pr.id)` 가 되는데, PR 을 바꾸면 그 자식이 교체되면서
            // NSSplitView 가 분할 위치를 잃고 idealWidth 로 되돌아간다(실측: 목록 클릭마다 폭 초기화).
            // 폭을 직접 들고 있으면 선택·목록 접기·앱 재시작에도 유지된다.
            GeometryReader { geometry in
                HStack(spacing: 0) {
                    if showPRList {
                        let width = clampedListWidth(in: geometry.size.width)
                        VStack(spacing: 0) {
                            PRListView()
                                // 행이 폭에 따라 무엇을 보여줄지 결정한다(PRRowDensity 주석 참고).
                                .environment(\.prRowDensity, PRRowDensity(width: width))
                            // 지금 보는 앱 버전 — 목록 왼쪽 아래 한 줄(VersionFooter 주석). 개발 빌드는 오른쪽에 목록 비우기 버튼.
                            HStack(spacing: 8) {
                                VersionFooter()
                                Spacer(minLength: 0)
                                #if DEBUG
                                if !DemoMode.isOn {
                                    DevListResetButtons()
                                }
                                #endif
                            }
                            .padding(.horizontal, 16)
                            .padding(.vertical, 6)
                        }
                        .frame(width: width)
                        listDivider
                    }
                    detailPane
                        .frame(maxWidth: .infinity, maxHeight: .infinity)
                }
            }
        .toolbar { toolbarContent }
        // 창 제목은 이름만. 한동안 "PRView - PR Review Manager" 로 설명을 붙였다가 뺐다(2026-10-20 사용자:
        // "별로다"). 설명(AppInfo.subtitle)은 정보 창·온보딩·상태 팝오버에만 남는다.
        .navigationTitle(AppInfo.displayName)
    }

    @ToolbarContentBuilder
    private var toolbarContent: some ToolbarContent {
        // 목록 접기/펴기. **양쪽 상태에서 같은 자리**여야 한다 — 예전에는 펼쳤을 때는
        // 패널 안 검색줄에, 접었을 때는 툴바에 나타나서 같은 버튼을 매번 다시 찾아야 했다.
        // macOS 도 사이드바 토글을 툴바 맨 왼쪽에 두므로 그 관례를 따른다.
        //
        // opacity(0) 로 숨기지 않는다 — 투명해질 뿐 툴바 슬롯은 그대로 차지해서
        // 신호등과 첫 버튼 사이에 빈 자리가 남는다(그래서 항목을 조건부로 넣고 뺐었다).
        ToolbarItem(placement: .navigation) {
            Button {
                toggleList()
            } label: {
                ToolbarButtonLabel(title: showPRList ? "접기" : "목록", tint: .primary) {
                    Image(systemName: showPRList ? "sidebar.squares.leading" : "rectangle.righthalf.inset.filled")
                }
            }
            .help(showPRList ? "PR 목록 접기 (⌘⌥L)" : "PR 목록 보이기 (⌘⌥L)")
            .keyboardShortcut("l", modifiers: [.command, .option])
            // 신호등 바로 옆에 붙으면 창 조작 버튼과 한 덩어리로 보인다. 툴바 첫 항목에만
            // 앞 여백을 준다(툴바 자체에는 신호등과의 간격을 조절하는 수단이 없다).
            .padding(.leading, 10)
        }
        ToolbarItemGroup {
            if model.activeJobCount > 0 {
                QueueToolbarMenu()
            }
            // macOS 툴바는 Label 을 기본으로 **아이콘만** 그린다. 그대로 두면 "일부만" 같은 글자가
            // 사라지고 아이콘 하나만 남아 무슨 표시인지 알 수 없다. 이름을 직접 아래에 붙인다.
            //
            // "게시 대기 N" 표시는 지웠다(사용자 결정). 게시하지 않은 초안을 PR 이 머지·닫힌 뒤에도
            // 계속 세서 숫자가 부풀었고(실측: 24건 중 23건이 리뷰 대기 목록에 없는 PR), 누를 수도 없어
            // 할 일을 알려 주지 못했다. 초안은 각 PR 의 AI 리뷰 탭에 그대로 있다.
            if model.listTruncated {
                ToolbarButtonLabel(title: "일부만", tint: .orange) {
                    Image(systemName: "exclamationmark.circle")
                }
                .help("PR 이 많아 일부만 받았습니다. 탭의 기간을 짧게 잡으면 전부 보입니다.")
            }
            Button {
                model.toggleTeamStats()
            } label: {
                // 켜져 있으면 강조색 — 상세 칸이 지금 통계라는 표시이자, 다시 누르면 닫힌다는 표시.
                ToolbarButtonLabel(title: "통계", tint: model.showingTeamStats ? .accentColor : .primary) {
                    Image(systemName: model.showingTeamStats ? "chart.bar.fill" : "chart.bar")
                }
            }
            .help(model.showingTeamStats
                  ? "PR 로 돌아가기 (⌥⌘S)"
                  : "팀 통계 — 주간·월간 커밋·PR·Approve·코멘트 순위 (⌥⌘S)")
            StatusToolbarMenu()
            Button {
                Task { await model.refreshByUser() }
            } label: {
                ToolbarButtonLabel(title: "새로고침", tint: .primary) {
                    Image(systemName: "arrow.clockwise")
                }
            }
            .help("새로고침 (⌘R)")
            .disabled(model.isRefreshing)
        }
    }

    /// 새 버전 안내 줄. 툴바 "상태" 팝오버 안에만 있으면 거기를 열어 보기 전까지 모른다.
    /// X 는 이번 실행 동안만 숨긴다(다음에 켜면 다시 뜬다) — 영영 안 보이게 하면 업데이트를 잊는다.
    @ViewBuilder
    private var updatePrompt: some View {
        if model.showsUpdatePrompt, let update = model.availableUpdate {
            HStack(spacing: 10) {
                Image(systemName: "arrow.down.circle.fill").foregroundStyle(.blue)
                VStack(alignment: .leading, spacing: 2) {
                    Text("새 버전 v\(update.version) 이 나왔습니다. 지금은 v\(UpdateCheck.currentVersion()) 입니다.")
                        .font(.callout)
                    // 실패 이유를 누른 자리에 적는다. 창 아래 토스트로만 띄웠더니 팀원에게는
                    // "눌러도 아무 반응이 없다" 로 보였다(순식간에 실패하면 버튼 글자도 안 바뀐다).
                    if let failure = model.updateFailure {
                        Text(failure)
                            .font(.caption)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
                Spacer()
                Button(model.isUpdating ? "업데이트 받는 중…" : (model.updateFailure == nil ? "앱에서 업데이트" : "다시 시도")) {
                    model.runUpdate()
                }
                .buttonStyle(.link)
                .disabled(model.isUpdating)
                Button {
                    model.dismissedUpdateVersion = update.version
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("이번 실행 동안 숨깁니다. 툴바의 '상태' 에서도 업데이트할 수 있습니다.")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.thinMaterial)
        }
    }

    @ViewBuilder
    private var notificationPrompt: some View {
        if model.notificationStatus == .notDetermined, !dismissedNotificationPrompt {
            HStack(spacing: 10) {
                Image(systemName: "bell.badge").foregroundStyle(.orange)
                Text("리뷰가 끝났을 때 알림을 받으려면 알림을 켜세요.")
                    .font(.callout)
                Spacer()
                Button("알림 켜기") { Task { await model.enableNotifications() } }
                    .buttonStyle(.link)
                Button {
                    dismissedNotificationPrompt = true
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
                .help("이 안내를 숨깁니다. 설정 → 알림에서 언제든 켤 수 있습니다.")
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 8)
            .background(.thinMaterial)
        }
    }

    /// 아래쪽에 떠 있는 토스트. 화면을 밀어내지 않는다.
    /// 오류는 남기고(원인을 읽어야 한다), 정보·경고는 스스로 사라진다.
    @ViewBuilder
    private var bannerToast: some View {
        if let banner = model.banner {
            HStack(spacing: 10) {
                if banner.inProgress {
                    ProgressView()
                        .controlSize(.small)
                } else {
                    Image(systemName: symbol(for: banner.kind))
                        .foregroundStyle(color(for: banner.kind))
                }
                Text(banner.message)
                    .font(.callout)
                    .lineLimit(4)
                    .fixedSize(horizontal: false, vertical: true)
                if let title = banner.actionTitle, let action = banner.action {
                    Button {
                        action()
                    } label: {
                        if banner.opensGitHub {
                            GitHubLinkLabel(title: title, markSize: 12)
                        } else {
                            Text(title)
                        }
                    }
                    .buttonStyle(.link)
                }
                Button {
                    model.banner = nil
                } label: {
                    Image(systemName: "xmark")
                }
                .buttonStyle(.borderless)
            }
            .padding(.horizontal, 14)
            .padding(.vertical, 10)
            .frame(maxWidth: 620)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 10))
            .overlay(RoundedRectangle(cornerRadius: 10).stroke(color(for: banner.kind).opacity(0.35), lineWidth: 1))
            .shadow(color: .black.opacity(0.18), radius: 12, y: 4)
            .padding(.bottom, 16)
            .padding(.horizontal, 16)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .task(id: banner.id) {
                // 오류는 사용자가 닫을 때까지 남긴다. 기다리는 안내는 기다림이 끝나면 앱이 바꾼다.
                guard banner.kind != .error, !banner.inProgress else { return }
                try? await Task.sleep(for: .seconds(banner.kind == .warning ? 12 : 6))
                if model.banner?.id == banner.id {
                    withAnimation(.easeOut(duration: 0.2)) { model.banner = nil }
                }
            }
        }
    }

    private func symbol(for kind: Banner.Kind) -> String {
        switch kind {
        case .info: return "info.circle.fill"
        case .success: return "checkmark.circle.fill"
        case .warning: return "exclamationmark.triangle.fill"
        case .error: return "xmark.octagon.fill"
        }
    }

    private func color(for kind: Banner.Kind) -> Color {
        switch kind {
        case .info: return .accentColor
        case .success: return .green
        case .warning: return .orange
        case .error: return .red
        }
    }
}
