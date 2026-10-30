import SwiftUI
import AppKit
import PRayerCore

/// 지금 보는 앱의 버전과 베타 여부 — 목록 왼쪽 아래 한 줄. 무슨 버전을 보고 있는지 알 길이 없었다(사용자 피드백).
///
/// 툴바 오른쪽에 아이콘·이름으로 있던 것을 여기로 옮겼다(사용자 선택 B안). 늘 보이기만 하고 누를 일은 없는
/// 표시가 버튼들 사이에서 자리를 차지했다. 베타·개발 빌드만 색 점을 달고, 정식은 점 없이 회색으로 둔다 —
/// 평소 상태는 조용히, 다른 판일 때만 눈에 띄게(사용자 결정). 목록을 접으면 같이 숨지만 상태 메뉴 맨 위에도 버전이 있다.
///
/// 베타와 정식은 같은 파일이라, 공개 저장소에 이 버전이 올라가 있는지로 가른다(AppModel.buildKind).
/// 아직 모르면(오프라인·확인 전) 버전만 적는다 — 베타라고 단정하지 않는다. 글자는 "v0.5.0 베타 3" 처럼
/// 버전 뒤에 붙인다(AppModel.versionLabel).
struct VersionFooter: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 5) {
            if let tint {
                Circle()
                    .fill(tint)
                    .frame(width: 6, height: 6)
            }
            Text(model.versionLabel)
                .foregroundStyle(tint ?? Color.secondary)
        }
        .font(.system(size: 10.5))
        .lineLimit(1)
        .help("\(AppInfo.displayName) \(model.versionSummary)")
    }

    /// 점과 글자 색. 정식·확인 전은 nil — 점 없이 회색.
    private var tint: Color? {
        switch model.buildKind {
        case .beta: return .purple
        case .development: return .orange
        case .release, .unknown: return nil
        }
    }
}

#if DEBUG
/// 개발 빌드에만 — 목록 아래 버전 줄 오른쪽. 지난 목록을 메모리·디스크에서 지우고 처음 받는 것처럼 다시 받아, 받는 중
/// 화면(빈 행 자리)을 다시 보려고(사용자 요청 2026-10-28). 데모 모드(README 캡처)에서는 숨긴다.
struct DevListResetButtons: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        HStack(spacing: 10) {
            Button("이 탭 비우기") { model.debugClearLists(all: false) }
                .help("지금 탭의 지난 목록을 지우고 다시 받습니다")
            Button("모든 탭 비우기") { model.debugClearLists(all: true) }
                .help("To review·Approved·All PRs 의 지난 목록을 모두 지우고 지금 탭을 다시 받습니다")
        }
        .buttonStyle(.borderless)
        .font(.system(size: 10.5))
        .foregroundStyle(.orange)
        .lineLimit(1)
    }
}
#endif

/// 툴바에서 여는 팝오버 버튼. 메뉴로는 두 줄 라벨·진행 막대를 그릴 수 없어 팝오버를 쓴다.
/// 툴바 버튼 라벨 — 아이콘이 위, 이름이 아래.
///
/// 이름을 아이콘 옆에 붙이면 버튼이 옆으로 길어지고, 한 줄에 아이콘·글자·화살표가 섞여
/// 어디까지가 한 버튼인지 경계가 흐려진다. 아래로 내리면 버튼 폭이 이름 길이에 좌우되지 않고
/// 아이콘들이 같은 높이로 줄을 맞춘다(macOS 의 "아이콘과 텍스트" 툴바와 같은 배치).
struct ToolbarButtonLabel<Icon: View>: View {
    let title: String
    var tint: Color = .secondary
    var showsChevron = false
    @ViewBuilder var icon: Icon

    var body: some View {
        // 아이콘과 이름 사이 간격. 붙어 있으면 둘이 한 덩어리로 읽힌다.
        //
        // 화면을 픽셀로 재서 정한 값이다(2x 캡처에서 어두운 픽셀 행 위치):
        //   spacing 3  → 실제 간격 4pt   (거의 붙어 보인다)
        //   spacing 6  → 7pt
        //   spacing 10 → 11pt            ← 여기서 확실히 떨어져 보이고, 툴바 높이 안에서 안 잘린다
        VStack(spacing: 6) {
            HStack(spacing: 2) {
                icon
                if showsChevron {
                    Image(systemName: "chevron.down").font(.system(size: 7, weight: .bold))
                }
            }
            .frame(height: 13)
            Text(title)
                .font(.system(size: 9))
                .lineLimit(1)
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 6)
//        .padding(.vertical, 2)
        .padding(.top, 5)
        .padding(.bottom, 2)
        .contentShape(Rectangle())
    }
}

struct ToolbarPopover<Label: View, Content: View>: View {
    /// DEBUG 빌드에서 환경 변수 `PRAYER_DEBUG_OPEN_POPOVER` 가 이 값이면 켜자마자 연다.
    /// 버튼을 누를 수 없는 확인(접근성 권한 없이 화면만 찍어 보는 실측)에서 팝오버를 띄워 보려고 둔다 —
    /// `open --env PRAYER_DEBUG_OPEN_POPOVER=repos <앱>`.
    var debugID: String?
    @ViewBuilder var label: Label
    @ViewBuilder var content: Content

    @State private var isPresented = false

    var body: some View {
        Button {
            isPresented.toggle()
        } label: {
            label
        }
        .popover(isPresented: $isPresented, arrowEdge: .bottom) {
            content
                .padding(14)
                .frame(minWidth: 300)
        }
        #if DEBUG
        .task {
            guard let debugID, ProcessInfo.processInfo.environment["PRAYER_DEBUG_OPEN_POPOVER"] == debugID else { return }
            // 창과 툴바가 자리를 잡기 전에 열면 팝오버가 엉뚱한 데 붙거나 안 뜬다.
            try? await Task.sleep(for: .seconds(2))
            isPresented = true
        }
        #endif
    }
}

// MARK: - 레포

/// 레포 관리 — 레포 줄(RepoStrip)의 ⚙︎(탭 바로 뒤, 넘치면 오른쪽 끝). 볼 레포를 찾아 더하고, 켜고 끄고, 전체 리뷰 폴더를 정한다.
///
/// 예전에는 툴바의 "레포 N개" 메뉴였다. 레포 탭을 툴바 아래 창 너비 줄로 옮기면서 그 줄 끝으로 왔다 —
/// 볼 레포(탭)와 조회할 레포(이 팝오버)가 한 줄에 모인다(RepoStrip 주석).
struct RepoManageButton: View {
    @Environment(AppModel.self) private var model

    var body: some View {
        ToolbarPopover(debugID: "repos") {
            Image(systemName: "gearshape")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
                .frame(width: 26, height: 22)
                .contentShape(Rectangle())
        } content: {
            // 설정 창 "레포·팀 규칙" 탭과 같은 목록(RepoPickerStep)이다 — 레포를 찾아 고르고, 켜고 끄고,
            // 전체 리뷰 폴더까지 여기서 정한다. 예전에는 "레포·팀 규칙 설정…" 으로 설정 창에 보냈다(사용자 요청).
            // "승인 임계값 다시 읽기" 도 뺐다 — 앱을 켤 때·새로고침(⌘R)·레포를 켤 때 같이 다시 읽는다.
            VStack(alignment: .leading, spacing: 8) {
                Text("레포").font(.caption.weight(.semibold)).foregroundStyle(.secondary)
                RepoPickerStep(showsTitle: false, showsClonePaths: true, compact: true)
            }
            .frame(width: 420)
            // 검색은 받아 둔 레포·조직 목록을 바탕으로 한다(조직을 알아야 org: 로 찾는다).
            // 설정 창은 열 때마다 받지만, 팝오버는 자주 여닫으니 앱을 켜고 처음 열 때 한 번만 받는다.
            .task {
                if model.repoOptions.isEmpty { await model.loadRepoOptions() }
            }
        }
        // 툴바 밖이라 기본 버튼 모양(테두리)을 빼고 아이콘만 둔다.
        .buttonStyle(.borderless)
        .help("레포 관리 — 볼 레포를 찾아 더하고, 켜고 끄고, 전체 리뷰 폴더를 정합니다")
    }
}

/// 레포 줄 오른쪽 — 목록에 보이는 건수와, 한 건도 안 보일 때 그 까닭(레포 관리 팝오버).
struct RepoListStatus: View {
    @Environment(AppModel.self) private var model
    let config: RepoConfig
    /// 아이콘·"숨김 N" 에 마우스가 올라가 있는 동안 줄 아래에 펼 이유. 줄(RepoOptionRow)이 그린다.
    @Binding var hint: String?

    private var fetched: Int { model.prs.filter { $0.repo == config.repo }.count }
    private var visible: Int { model.visiblePRs.filter { $0.repo == config.repo }.count }
    private var hiddenAll: Bool { fetched > 0 && visible == 0 }
    private var reason: AppModel.RepoHiddenReason { model.hiddenReason(for: config.repo) }
    private var hiddenByRepoTab: Bool { config.enabled && !model.isRepoShown(config.repo) }

    private static let repoTabHint = "위쪽 레포 탭에서 뺀 레포입니다 — 목록에서만 숨기고 조회·알림은 그대로입니다. 누르면 다시 보입니다."

    /// 검색어 때문에 가려졌는가. 검색어는 쳐 두고 잊기 쉬워서 이때만 주황 경고를 띄운다.
    /// 숨길 사람·라벨은 내가 정해 둔 것이라 경고가 아니라 "숨김 N" 으로 적는다(사용자 결정 —
    /// 숨길 사람의 PR 만 있는 레포가 늘 경고로 떠서 "내가 뺀 건데 왜 느낌표냐" 였다).
    private func searchHides(_ reason: AppModel.RepoHiddenReason) -> Bool {
        reason.byFilter[.search] != nil
    }

    var body: some View {
        HStack(spacing: 8) {
            if hiddenByRepoTab {
                countText
                // 위쪽 레포 탭에서 뺀 레포. 사용자가 고른 상태라 경고(주황)가 아니라 눈 아이콘으로 둔다.
                // 누르면 이 레포만 다시 보인다(탭에서 같이 고른 것처럼) — 필터를 통째로 풀면 고른 것이 다 풀린다.
                Button {
                    model.setRepoShown(config.repo, true)
                } label: {
                    Image(systemName: "eye.slash")
                        .foregroundStyle(.secondary)
                }
                .buttonStyle(.borderless)
                .help(Self.repoTabHint)
                .onHover { show($0, Self.repoTabHint) }
            } else if hiddenAll {
                let reason = self.reason
                let text = explain(reason)
                if searchHides(reason) {
                    countText
                    // 검색어만 지운다. 숨길 사람·라벨까지 끄면 내가 정해 둔 것이 함께 풀린다.
                    Button {
                        model.turnOff(.search)
                    } label: {
                        Image(systemName: "exclamationmark.triangle.fill")
                            .foregroundStyle(.orange)
                    }
                    .buttonStyle(.borderless)
                    .help(text)
                    .onHover { show($0, text) }
                } else if reason.filtersCanHelp {
                    // 숨길 사람·라벨에 걸려 다 안 보인다. 건수 자리에 회색 글자로만 — 아이콘을 달지 않는다.
                    Text("숨김 \(fetched)")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                        .help(text)
                        .onHover { show($0, text) }
                } else {
                    countText
                    // 필터가 원인이 아니면(탭 조건·처리함) 풀 것이 없으므로 버튼이 아니라 표시만 한다 —
                    // 눌러도 아무 일이 없는 버튼은 "고장" 으로 읽힌다.
                    Image(systemName: "info.circle.fill")
                        .foregroundStyle(.secondary)
                        .help(text)
                        .onHover { show($0, text) }
                }
            } else {
                countText
            }
        }
    }

    private var countText: some View {
        Text(visible == fetched ? "\(fetched)" : "\(visible)/\(fetched)")
            .font(.caption.monospacedDigit())
            .foregroundStyle(.secondary)
    }

    /// 왜 한 건도 안 보이는지. 제목 한 줄, 이유는 한 줄에 하나(건수와 함께), 무엇을 하면 되는지 한 줄.
    /// 한 문장으로 이어 쓰면 팝오버 폭에서 "2건" 만 다음 줄로 넘어가 읽기 어려웠다.
    private func explain(_ reason: AppModel.RepoHiddenReason) -> String {
        var parts: [String] = []
        for (kind, count) in reason.byFilter.sorted(by: { $0.value > $1.value }) {
            parts.append("\(kind.label)\(names(for: kind, in: reason)) — \(count)건")
        }
        if reason.scopeExcluded > 0 {
            parts.append(model.listScope.kind == .open
                         ? "닫힘·머지이거나 내가 이미 Approve 함 — \(reason.scopeExcluded)건"
                         : "'\(model.listScope.label)' 탭 조건에 안 맞음 — \(reason.scopeExcluded)건")
        }
        if reason.movedToMyPRs > 0 { parts.append("내가 올린 PR 이라 맨 위 그룹으로 감 — \(reason.movedToMyPRs)건") }
        if reason.dismissed > 0 { parts.append("내가 처리해서 뺌 — \(reason.dismissed)건") }
        guard !parts.isEmpty else { return "받은 \(fetched)건이 모두 목록에서 빠졌습니다." }

        var lines = ["받은 \(fetched)건이 다 안 보이는 이유"] + parts.map { "· " + $0 }
        if searchHides(reason) {
            // 검색어는 레포마다가 아니라 목록 전체에 걸린다. 누르면 다른 레포 목록도 바뀐다는 것을 미리 말한다.
            lines.append("경고 아이콘을 누르면 검색어를 지웁니다(모든 레포에 적용).")
        }
        if reason.byFilter[.hideIgnoredAuthors] != nil || reason.byFilter[.hideLabels] != nil {
            lines.append("숨길 사람·라벨은 목록 위 ‘필터’ 에서 끄거나 고칩니다.")
        }
        return lines.joined(separator: "\n")
    }

    /// 숨길 사람·라벨 필터면 걸린 이름을 괄호로. 그 밖의 필터는 이름이 없다.
    private func names(for kind: PRFilterKind, in reason: AppModel.RepoHiddenReason) -> String {
        let names: Set<String>
        switch kind {
        case .hideIgnoredAuthors: names = reason.authors
        case .hideLabels: names = reason.labels
        default: return ""
        }
        return names.isEmpty ? "" : "(\(names.sorted().joined(separator: ", ")))"
    }

    private func show(_ inside: Bool, _ text: String) {
        withAnimation(.easeOut(duration: 0.12)) { hint = inside ? text : nil }
    }
}

/// 아이콘에 마우스를 올리면 그 줄 아래에 펴는 이유.
///
/// 시스템 툴팁(`.help`)만 두었더니 팝오버 안에서는 안 뜨거나 1~2초 늦어, 경고가 왜 떴는지 알 길이
/// 없었다(사용자 피드백 — "경고 표시가 나오면 호버하면 이유가 나오게"). `.help` 는 그대로 둔다.
/// 줄바꿈은 팝오버 폭 안에서 한다 — 이상적 폭을 작게 잡아 긴 이유가 팝오버를 옆으로 늘리지 않게 한다.
struct HoverHint: View {
    let text: String

    var body: some View {
        Text(text)
            .font(.caption)
            .foregroundStyle(.secondary)
            .fixedSize(horizontal: false, vertical: true)
            .frame(minWidth: 0, idealWidth: 260, maxWidth: .infinity, alignment: .leading)
            .padding(.horizontal, 8)
            .padding(.vertical, 6)
            .background(RoundedRectangle(cornerRadius: 6).fill(Color.orange.opacity(0.1)))
            .transition(.opacity)
    }
}

// MARK: - 큐

struct QueueToolbarMenu: View {
    @Environment(AppModel.self) private var model
    @State private var showsCapHint = false

    private var active: [ReviewJob] { model.jobs.filter(\.isActive) }

    private func capHint(_ cap: Int) -> String {
        "최근 5시간 동안 쓴 토큰이 정해 둔 상한(\(cap / 1000)k)을 넘었습니다. 리뷰를 막지는 않습니다 — "
            + "Claude 사용 한도에 걸리기 전에 알려 주는 표시입니다. 상한은 설정 → ‘대상 제외’ → 사용량 방어에서 바꿉니다."
    }

    var body: some View {
        ToolbarPopover {
            ToolbarButtonLabel(title: "리뷰 \(active.count)", tint: .primary, showsChevron: true) {
                Image(systemName: "bolt.fill").foregroundStyle(.orange)
            }
        } content: {
            VStack(alignment: .leading, spacing: 10) {
                Text("돌고 있는 리뷰 \(active.count)건")
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(.secondary)
                ForEach(active) { job in
                    QueueRow(job: job)
                }
                Divider()
                let cap = model.settings.fiveHourTokenCap
                HStack(spacing: 6) {
                    Text("5시간 토큰 \(model.fiveHourTokens / 1000)k")
                        .font(.caption.monospacedDigit())
                    if cap > 0 {
                        Text("/ 상한 \(cap / 1000)k")
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                        if model.fiveHourTokens >= cap {
                            Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                                .help(capHint(cap))
                                .onHover { inside in withAnimation(.easeOut(duration: 0.12)) { showsCapHint = inside } }
                        }
                    }
                }
                if showsCapHint, cap > 0, model.fiveHourTokens >= cap {
                    HoverHint(text: capHint(cap))
                }
            }
        }
        .help("리뷰 큐")
    }
}

private struct QueueRow: View {
    @Environment(AppModel.self) private var model
    let job: ReviewJob

    private var elapsed: TimeInterval {
        guard let startedAt = job.startedAt else { return 0 }
        return max(0, model.clockTick.timeIntervalSince(startedAt))
    }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            if job.state == .running {
                ProgressView().controlSize(.small)
            } else {
                Image(systemName: "clock").foregroundStyle(.secondary)
            }
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: 5) {
                    Text(verbatim: "#\(job.number)").font(.callout.weight(.medium))
                    if job.deep { Tag(text: "전체 리뷰", color: .purple) }
                }
                if job.state == .running {
                    HStack(spacing: 6) {
                        Text(job.progressTitle).font(.caption)
                        if let fraction = job.cloneFraction {
                            Text("\(Int((fraction * 100).rounded()))%")
                                .font(.caption.monospacedDigit())
                                .foregroundStyle(.secondary)
                        }
                        Text(String(format: "%d:%02d", Int(elapsed) / 60, Int(elapsed) % 60))
                            .font(.caption.monospacedDigit())
                            .foregroundStyle(.secondary)
                    }
                    PhaseTrack(current: job.phase, deep: job.deep, clonedSnapshot: job.clonedSnapshot)
                } else {
                    Text("대기 중").font(.caption).foregroundStyle(.secondary)
                }
            }
            Spacer(minLength: 4)
            Button("취소") { model.cancel(jobID: job.id) }
                .buttonStyle(.link)
                .font(.caption)
        }
    }
}

// MARK: - 상태

struct StatusToolbarMenu: View {
    @Environment(AppModel.self) private var model
    @Environment(\.openWindow) private var openWindow

    /// 팝오버를 열 때 센다. 문제 기록은 관찰 대상이 아니지만 팝오버는 열 때마다 다시 그려진다.
    private var recentProblemCount: Int {
        ProblemLog.shared.entries(since: Date().addingTimeInterval(-30 * 86_400)).count
    }

    /// 기본 리뷰 모델의 엔진이 준비됐는가 — 리뷰 버튼을 누르면 그 엔진으로 돈다.
    private var primaryOK: Bool { model.engineReady(ReviewEngineKind(model: model.settings.model)) }

    /// 줄로 보일 엔진 — 깔려 있는 것. 둘 다 없으면 Claude 줄 하나로 무엇이 없는지 알린다.
    private var shownEngines: [ReviewEngineKind] {
        let installed = ReviewEngineKind.allCases.filter { model.engineStatus($0)?.isInstalled == true }
        return installed.isEmpty ? [.claude] : installed
    }
    private var githubOK: Bool { model.githubAccount != nil }
    private var refreshFailing: Bool { model.consecutiveRefreshFailures > 0 }

    var body: some View {
        ToolbarPopover(debugID: "status") {
            // 색점만으로는 무슨 버튼인지 알 수 없다. 이름을 아래에 붙인다.
            // (점 = 엔진·GitHub 연결 상태 요약, 상시로 색만은 보이게 둔다.)
            ToolbarButtonLabel(title: "상태", tint: .primary, showsChevron: true) {
                HStack(spacing: 3) {
                    dot(primaryOK)
                    dot(githubOK && !refreshFailing, warning: githubOK && refreshFailing)
                }
            }
        } content: {
            VStack(alignment: .leading, spacing: 8) {
                LabeledContent {
                    Text(model.versionSummary)
                        .font(.caption)
                        .multilineTextAlignment(.trailing)
                } label: {
                    VStack(alignment: .leading, spacing: 1) {
                        Text(AppInfo.displayName)
                        Text(AppInfo.subtitle)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
                // 경고·실패를 이 맥에 모아 둔다. 보고는 종류·횟수·버전만 복사한다(사람이 누를 때만).
                LabeledContent("문제 기록") {
                    HStack(spacing: 8) {
                        Text("최근 30일 \(recentProblemCount)건")
                            .font(.caption.monospacedDigit())
                        Button("보기…") { openWindow(id: "problems") }
                            .buttonStyle(.link)
                            .font(.caption)
                        Button("보고 복사") { model.copyProblemReport() }
                            .buttonStyle(.link)
                            .font(.caption)
                            .help("종류·횟수·앱 버전만 담은 글을 복사합니다. 파일·PR·레포 이름은 넣지 않습니다.")
                    }
                }
                Divider()
                ForEach(shownEngines) { engine in
                    let status = model.engineStatus(engine)
                    statusRow(title: engine.displayName,
                              ok: model.engineReady(engine),
                              detail: status?.accountLabel ?? status?.errorMessage ?? "확인 중")
                    // 빨간불만 보여 주고 길을 안 주면 터미널 명령을 외워야 한다.
                    if !model.engineReady(engine), status?.isInstalled == true {
                        Button("\(engine.displayName) 다시 로그인") {
                            model.openEngineLogin(engine)
                        }
                        .buttonStyle(.link)
                    }
                }
                statusRow(title: "GitHub", ok: githubOK,
                          detail: model.githubAccount?.login ?? "미연결")
                Divider()
                if let remaining = model.rateRemaining {
                    LabeledContent("API 잔여") {
                        Text("\(remaining)").font(.caption.monospacedDigit())
                    }
                }
                LabeledContent("5시간 토큰") {
                    Text("\(model.fiveHourTokens / 1000)k / 상한 \(model.settings.fiveHourTokenCap / 1000)k")
                        .font(.caption.monospacedDigit())
                }
                // 잠자기 중에는 갱신을 멈춘다. 알려 주지 않으면 "왜 안 도는지" 알 길이 없다
                // (예전에는 툴바의 자동 리뷰 컨트롤이 이 표시를 들고 있었다).
                if model.isSleeping {
                    Label("잠자기 중 — 새 리뷰와 갱신을 멈춥니다", systemImage: "moon.zzz.fill")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                if let last = model.lastRefreshedAt {
                    LabeledContent("갱신") {
                        Text(last, style: .time).font(.caption.monospacedDigit())
                    }
                }
                if refreshFailing {
                    Label("갱신 실패 \(model.consecutiveRefreshFailures)회 연속 — \(model.githubError ?? "")",
                          systemImage: "exclamationmark.triangle.fill")
                        .font(.caption)
                        .foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                }
                Divider()
                SettingsLink { Text("연결 설정…") }
                    .buttonStyle(.link)
                Button("로그 열기") { model.openLogFile() }
                    .buttonStyle(.link)
                // 터미널에서 직접 로그인한 경우를 위한 수동 확인. 앱으로 돌아올 때 자동으로도 돈다.
                Button("연결 다시 확인") { Task { await model.checkEngines() } }
                    .buttonStyle(.link)

                if let update = model.availableUpdate {
                    Divider()
                    Label("새 버전 v\(update.version) 이 있습니다", systemImage: "arrow.down.circle")
                        .font(.caption)
                        .foregroundStyle(.blue)
                    Text("지금 v\(UpdateCheck.currentVersion())")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                    Button(model.isUpdating ? "업데이트 다운로드 중…" : (model.updateFailure == nil ? "앱에서 업데이트" : "다시 시도")) {
                        model.runUpdate()
                    }
                    .buttonStyle(.link)
                    .disabled(model.isUpdating)
                    // 실패 이유를 누른 자리에 적는다(창 아래 토스트만으로는 못 보고 지나갔다).
                    if let failure = model.updateFailure {
                        Text(failure)
                            .font(.caption2)
                            .foregroundStyle(.red)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                }
            }
        }
        .help(statusHelp)
    }

    private var statusHelp: String {
        var parts: [String] = []
        parts.append("\(ReviewEngineKind(model: model.settings.model).displayName) \(primaryOK ? "정상" : "확인 필요")")
        parts.append("GitHub \(githubOK ? "정상" : "미연결")")
        if refreshFailing { parts.append("갱신 실패 \(model.consecutiveRefreshFailures)회") }
        return parts.joined(separator: " · ")
    }

    private func dot(_ ok: Bool, warning: Bool = false) -> some View {
        Circle()
            .fill(warning ? Color.orange : (ok ? Color.green : Color.red))
            .frame(width: 7, height: 7)
    }

    private func statusRow(title: String, ok: Bool, detail: String) -> some View {
        HStack(spacing: 6) {
            Circle().fill(ok ? Color.green : Color.red).frame(width: 7, height: 7)
            Text(title).font(.callout)
            Spacer(minLength: 8)
            Text(detail)
                .font(.caption)
                .foregroundStyle(.secondary)
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }
}

// MARK: - 프리뷰 (캔버스에서 간격 맞추는 용도)
//
// 간격 하나 고치자고 `install.sh` → `pkill` → `open` 을 돌리면 매번 1분 넘게 걸린다.
// 이 파일을 Xcode 에서 열고 ⌥⌘↩ 로 캔버스를 켜면, 위 `ToolbarButtonLabel` 을 고치는 즉시
// 오른쪽에 다시 그려진다.
//
// 프리뷰를 셋으로 나눈 이유:
//  - **툴바**        알약 배경과 툴바 높이는 macOS 가 그린다. 라벨이 툴바 높이를 넘겨
//                   잘리는지는 진짜 툴바에 얹어 봐야만 보인다.
//  - **라벨 · 확대**  눈으로 "붙었다/떨어졌다" 를 재면 틀린다(실제로 한 번 틀렸다).
//                   3배로 키우고 padding 상자를 색으로 드러내 어디가 얼마인지 보이게 한다.
//  - **메뉴 3종**    실제로 쓰는 세 버튼. `@Environment(AppModel.self)` 를 읽으므로
//                   빈 모델을 심어 줘야 한다 — 안 심으면 그리는 순간 죽는다.

#if DEBUG

/// 툴바 버튼 하나의 견본. 아이콘 종류에 따라 배치가 달라지는지도 같이 본다.
private struct PreviewSample: Identifiable {
    let id = UUID()
    let title: String
    let symbol: String
    var tint: Color = .primary
    var symbolTint: Color?
    var chevron = false
    /// 상태 버튼은 아이콘 자리에 색점 두 개가 들어간다. 높이가 달라 따로 본다.
    var dots = false

    static let all: [PreviewSample] = [
        .init(title: "목록", symbol: "sidebar.left"),
        .init(title: "레포 2개", symbol: "shippingbox", chevron: true),
        .init(title: "리뷰 1", symbol: "bolt.fill", symbolTint: .orange, chevron: true),
        .init(title: "상태", symbol: "circle", chevron: true, dots: true),
        .init(title: "일부만", symbol: "tray.full", tint: .orange),
    ]
}

private struct PreviewSampleLabel: View {
    let sample: PreviewSample

    var body: some View {
        ToolbarButtonLabel(title: sample.title, tint: sample.tint, showsChevron: sample.chevron) {
            if sample.dots {
                HStack(spacing: 3) {
                    Circle().fill(Color.green).frame(width: 7, height: 7)
                    Circle().fill(Color.red).frame(width: 7, height: 7)
                }
            } else {
                Image(systemName: sample.symbol)
                    .foregroundStyle(sample.symbolTint ?? sample.tint)
            }
        }
    }
}

/// 진짜 툴바 위. 알약 배경과 잘림 여부는 여기서만 제대로 보인다.
///
/// `NavigationStack` 으로 감싸는 이유: macOS 에서 `.toolbar` 는 창의 툴바에 붙는데,
/// 프리뷰 호스트에는 창 툴바가 없다. 그냥 `Text().toolbar {}` 로 두면 조용히 아무것도 안 뜬다.
#Preview("툴바") {
    NavigationStack {
        Text("본문")
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .toolbar {
                ToolbarItemGroup {
                    ForEach(PreviewSample.all) { sample in
                        Button {} label: { PreviewSampleLabel(sample: sample) }
                    }
                }
            }
    }
    .frame(width: 640, height: 160)
}

/// 실제 크기 · 3배 확대 · 상자 표시. 간격을 눈이 아니라 상자로 본다.
#Preview("라벨 · 확대") {
    VStack(alignment: .leading, spacing: 18) {
        PreviewSection("실제 크기") {
            HStack(spacing: 10) {
                ForEach(PreviewSample.all) { PreviewSampleLabel(sample: $0) }
            }
        }
        PreviewSection("3배 — 아이콘과 글자 사이가 실제로 이만큼 벌어져 있다") {
            PreviewSampleLabel(sample: PreviewSample.all[1])
                .fixedSize()
                .scaleEffect(3, anchor: .topLeading)
                .frame(width: 200, height: 120, alignment: .topLeading)
        }
        PreviewSection("상자 — 노랑이 라벨이 차지하는 넓이(padding 포함), 빨강이 그 테두리") {
            HStack(spacing: 10) {
                ForEach(PreviewSample.all) { sample in
                    PreviewSampleLabel(sample: sample)
                        .background(Color.yellow.opacity(0.25))
                        .border(Color.red.opacity(0.7))
                }
            }
        }
    }
    .padding(20)
    .frame(width: 600, alignment: .leading)
}

/// 툴바에 실제로 쓰이는 두 버튼(레포 메뉴는 툴바 아래 레포 줄로 옮겼다). 빈 `AppModel` 이라 큐 내용은 없지만 라벨 배치는 같다.
#Preview("메뉴 2종") {
    HStack(spacing: 10) {
        QueueToolbarMenu()
        StatusToolbarMenu()
    }
    .padding(20)
    .environment(AppModel())
}

private struct PreviewSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    init(_ title: String, @ViewBuilder content: () -> Content) {
        self.title = title
        self.content = content()
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            content
        }
    }
}

#endif
