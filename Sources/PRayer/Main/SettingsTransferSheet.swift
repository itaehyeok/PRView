import SwiftUI
import UniformTypeIdentifiers
import PRayerCore

/// 내보내기 창을 여는 버튼. 설정 창 ‘설정 공유’ 탭에서 쓴다.
struct SettingsExportButton: View {
    @State private var request: SettingsTransferRequest?

    var body: some View {
        Button("내보내기…") { request = SettingsTransferRequest(mode: .export) }
            .sheet(item: $request) { SettingsTransferSheet(request: $0) }
    }
}

/// 받은 설정 파일을 여는 버튼. 설정 창 ‘설정 공유’ 탭과 온보딩 레포 단계에서 쓴다.
///
/// 파일을 고르자마자 설정을 바꾸지 않는다. 먼저 항목을 고르는 창을 띄운다 — 남의 설정을 통째로 덮어쓰면
/// 내 알림·글꼴·경로까지 그 사람 것으로 바뀐다.
struct SettingsImportButton: View {
    /// 온보딩에서는 "팀원 설정 가져오기…" 로 무엇을 가져오는지 적는다.
    var title = "가져오기…"
    @State private var request: SettingsTransferRequest?
    @State private var openError: String?

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            Button(title) { pickFile() }
            // 설정 창에서 연 경우 토스트는 본 창 아래에 떠서 안 보인다. 그 자리에서 알린다.
            if let openError {
                Label(openError, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .sheet(item: $request) { SettingsTransferSheet(request: $0) }
    }

    private func pickFile() {
        openError = nil
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [.json]
        panel.allowsMultipleSelection = false
        panel.canChooseDirectories = false
        panel.prompt = "열기"
        panel.message = "팀원에게 받은 \(AppInfo.displayName) 설정 파일(.json)을 고르세요. 열어도 바로 바뀌지 않고, 가져올 항목을 고르는 창이 먼저 뜹니다."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            let size = (try? url.resourceValues(forKeys: [.fileSizeKey]).fileSize) ?? 0
            guard size <= SettingsTransfer.maxFileBytes else { throw SettingsTransferError.tooLarge }
            let result = try SettingsTransfer.read(Data(contentsOf: url))
            request = SettingsTransferRequest(mode: .importing(result, fileName: url.lastPathComponent))
        } catch {
            openError = error.localizedDescription
        }
    }
}

struct SettingsTransferRequest: Identifiable {
    enum Mode {
        case export
        case importing(SettingsTransfer.ReadResult, fileName: String)
    }

    let id = UUID()
    let mode: Mode
}

/// 묶음(설정 창의 탭과 같은 갈래)마다 설명을 달고, 항목마다 무엇을 하는 설정인지와 값을 보여 주며 고르게 한다.
/// 가져오기에서는 지금 내 값과 나란히 놓는다 — "가져오면 뭐가 바뀌지" 를 고르기 전에 알 수 있어야 한다.
struct SettingsTransferSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: SettingsTransferRequest

    @State private var sections: [TransferSection] = []
    @State private var selection: Set<String> = []
    @State private var phase: Phase = .choosing
    @State private var errorText: String?
    @State private var showsSkipped = false

    private enum Phase {
        case choosing
        /// 도는 동안 아래 줄에 띄울 말.
        case working(String)
        case exported(URL)
        case imported(SettingsImportReport)
        case undone
    }

    private var isExport: Bool {
        if case .export = request.mode { return true }
        return false
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
                .padding(.horizontal, 20)
                .padding(.vertical, 14)
            Divider()
            content
                .frame(maxWidth: .infinity, maxHeight: .infinity, alignment: .topLeading)
            Divider()
            footer
                .padding(.horizontal, 20)
                .padding(.vertical, 12)
        }
        // 설정 창(620×560)·온보딩 창(640×560) 위에 뜬다. 부모보다 크면 시트가 창 밖으로 삐져나온다.
        .frame(width: 600, height: 540)
        .onAppear(perform: load)
    }

    // MARK: 머리

    @ViewBuilder
    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            switch request.mode {
            case .export:
                Text("설정 내보내기").font(.title2.bold())
                Text("고른 항목만 파일에 담습니다. 받는 사람은 이 가운데서 다시 골라 가져옵니다. 토큰·로그인 정보·초안·리뷰 기록은 담기지 않습니다(앱이 토큰을 저장하지 않습니다).")
                    .font(.callout)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            case .importing(let result, let fileName):
                Text("설정 가져오기").font(.title2.bold())
                Text(origin(of: result.file, fileName: fileName))
                    .font(.callout)
                    .fixedSize(horizontal: false, vertical: true)
                Text("고른 항목만 내 설정에 들어옵니다. 지금 값과 같은 항목은 고를 수 없습니다. 목록(레포·라벨·사람·제외 경로)은 합치기만 하고, 내 것을 지우지 않습니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                if !result.skipped.isEmpty {
                    DisclosureGroup(isExpanded: $showsSkipped) {
                        VStack(alignment: .leading, spacing: 2) {
                            ForEach(Array(result.skipped.enumerated()), id: \.offset) { _, line in
                                Text("· \(line)")
                            }
                        }
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .frame(maxWidth: .infinity, alignment: .leading)
                    } label: {
                        Label("파일에서 그대로 쓸 수 없어 건너뛰거나 고친 값 \(result.skipped.count)개",
                              systemImage: "exclamationmark.triangle.fill")
                            .font(.caption)
                            .foregroundStyle(.orange)
                    }
                }
            }
        }
    }

    private func origin(of file: SettingsTransferFile, fileName: String) -> String {
        var parts: [String] = []
        parts.append(file.exportedBy.map { "\($0) 님이" } ?? "보낸 사람이 적혀 있지 않은 파일 —")
        if let date = file.exportedAt {
            // 앱의 기본 언어가 영어라 그냥 formatted() 하면 "Oct 1, 2026 at 3:23 PM" 이 된다(실측).
            let formatter = DateFormatter()
            formatter.locale = Locale(identifier: "ko_KR")
            formatter.dateFormat = "yyyy년 M월 d일 a h:mm"
            parts.append(formatter.string(from: date) + "에")
        }
        if let version = file.appVersion { parts.append("\(AppInfo.displayName) v\(version) 에서") }
        parts.append("내보낸 설정입니다.")
        return parts.joined(separator: " ") + "  (\(fileName))"
    }

    // MARK: 본문

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .choosing, .working(_):
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    ForEach(sections) { section in
                        TransferSectionView(section: section, selection: $selection, isExport: isExport)
                    }
                }
                .padding(20)
            }
            .disabled(isWorking)
        case .exported(let url):
            exportedView(url)
        case .imported(let report):
            importedView(report)
        case .undone:
            Label("가져오기 전으로 되돌렸습니다.", systemImage: "arrow.uturn.backward.circle.fill")
                .font(.title3)
                .padding(20)
        }
    }

    private var isWorking: Bool {
        if case .working = phase { return true }
        return false
    }

    private func exportedView(_ url: URL) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Label("저장했습니다", systemImage: "checkmark.circle.fill")
                .font(.title3)
                .foregroundStyle(.green)
            Text(url.path)
                .font(.caption.monospaced())
                .textSelection(.enabled)
            Text("이 파일을 슬랙이나 메신저로 보내면, 받는 사람은 \(AppInfo.displayName) → 설정 → ‘설정 공유’ 탭 → ‘가져오기…’로 엽니다. 처음 설치한 사람은 온보딩의 레포 선택 단계에서도 열 수 있습니다.")
                .font(.callout)
                .fixedSize(horizontal: false, vertical: true)
            Button("Finder 에서 보기") { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        }
        .padding(20)
    }

    private func importedView(_ report: SettingsImportReport) -> some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 10) {
                if report.applied.isEmpty {
                    Label("바뀐 항목이 없습니다.", systemImage: "info.circle.fill")
                        .font(.title3)
                } else {
                    Label("\(report.applied.count)개 항목을 가져왔습니다.", systemImage: "checkmark.circle.fill")
                        .font(.title3)
                        .foregroundStyle(.green)
                    VStack(alignment: .leading, spacing: 2) {
                        ForEach(report.applied, id: \.self) { Text("· \($0)") }
                    }
                    .font(.callout)
                }
                if !report.unreachableRepos.isEmpty {
                    notice("내 계정으로 볼 수 없어 넣지 않은 레포: \(report.unreachableRepos.joined(separator: ", ")). 권한을 받은 뒤 ‘레포·팀 규칙’ 탭에서 추가하세요.",
                           color: .orange)
                }
                if !report.uncheckedRepos.isEmpty {
                    notice("볼 수 있는지 확인하지 못하고 넣은 레포: \(report.uncheckedRepos.joined(separator: ", ")). 목록에 PR 이 뜨지 않으면 ‘레포·팀 규칙’ 탭에서 빼세요.",
                           color: .orange)
                }
                ForEach(report.problems, id: \.self) { notice($0, color: .red) }
                if let backup = report.backupFile {
                    Text("가져오기 전 설정은 \(backup.path) 에 남겨 두었습니다. 창을 닫은 뒤에 되돌리고 싶으면 앱을 끄고 이 파일을 settings.json 자리에 두세요.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                        .fixedSize(horizontal: false, vertical: true)
                }
            }
            .padding(20)
        }
    }

    private func notice(_ text: String, color: Color) -> some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.callout)
            .foregroundStyle(color)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: 아래 줄

    @ViewBuilder
    private var footer: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let errorText {
                Label(errorText, systemImage: "xmark.octagon.fill")
                    .font(.caption)
                    .foregroundStyle(.red)
            }
            HStack(spacing: 10) {
                switch phase {
                case .choosing, .working(_):
                    selectionShortcuts
                    Spacer()
                    if case .working(let message) = phase {
                        ProgressView().controlSize(.small)
                        Text(message).font(.caption).foregroundStyle(.secondary)
                    } else {
                        Text(isExport ? "\(selection.count)개 항목을 담습니다" : "\(selection.count)개 항목을 가져옵니다")
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                    Button("취소") { dismiss() }
                        .keyboardShortcut(.cancelAction)
                        .disabled(isWorking)
                    Button(isExport ? "파일로 저장…" : "가져오기") { isExport ? saveExport() : runImport() }
                        .keyboardShortcut(.defaultAction)
                        .disabled(selection.isEmpty || isWorking)
                case .imported(let report):
                    Spacer()
                    if !report.applied.isEmpty {
                        Button("되돌리기") { undo(report) }
                    }
                    Button("닫기") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                case .exported, .undone:
                    Spacer()
                    Button("닫기") { dismiss() }
                        .keyboardShortcut(.defaultAction)
                }
            }
        }
    }

    private var selectionShortcuts: some View {
        HStack(spacing: 10) {
            Button("모두 고르기") { selection = sections.selectableIDs }
            Button("모두 풀기") { selection = [] }
            Button("처음대로") { selection = sections.defaultSelection }
        }
        .buttonStyle(.link)
        .font(.caption)
        .disabled(isWorking)
    }

    // MARK: 동작

    private func load() {
        // 저장 창(NSSavePanel)을 닫고 돌아올 때 등 onAppear 가 다시 불려도 고른 것을 처음으로 되돌리지 않는다.
        guard sections.isEmpty else { return }
        switch request.mode {
        case .export:
            sections = model.exportSections()
        case .importing(let result, _):
            sections = model.importSections(for: result.file)
        }
        selection = sections.defaultSelection
    }

    private func saveExport() {
        errorText = nil
        let panel = NSSavePanel()
        panel.allowedContentTypes = [.json]
        panel.nameFieldStringValue = model.suggestedExportFileName
        panel.canCreateDirectories = true
        panel.message = "팀원에게 보낼 설정 파일을 저장할 곳을 고르세요."
        guard panel.runModal() == .OK, let url = panel.url else { return }
        do {
            try model.writeSettingsExport(selected: selection, to: url)
            phase = .exported(url)
        } catch {
            errorText = "저장하지 못했습니다: \(error.localizedDescription)"
        }
    }

    private func runImport() {
        guard case .importing(let result, _) = request.mode else { return }
        errorText = nil
        phase = .working("가져오는 중 — 새 레포를 내 계정으로 볼 수 있는지 확인하고 있습니다")
        let picked = selection
        Task {
            let report = await model.applySettingsImport(result.file, selected: picked)
            phase = .imported(report)
        }
    }

    private func undo(_ report: SettingsImportReport) {
        phase = .working("되돌리는 중")
        Task {
            await model.undoSettingsImport(report)
            phase = .undone
        }
    }
}

// MARK: - 묶음·항목 줄

/// 선택 집합을 체크박스 여럿의 값으로. 묶음 체크박스가 "일부만 고름(–)" 을 그리게 하려면
/// `Toggle(sources:)` 에 칸마다의 Binding 이 필요하다.
private func selectionFlags(_ ids: [String], _ selection: Binding<Set<String>>) -> Binding<[Bool]> {
    Binding(
        get: { ids.map { selection.wrappedValue.contains($0) } },
        set: { values in
            for (id, isOn) in zip(ids, values) {
                if isOn {
                    selection.wrappedValue.insert(id)
                } else {
                    selection.wrappedValue.remove(id)
                }
            }
        })
}

private func selectionBinding(_ id: String, _ selection: Binding<Set<String>>) -> Binding<Bool> {
    Binding(
        get: { selection.wrappedValue.contains(id) },
        set: { isOn in
            if isOn {
                selection.wrappedValue.insert(id)
            } else {
                selection.wrappedValue.remove(id)
            }
        })
}

private struct TransferSectionView: View {
    let section: TransferSection
    @Binding var selection: Set<String>
    let isExport: Bool

    private var selectable: [String] { section.leaves.filter(\.isSelectable).map(\.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline) {
                if selectable.isEmpty {
                    Text(section.title).font(.headline)
                } else {
                    Toggle(sources: selectionFlags(selectable, $selection), isOn: \.self) {
                        Text(section.title).font(.headline)
                    }
                    .toggleStyle(.checkbox)
                }
                Spacer()
                Text(countText)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            Text(section.summary)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            VStack(alignment: .leading, spacing: 12) {
                ForEach(section.items) { item in
                    TransferItemRow(item: item, selection: $selection, isExport: isExport)
                }
            }
            .padding(.top, 2)
        }
        .padding(12)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.035)))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.primary.opacity(0.08)))
    }

    private var countText: String {
        guard !selectable.isEmpty else { return "모두 지금과 같음" }
        let picked = selectable.filter { selection.contains($0) }.count
        return "\(picked)/\(selectable.count)개 고름"
    }
}

private struct TransferItemRow: View {
    let item: TransferItem
    @Binding var selection: Set<String>
    let isExport: Bool

    private var selectableChildren: [String] { item.children.filter(\.isSelectable).map(\.id) }

    var body: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                if item.children.isEmpty {
                    Toggle(isOn: selectionBinding(item.id, $selection)) {
                        Text(item.title).font(.callout.weight(.medium))
                    }
                    .toggleStyle(.checkbox)
                    .disabled(!item.isSelectable)
                    TransferStatusBadge(status: item.status)
                } else {
                    if selectableChildren.isEmpty {
                        Text(item.title).font(.callout.weight(.medium)).padding(.leading, 20)
                    } else {
                        Toggle(sources: selectionFlags(selectableChildren, $selection), isOn: \.self) {
                            Text(item.title).font(.callout.weight(.medium))
                        }
                        .toggleStyle(.checkbox)
                    }
                    Text(item.value)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 4) {
                if !item.detail.isEmpty {
                    Text(item.detail)
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)
                }
                if item.children.isEmpty {
                    TransferValues(item: item, isExport: isExport)
                }
                if let note = item.note {
                    TransferNote(text: note)
                }
                if !item.children.isEmpty {
                    VStack(alignment: .leading, spacing: 8) {
                        ForEach(item.children) { child in
                            TransferChildRow(item: child, selection: $selection, isExport: isExport)
                        }
                    }
                    .padding(.top, 2)
                }
            }
            .padding(.leading, 20)
        }
    }
}

/// 묶음 안의 한 줄(레포 하나, 로컬 클론 하나).
private struct TransferChildRow: View {
    let item: TransferItem
    @Binding var selection: Set<String>
    let isExport: Bool

    var body: some View {
        VStack(alignment: .leading, spacing: 2) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Toggle(isOn: selectionBinding(item.id, $selection)) {
                    Text(item.title).font(.callout.monospaced())
                }
                .toggleStyle(.checkbox)
                .disabled(!item.isSelectable)
                TransferStatusBadge(status: item.status)
                Spacer(minLength: 0)
            }
            VStack(alignment: .leading, spacing: 2) {
                TransferValues(item: item, isExport: isExport)
                if let note = item.note { TransferNote(text: note) }
            }
            .padding(.leading, 20)
        }
    }
}

/// "가져올 값 / 지금" 두 줄. 같으면 한 줄로 줄인다.
private struct TransferValues: View {
    let item: TransferItem
    let isExport: Bool

    var body: some View {
        Grid(alignment: .leading, horizontalSpacing: 8, verticalSpacing: 2) {
            if item.status == .same {
                GridRow {
                    Text("지금과 같음").foregroundStyle(.secondary)
                    Text(item.value).textSelection(.enabled)
                }
            } else {
                GridRow {
                    Text(isExport ? "담을 값" : "가져올 값").foregroundStyle(.secondary)
                    Text(item.value).textSelection(.enabled)
                }
                if let current = item.current {
                    GridRow {
                        Text("지금").foregroundStyle(.secondary)
                        Text(current).foregroundStyle(.secondary)
                    }
                }
            }
        }
        .font(.caption)
        .fixedSize(horizontal: false, vertical: true)
    }
}

private struct TransferNote: View {
    let text: String

    var body: some View {
        Label(text, systemImage: "exclamationmark.triangle.fill")
            .font(.caption)
            .foregroundStyle(.orange)
            .fixedSize(horizontal: false, vertical: true)
    }
}

private struct TransferStatusBadge: View {
    let status: TransferItem.Status

    var body: some View {
        switch status {
        case .export:
            EmptyView()
        case .added:
            badge("새로 추가", .green)
        case .changed:
            badge("바뀜", .blue)
        case .same:
            badge("지금과 같음", .secondary)
        }
    }

    private func badge(_ text: String, _ color: Color) -> some View {
        Text(text)
            .font(.caption2.weight(.medium))
            .foregroundStyle(color)
            .padding(.horizontal, 6)
            .padding(.vertical, 1)
            .background(color.opacity(0.12), in: Capsule())
    }
}
