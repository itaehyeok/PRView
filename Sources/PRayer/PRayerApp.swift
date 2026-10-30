import SwiftUI
import AppKit
import UserNotifications
import PRayerCore

/// 종료 시 진행 중 자식 프로세스를 내리고 대기 중 초안을 저장한다.
final class AppDelegate: NSObject, NSApplicationDelegate {
    @MainActor static var model: AppModel?

    /// 창을 띄우고 데이터를 읽기(bootstrap) 전에, 같은 데이터를 쓰는 PRayer 가 이미 떠 있는지 본다.
    /// 둘이 함께 돌면 설정·초안을 서로 덮어쓴다(InstanceGuard · SingleInstance 주석).
    /// 확인용 사본이면 창을 다른 앱 창 뒤에 깔기 시작한다(BackgroundCopy).
    func applicationWillFinishLaunching(_ notification: Notification) {
        MainActor.assumeIsolated {
            InstanceGuard.resolve()
            #if DEBUG
            BackgroundCopy.start()
            #endif
        }
    }

    /// 종료 안내. 스풀이 있어 리뷰는 앱이 꺼져도 계속 돌고 다음 실행에서 수확되지만,
    /// 그 사실을 모르면 종료를 망설이게 되므로 한 번 알려 준다. 막는 것이 목적이 아니다.
    /// 자동화 탈출구: `defaults write dev.itaehyeok.PRayer skipQuitGuard -bool true`
    /// (killall·kill -9 는 이 훅을 아예 거치지 않는다.)
    @MainActor
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        let count = AppDelegate.model?.activeJobCount ?? 0
        guard count > 0, !UserDefaults.standard.bool(forKey: "skipQuitGuard") else { return .terminateNow }
        let alert = NSAlert()
        alert.messageText = "리뷰 \(count)건이 돌고 있습니다"
        alert.informativeText = """
            종료해도 리뷰는 계속 돌고, 다시 켜면 끝난 결과를 가져옵니다.
            맥이 잠들거나 재부팅되면 그때까지 쓴 토큰은 결과 없이 사라집니다.
            """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "종료")
        alert.addButton(withTitle: "취소")
        return alert.runModal() == .alertFirstButtonReturn ? .terminateNow : .terminateCancel
    }

    func applicationWillTerminate(_ notification: Notification) {
        MainActor.assumeIsolated {
            AppDelegate.model?.teardown()
        }
    }
}

@main
struct PRayerApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @State private var model: AppModel

    init() {
        // 옛 이름의 데이터 폴더·설정을 가장 먼저 옮긴다. 아래에서 폴더를 만들거나 로그를
        // 쓰면 새 폴더가 먼저 생기고, UserDefaults 를 읽으면 빈 설정으로 시작한다.
        LegacyMigration.run()
        // 자식 프로세스 파이프가 먼저 닫히면 SIGPIPE 로 앱이 죽을 수 있다.
        signal(SIGPIPE, SIG_IGN)
        AppPaths.ensureDirectories()
        Log.info("\(AppInfo.name) 시작 (build \(Bundle.main.infoDictionary?["CFBundleVersion"] as? String ?? "?"))", "app")
        let model = AppModel()
        _model = State(initialValue: model)
        MainActor.assumeIsolated { AppDelegate.model = model }
    }

    /// 목록 탭을 고른다. 기간은 그 탭이 기억하던 값을 쓴다(탭 버튼을 누른 것과 같다).
    @MainActor
    private func show(_ kind: PRListScopeKind) {
        // 목록이 접혀 있으면 펴 준다. 안 그러면 화면은 그대로인데 조회만 다시 돌아서
        // "눌렀는데 아무 일도 안 일어난" 것처럼 보인다(@AppStorage 가 이 값을 읽는다).
        UserDefaults.standard.set(true, forKey: "showPRList")
        let target = model.scope(for: kind)
        guard model.listScope != target else { return }
        model.listScope = target
    }

    var body: some Scene {
        // Window(단일 창). WindowGroup 은 ⌘N 으로 창이 늘어나고 그때마다 bootstrap 이 다시 돈다.
        Window(AppInfo.displayName, id: "main") {
            MainWindow()
                .modifier(DebugLaunchModifier())
                .environment(model)
                .frame(minWidth: 1080, minHeight: 640)
                .task { await model.bootstrap() }
        }
        .windowToolbarStyle(.unified)
        .commands {
            CommandGroup(replacing: .appInfo) {
                Button("About \(AppInfo.displayName)") { AboutPanel.show() }
            }
            CommandGroup(after: .newItem) {
                Button("새로고침") { Task { await model.refreshByUser() } }
                    .keyboardShortcut("r", modifiers: .command)
                Button("선택한 PR 지금 리뷰 (초안만 생성)") { model.reviewSelectedNow() }
                    .keyboardShortcut("r", modifiers: [.command, .shift])
            }
            // 목록 탭을 메뉴로 낸다. 툴바 탭에만 두면 단축키를 발견할 길이 없고,
            // macOS 시스템 설정(키보드 > 단축키 > 앱 단축키)은 **메뉴 항목 제목**으로
            // 재정의하기 때문에 메뉴에 없는 키는 사용자가 바꿀 수도 없다.
            //
            // 뷰가 아니라 여기(App 수준)에 거는 이유: 목록은 `if showPRList` 로 조건부라
            // 접어 두면 뷰에 건 단축키가 계층에서 통째로 사라진다.
            // `CommandMenu("보기")` 로 만들면 macOS 가 이미 주는 View 메뉴 **옆에** 같은 뜻의
            // 메뉴가 하나 더 생긴다(실측: File Edit View 보기 Window Help).
            // `.sidebar` 그룹에 넣어 원래 있는 View 메뉴 안으로 들어가게 한다.
            CommandGroup(after: .sidebar) {
                // 순서는 화면의 탭과 같아야 한다 — PRListScopeKind 선언 순서가 기준이다.
                // 메뉴에서 세 번째인데 화면에서 두 번째면, 키를 외우는 근거가 사라진다.
                Button(PRListScopeKind.open.shortLabel) { show(.open) }
                    .keyboardShortcut("1", modifiers: .command)
                Button(PRListScopeKind.myApprovals.shortLabel) { show(.myApprovals) }
                    .keyboardShortcut("2", modifiers: .command)
                Button(PRListScopeKind.recentAll.shortLabel) { show(.recentAll) }
                    .keyboardShortcut("3", modifiers: .command)

                Divider()

                // 상세 탭. 목록 탭과 같은 1·2·3 을 쓰되 ⌃ 를 더 붙인다 — 화면에서 아래위로
                // 나란히 있는 두 줄의 탭이라, 다른 숫자를 주면 어느 줄이 몇 번인지 외워야 한다.
                // 순서는 화면의 탭과 같아야 한다(DetailTab 선언 순서가 기준이다).
                ForEach(Array(DetailTab.allCases.enumerated()), id: \.element) { index, item in
                    Button(item.label) { model.detailTab = item }
                        .keyboardShortcut(KeyEquivalent(Character("\(index + 1)")),
                                          modifiers: [.control, .command])
                        // 고른 PR 이 없으면 상세가 없다. 눌러도 아무 일이 없는 메뉴는 꺼 둔다.
                        .disabled(model.selectedPR == nil)
                }

                Divider()

                // 상세 칸을 팀 통계로 바꾼다(툴바 "통계" 와 같다). 다시 누르면 보던 PR 로 돌아간다.
                Button("팀 통계") { model.toggleTeamStats() }
                    .keyboardShortcut("s", modifiers: [.command, .option])

                Divider()

                // 폰트 설정 화면을 걷어내고 여기로 옮겼다. 글자 크기는 "지금 조금 크게" 가
                // 거의 전부라, 설정 창을 열어 세 군데를 따로 맞추는 것보다 ⌘+/⌘- 가 맞다.
                Button("글자 크게") { model.changeFontSize(by: 1) }
                    .keyboardShortcut("+", modifiers: .command)
                Button("글자 작게") { model.changeFontSize(by: -1) }
                    .keyboardShortcut("-", modifiers: .command)
                Button("글자 기본 크기") { model.resetFontSize() }
                    .keyboardShortcut("0", modifiers: .command)
                    .disabled(model.isDefaultFontSize)

            }
        }

        Settings {
            SettingsView()
                .environment(model)
                .frame(width: 620, height: 560)
        }

        // 툴바 "상태" → "문제 기록 보기…" 로 연다. 단일 창이라 여러 번 눌러도 하나만 뜬다.
        Window("문제 기록", id: "problems") {
            ProblemsView()
                .environment(model)
        }
        .defaultSize(width: 620, height: 540)
    }
}
