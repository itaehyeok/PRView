import AppKit
import PRayerCore
import SwiftUI

/// PR 머리 줄의 "보내는 브랜치 → 받는 브랜치".
///
/// 칩마다 색을 달리해 이름을 읽기 전에 어느 쪽이 어느 쪽인지 갈린다 — 보내는 쪽 보라, 받는 쪽 초록. 바탕은 칠하지 않고
/// 테두리와 글자에만 색을 쓴다(사용자 결정, 시안 K-11 — 옅은 바탕을 칠한 K-3 과 견줘 골랐다).
/// 초록은 머지 줄(MergeBar)이 머지할 곳에 쓰는 색과 같다. 예전엔 회색 글자 두 줄이라 어디서 어디로인지 한 번 더 읽어야 했다.
/// 받는 쪽은 바꿀 수 있으면(`canChangeBase`) ▾ 를 달고, 누르면 고르기 칸(`BaseBranchPicker`)이 뜬다. 고르면 칸을 닫고
/// 확인 시트(`BaseChangeConfirm`)를 띄운다.
/// head 커밋 번호는 따로 보이지 않는다 — 대화 목록의 커밋 줄과 겹쳤다(사용자 결정). 보내는 쪽 칩 툴팁에만 둔다.
struct PRBranchPair: View {
    @Environment(AppModel.self) private var model
    let pr: PullRequestInfo
    @State private var showsPicker = false
    @State private var hoveringBase = false
    /// 고르기 칸에서 고른 브랜치. 있으면 확인 시트가 떠 있다.
    @State private var confirmBase: String?

    var body: some View {
        BranchPairLayout {
            BranchChip(name: pr.headRefName, tint: BranchTint.head)
                .help("보내는 브랜치 \(pr.headRefName) · 최신 커밋 \(pr.shortHead)")
            Image(systemName: "arrow.right")
                .font(.system(size: 10, weight: .semibold))
                .foregroundStyle(BranchTint.base)
            base
        }
    }

    @ViewBuilder
    private var base: some View {
        if pr.canChangeBase {
            Button {
                showsPicker = true
            } label: {
                BranchChip(name: pr.baseRefName, tint: BranchTint.base, editable: true, highlighted: hoveringBase || showsPicker)
            }
            .buttonStyle(.plain)
            .onHover { hoveringBase = $0 }
            .help("받는 브랜치 \(pr.baseRefName) — 눌러서 base 를 바꿉니다")
            .popover(isPresented: $showsPicker, arrowEdge: .bottom) {
                BaseBranchPicker(pr: pr, onChoose: choose)
            }
            .sheet(isPresented: Binding(get: { confirmBase != nil }, set: { if !$0 { confirmBase = nil } })) {
                if let confirmBase {
                    BaseChangeConfirm(pr: pr, newBase: confirmBase) { self.confirmBase = nil }
                }
            }
            .task {
                guard let debug = DebugLaunch.basePicker else { return }
                try? await Task.sleep(for: .seconds(2))
                showsPicker = true
                // confirm 은 줄을 누른 것과 같은 길(칸 닫기 → 시트)로 고른다.
                guard debug.hasPrefix("confirm:") else { return }
                try? await Task.sleep(for: .seconds(1.5))
                choose(String(debug.dropFirst(8)))
            }
        } else {
            BranchChip(name: pr.baseRefName, tint: BranchTint.base)
                .help(pr.isOpen ? "받는 브랜치 \(pr.baseRefName)" : "받는 브랜치 \(pr.baseRefName) — 닫힌 PR 은 base 를 바꿀 수 없습니다")
        }
    }

    /// 칸을 닫고 같은 순간에 시트를 띄운다(칸이 닫히기를 기다리지 않아도 시트가 뜬다 — 데모 사본 실측).
    private func choose(_ name: String) {
        showsPicker = false
        confirmBase = name
    }
}

/// 보라·초록 둘 다 시스템 색은 밝은 바탕 위 글자·테두리로 대비가 모자라다(특히 초록). 밝은 바탕에서는 한 단계 어둡게
/// (GitHub 의 done·success 글자색), 어두운 바탕에서는 시스템 색 그대로 쓴다.
enum BranchTint {
    static let head = dynamic(light: NSColor(srgbRed: 0x82 / 255, green: 0x50 / 255, blue: 0xDF / 255, alpha: 1),
                              dark: .systemPurple)
    static let base = dynamic(light: NSColor(srgbRed: 0x1A / 255, green: 0x7F / 255, blue: 0x37 / 255, alpha: 1),
                              dark: .systemGreen)

    private static func dynamic(light: NSColor, dark: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
}

/// 브랜치 아이콘 + 이름(+ 바꿀 수 있으면 ▾)을 색 테두리로 두른 칩. 바탕은 누를 수 있는 칩에 마우스를 올리거나 고르기 칸이
/// 열렸을 때만 옅게 칠한다 — 눌린다는 표시. 이름이 길면 가운데를 줄인다 — 앞(접두어·작성자)과
/// 끝(티켓 번호)이 알아보는 데 쓰인다.
private struct BranchChip: View {
    let name: String
    let tint: Color
    var editable = false
    var highlighted = false

    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 9, weight: .semibold))
            Text(verbatim: name)
                .font(.caption.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
            if editable {
                Image(systemName: "chevron.down")
                    .font(.system(size: 7, weight: .bold))
            }
        }
        .foregroundStyle(tint)
        .padding(.horizontal, 6)
        .padding(.vertical, 2)
        .background(tint.opacity(highlighted ? 0.10 : 0), in: RoundedRectangle(cornerRadius: 5))
        .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(tint.opacity(0.7), lineWidth: 1))
        .contentShape(RoundedRectangle(cornerRadius: 5))
    }
}

/// [보내는 칩, 화살표, 받는 칩] 셋을 넓으면 한 줄, 모자라면 두 줄(보내는 칩 / 화살표 + 받는 칩)로 놓는다.
/// 예전에는 늘 두 줄이었다 — 글자로 한 줄에 이으면 좁을 때 받는 브랜치 이름 가운데("feature/" | "login-redesign-…")에서
/// 꺾였다(사용자 피드백). 칩째 다음 줄로 내리면 그 일이 없어서, 자리가 넉넉할 때는 한 줄로 둔다(사용자 요청).
///
/// `ViewThatFits` 로 두 배치를 다 두지 않는 이유: 폭이 바뀔 때마다 두 배치를 처음부터 다시 재고(목록 행에서 드래그 비용
/// 대부분이었다 — PRRowFactsLayout 주석), 받는 칩의 고르기 팝오버가 두 벌 생긴다. 여기서는 칩을 한 벌만 두고 자리만 바꾼다.
/// 두 줄로도 모자라면 칩 안 이름이 가운데부터 줄어든다(받는 쪽은 짧아서 대개 보내는 쪽이 줄어든다).
private struct BranchPairLayout: Layout {
    private let gap: CGFloat = 5
    private let rowGap: CGFloat = 3

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(width: proposal.width, subviews: subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let arrangement = arrange(width: bounds.width, subviews: subviews)
        for (subview, frame) in zip(subviews, arrangement.frames) {
            subview.place(at: CGPoint(x: bounds.minX + frame.minX, y: bounds.minY + frame.minY),
                          proposal: ProposedViewSize(frame.size))
        }
    }

    private func arrange(width: CGFloat?, subviews: Subviews) -> (size: CGSize, frames: [CGRect]) {
        guard subviews.count == 3 else { return (.zero, subviews.map { _ in .zero }) }
        let ideal = subviews.map { $0.sizeThatFits(.unspecified) }
        let oneLine = ideal[0].width + gap + ideal[1].width + gap + ideal[2].width
        if width.map({ oneLine <= $0 }) ?? true {
            let height = ideal.map(\.height).max() ?? 0
            var x: CGFloat = 0
            let frames = ideal.map { size -> CGRect in
                defer { x += size.width + gap }
                return CGRect(x: x, y: (height - size.height) / 2, width: size.width, height: size.height)
            }
            return (CGSize(width: oneLine, height: height), frames)
        }
        let available = max(0, width ?? 0)
        let head = subviews[0].sizeThatFits(ProposedViewSize(width: min(ideal[0].width, available), height: nil))
        let baseRoom = max(0, available - ideal[1].width - gap)
        let base = subviews[2].sizeThatFits(ProposedViewSize(width: min(ideal[2].width, baseRoom), height: nil))
        let secondHeight = max(ideal[1].height, base.height)
        let secondY = head.height + rowGap
        let frames = [
            CGRect(origin: .zero, size: head),
            CGRect(x: 0, y: secondY + (secondHeight - ideal[1].height) / 2, width: ideal[1].width, height: ideal[1].height),
            CGRect(x: ideal[1].width + gap, y: secondY + (secondHeight - base.height) / 2, width: base.width, height: base.height),
        ]
        let size = CGSize(width: max(head.width, ideal[1].width + gap + base.width), height: secondY + secondHeight)
        return (size, frames)
    }
}

// MARK: - base 고르기 칸

/// 받는 쪽 칩을 누르면 뜨는 칸. 고르기만 한다 — 고르면 부르는 쪽이 칸을 닫고 확인 시트를 띄운다.
struct BaseBranchPicker: View {
    @Environment(AppModel.self) private var model
    let pr: PullRequestInfo
    let onChoose: (String) -> Void

    @State private var query = ""
    @State private var result: BranchSearchResult?
    @State private var searchError: String?
    @FocusState private var searchFocused: Bool

    var body: some View {
        chooser
            .frame(width: 320)
    }

    // MARK: 고르기

    private var suggestions: [String] {
        let all = model.suggestedBases(for: pr, defaultBranch: result?.defaultBranch)
        guard !query.isEmpty else { return all }
        return all.filter { $0.localizedCaseInsensitiveContains(query) }
    }

    /// 찾은 브랜치 중 위 후보에 없는 것.
    private var others: [String] {
        let shown = Set(suggestions)
        return (result?.names ?? []).filter { !shown.contains($0) }
    }

    private var chooser: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("base 브랜치 바꾸기")
                .font(.caption.weight(.semibold))
                .foregroundStyle(.secondary)
            TextField("브랜치 찾기", text: $query)
                .textFieldStyle(.roundedBorder)
                .focused($searchFocused)
                .onSubmit {
                    // 엔터는 맨 위 고를 수 있는 것 — 찾는 글을 다 치고 바로 고르게.
                    if let first = (suggestions + others).first(where: { $0 != pr.baseRefName }) { onChoose(first) }
                }
            ScrollView {
                VStack(alignment: .leading, spacing: 1) {
                    if !suggestions.isEmpty {
                        sectionTitle("이 레포 PR 들이 쓰는 base")
                        ForEach(suggestions, id: \.self) { row($0) }
                    }
                    if !others.isEmpty {
                        sectionTitle(query.isEmpty ? "최근 브랜치" : "찾은 브랜치")
                            .padding(.top, suggestions.isEmpty ? 0 : 6)
                        ForEach(others, id: \.self) { row($0) }
                    }
                    footer
                }
            }
            .frame(maxHeight: 300)
            .fixedSize(horizontal: false, vertical: true)
        }
        .padding(10)
        .task(id: query) {
            // 칠 때마다 묻지 않는다 — 멈추고 0.25초 뒤에 한 번. 처음 열 때(빈 글)는 바로 묻는다.
            if !query.isEmpty {
                try? await Task.sleep(for: .milliseconds(250))
                guard !Task.isCancelled else { return }
            }
            do {
                result = try await model.searchBranches(for: pr, matching: query)
                searchError = nil
            } catch is CancellationError {
                return
            } catch {
                searchError = error.localizedDescription
            }
        }
        .onAppear { searchFocused = true }
    }

    @ViewBuilder
    private var footer: some View {
        if let searchError {
            Text("브랜치를 못 가져왔습니다: \(searchError)")
                .font(.caption2)
                .foregroundStyle(.red)
                .padding(.top, 6)
        } else if result == nil {
            HStack(spacing: 4) {
                ProgressView().controlSize(.small).scaleEffect(0.7)
                Text("브랜치 가져오는 중").font(.caption2).foregroundStyle(.secondary)
            }
            .padding(.top, 6)
        } else if let result, result.totalCount > result.names.count {
            Text("브랜치 \(result.totalCount)개 중 최근 \(result.names.count)개 — 이름으로 찾으세요")
                .font(.caption2)
                .foregroundStyle(.tertiary)
                .padding(.top, 6)
        } else if suggestions.isEmpty, others.isEmpty {
            Text("'\(query)' 가 든 브랜치가 없습니다")
                .font(.caption2)
                .foregroundStyle(.secondary)
                .padding(.top, 6)
        }
    }

    private func sectionTitle(_ text: String) -> some View {
        Text(text)
            .font(.caption2)
            .foregroundStyle(.tertiary)
            .padding(.horizontal, 6)
            .padding(.bottom, 1)
    }

    private func row(_ name: String) -> some View {
        let isCurrent = name == pr.baseRefName
        return Button {
            onChoose(name)
        } label: {
            BranchPickerRow(name: name, isCurrent: isCurrent, isDefault: name == result?.defaultBranch)
        }
        .buttonStyle(.plain)
        .disabled(isCurrent)
    }
}

// MARK: - base 바꾸기 확인

/// base 를 바꾸기 전의 확인 — 머지 확인(MergeBar)과 같은 꼴로 창 위에서 내려오는 시트. Return 은 바꾸기, Esc 는 취소,
/// 바꾸는 동안은 닫히지 않는다. GitHub 웹도 고른 뒤 "Change base" 를 한 번 더 묻는다 — diff·커밋·줄 코멘트 자리가 통째로 달라진다.
///
/// 내 PR 이 아니면 주황 칸으로 알리고 버튼에 작성자 이름을 넣는다(사용자 결정, 시안 A). 쓰기 권한이 있으면 남의 PR 도
/// 바뀌는데, 고르기 칸은 내 PR 과 똑같이 생겨서 남의 것을 바꾸는지 모르고 누를 수 있었다.
struct BaseChangeConfirm: View {
    @Environment(AppModel.self) private var model
    let pr: PullRequestInfo
    let newBase: String
    let onClose: () -> Void

    @State private var isChanging = false
    @State private var failure: String?

    /// 내 PR 이 아니면 작성자의 화면 이름. 내 PR 이면 nil.
    private var otherAuthor: String? {
        pr.viewerDidAuthor ? nil : model.settings.displayName(pr.author)
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 14) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 26, weight: .semibold))
                    .foregroundStyle(BranchTint.base)
                    .frame(width: 34)
                VStack(alignment: .leading, spacing: 8) {
                    Text("base 를 바꿀까요?")
                        .font(.headline)
                    (Text(verbatim: "#\(pr.number) ").foregroundColor(.secondary) + Text(pr.title))
                        .font(.callout)
                        .lineLimit(2)
                    HStack(spacing: 5) {
                        BranchChip(name: pr.baseRefName, tint: .secondary)
                        Image(systemName: "arrow.right")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(BranchTint.base)
                        BranchChip(name: newBase, tint: BranchTint.base)
                    }
                    if let otherAuthor {
                        notMine(otherAuthor)
                    }
                    Text("커밋·diff 가 새 base 기준으로 바뀌고, 달린 줄 코멘트 일부가 outdated 될 수 있습니다. GitHub 에 바로 반영됩니다.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                .fixedSize(horizontal: false, vertical: true)
            }
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
                Button("취소", action: onClose)
                    .keyboardShortcut(.cancelAction)
                    .disabled(isChanging)
                Button {
                    Task { await change() }
                } label: {
                    if isChanging {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(otherAuthor.map { "\($0) 님 PR 의 base 바꾸기" } ?? "base 바꾸기")
                    }
                }
                .keyboardShortcut(.defaultAction)
                .disabled(isChanging)
            }
        }
        .padding(20)
        .frame(width: 460)
        .interactiveDismissDisabled(isChanging)
    }

    private func notMine(_ author: String) -> some View {
        HStack(alignment: .top, spacing: 8) {
            Image(systemName: "exclamationmark.triangle.fill")
                .foregroundStyle(.orange)
            VStack(alignment: .leading, spacing: 2) {
                Text("\(author) 님이 올린 PR 입니다 — 내 PR 이 아닙니다.")
                    .fontWeight(.medium)
                Text("쓰기 권한이 있어 바꿀 수 있지만, PR 타임라인에 내가 base 를 바꾼 것으로 남습니다.")
                    .foregroundStyle(.secondary)
            }
        }
        .font(.callout)
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.12), in: RoundedRectangle(cornerRadius: 8))
    }

    private func change() async {
        isChanging = true
        failure = nil
        defer { isChanging = false }
        do {
            try await model.changeBase(pr, to: newBase)
            onClose()
        } catch {
            failure = error.localizedDescription
        }
    }
}

/// 고르기 칸의 한 줄. 지금 base 는 ✓ 와 함께 흐리게(고를 수 없다), 기본 브랜치는 "기본" 을 단다.
private struct BranchPickerRow: View {
    let name: String
    let isCurrent: Bool
    let isDefault: Bool
    @State private var hovering = false

    var body: some View {
        HStack(spacing: 6) {
            Image(systemName: "arrow.triangle.branch")
                .font(.system(size: 9, weight: .semibold))
                .foregroundStyle(.tertiary)
            Text(verbatim: name)
                .font(.caption.monospaced())
                .lineLimit(1)
                .truncationMode(.middle)
            if isDefault {
                Tag(text: "기본", color: .secondary)
            }
            Spacer(minLength: 6)
            if isCurrent {
                Text("지금 base")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Image(systemName: "checkmark")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(.secondary)
            }
        }
        .foregroundStyle(isCurrent ? .secondary : .primary)
        .padding(.horizontal, 6)
        .padding(.vertical, 4)
        .background(hovering && !isCurrent ? Color.accentColor.opacity(0.12) : .clear,
                    in: RoundedRectangle(cornerRadius: 4))
        .contentShape(Rectangle())
        .onHover { hovering = $0 }
    }
}
