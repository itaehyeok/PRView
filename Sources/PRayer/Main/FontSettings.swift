import SwiftUI
import AppKit
import PRayerCore

/// 설정의 "글꼴" 탭. 코드 글꼴(diff · 코드 스니펫 · 인라인 코드)을 고르고 바로 아래 미리보기로 본다.
///
/// 크기는 여기서 **코드만** 바꾼다. ⌘+ / ⌘- 는 코드·UI·코멘트를 같이 움직인다(AppModel.changeFontSize).
struct FontSettings: View {
    @Environment(AppModel.self) private var model
    /// 이 맥의 고정폭 글꼴 목록. 글꼴 관리자를 훑으므로 탭이 뜰 때 한 번만 읽는다.
    @State private var others: [CodeFontCatalog.Option] = []

    var body: some View {
        @Bindable var model = model
        Form {
            Section {
                Picker("글꼴", selection: fontName) {
                    Section("앱에 들어 있음") { options(CodeFontCatalog.bundled) }
                    Section("macOS") { options(CodeFontCatalog.system) }
                    if !others.isEmpty {
                        Section("그 밖의 고정폭 글꼴") { options(others) }
                    }
                }
                LabeledContent("크기") {
                    HStack(spacing: 8) {
                        Text("\(Int(model.settings.codeFontSize))pt")
                            .monospacedDigit()
                        Stepper("크기", value: $model.settings.codeFontSize, in: 9...20, step: 1)
                            .labelsHidden()
                    }
                }
            } header: {
                Text("코드 글꼴 — diff · 코드 스니펫 · 인라인 코드")
            } footer: {
                Text(CodeFontCatalog.note(for: model.settings.codeFontName))
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            Section("미리보기") {
                CodeFontPreview()
            }
        }
        .formStyle(.grouped)
        .onAppear { others = CodeFontCatalog.others(current: model.settings.codeFontName) }
        // 다른 탭처럼 창을 닫을 때가 아니라 바로 저장한다 — 고르는 즉시 뒤의 diff 가 바뀌어서, 저장이 늦으면
        // 앱을 끌 때 본 글꼴과 다음에 켰을 때 글꼴이 달라질 수 있다.
        .onChange(of: model.settings.codeFontName) { Task { await model.save() } }
        .onChange(of: model.settings.codeFontSize) { Task { await model.save() } }
    }

    /// 고르면 "직접 고른 글꼴" 로 표시한다. 그래야 Menlo 를 골라도 옛 기본값으로 보고 옮기지 않는다(Settings.codeFontChosen).
    private var fontName: Binding<String> {
        Binding(
            get: { model.settings.codeFontName },
            set: { name in
                model.settings.codeFontName = name
                model.settings.codeFontChosen = true
            }
        )
    }

    private func options(_ list: [CodeFontCatalog.Option]) -> some View {
        ForEach(list) { option in
            Text(option.label).tag(option.name)
        }
    }
}

/// 글꼴 탭에 보이는 코드 글꼴 목록.
enum CodeFontCatalog {
    struct Option: Identifiable, Hashable {
        /// `Settings.codeFontName` 에 들어가는 값. 빈 이름은 시스템 고정폭(SF Mono).
        let name: String
        let label: String
        var id: String { name }
    }

    static let bundled = [
        Option(name: "IBM Plex Mono", label: "IBM Plex Mono (기본)"),
        Option(name: "D2Coding", label: "D2Coding"),
    ]
    static let system = [
        Option(name: "", label: "SF Mono"),
        Option(name: "Menlo", label: "Menlo"),
    ]

    /// 위 두 묶음에 없는, 이 맥의 고정폭 글꼴(계열 이름).
    /// 한자·가나만 있고 한글이 없는 중국어·일본어 글꼴은 뺀다 — 고정폭으로 표시돼 있지만 코드용이 아니다
    /// (실측: BIZ UDGothic · Osaka · Lantinghei TC 가 섞여 나왔다).
    /// 지금 쓰는 글꼴이 목록에 없으면(설정 가져오기로 받았는데 이 맥에 없는 글꼴 등) 맨 앞에 넣는다 — 고르기 칸이
    /// 빈칸으로 보이지 않게.
    static func others(current: String) -> [Option] {
        let listed = Set((bundled + system).map(\.name))
        let families = Set((NSFontManager.shared.availableFontNames(with: .fixedPitchFontMask) ?? [])
            .compactMap { NSFont(name: $0, size: 12) }
            .filter { !isChineseOrJapaneseOnly($0) }
            .compactMap(\.familyName))
        var result = families.subtracting(listed)
            .filter { !$0.hasPrefix(".") }
            .sorted()
            .map { Option(name: $0, label: $0) }
        if !listed.contains(current), !result.contains(where: { $0.name == current }) {
            result.insert(Option(name: current, label: "\(current) (이 맥에 없음)"), at: 0)
        }
        return result
    }

    private static func isChineseOrJapaneseOnly(_ font: NSFont) -> Bool {
        let covered = font.coveredCharacterSet
        let hanja = Unicode.Scalar(0x4E00 as UInt32).map(covered.contains) ?? false
        let hangul = Unicode.Scalar(0xAC00 as UInt32).map(covered.contains) ?? false
        return hanja && !hangul
    }

    static func note(for name: String) -> String {
        switch name {
        case "IBM Plex Mono": return "한글은 같은 계열인 IBM Plex Sans KR 로 채웁니다."
        case "D2Coding": return "한글 고정폭 — 한글 한 글자가 영문 두 칸이라 한글 주석이 있어도 줄이 맞습니다."
        case "": return "macOS 기본 고정폭. 한글은 IBM Plex Sans KR 로 채웁니다."
        case "Menlo": return "예전 기본값. 글자 폭이 넓습니다. 한글은 IBM Plex Sans KR 로 채웁니다."
        default: return "글꼴에 한글이 없으면 IBM Plex Sans KR 로 채웁니다."
        }
    }
}

/// 글꼴 탭의 미리보기. diff 와 같은 부품(CodeLineText · MarkdownText)으로 그려서 실제 화면과 같게 보인다.
/// 문법 색·한글 주석·헷갈리는 글자(0O lI1)·코멘트 속 인라인 코드를 한 번에 본다.
struct CodeFontPreview: View {
    @Environment(AppModel.self) private var model

    private struct Line: Identifiable {
        let id: Int
        let old: Int?
        let new: Int?
        let kind: DiffLine.Kind
        let text: String
    }

    private static let lines = [
        Line(id: 0, old: 12, new: 12, kind: .context, text: "func loadReviews() async {"),
        Line(id: 1, old: 13, new: nil, kind: .deletion, text: "    let items = try await api.page(0)"),
        Line(id: 2, old: nil, new: 13, kind: .addition, text: "    // 리뷰 요청 목록을 불러온다 — 실패하면 빈 목록"),
        Line(id: 3, old: nil, new: 14, kind: .addition, text: "    let items: [Review] = (try? await api.page(1)) ?? []"),
        Line(id: 4, old: 14, new: 15, kind: .context, text: "    render(items, title: \"리뷰 대기 0O lI1\")"),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text("@@ -12,6 +12,7 @@ func loadReviews()")
                .font(model.fonts.code())
                .foregroundStyle(.secondary)
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
            ForEach(Self.lines) { line in
                HStack(spacing: 8) {
                    Text(line.old.map(String.init) ?? "")
                        .frame(width: 28, alignment: .trailing)
                    Text(line.new.map(String.init) ?? "")
                        .frame(width: 28, alignment: .trailing)
                    HStack(spacing: 0) {
                        Text(marker(line.kind))
                        CodeLineText(text: line.text, profile: CodeSyntax.swift,
                                     font: model.fonts.code(), dimmed: line.kind == .context)
                    }
                    Spacer(minLength: 0)
                }
                .font(model.fonts.code())
                .foregroundStyle(line.kind == .context ? Color.secondary : Color.primary)
                .padding(.horizontal, 10)
                .padding(.vertical, 1)
                .background(background(line.kind))
            }
            Divider()
                .padding(.vertical, 8)
            MarkdownText(text: "코멘트 속 인라인 코드: `loadReviews()` 가 실패하면 `빈 목록`을 그립니다.")
                .padding(.horizontal, 10)
        }
        .padding(.vertical, 4)
    }

    // diff 화면(DiffView)과 같은 기호·색이다.
    private func marker(_ kind: DiffLine.Kind) -> String {
        switch kind {
        case .addition: return "+ "
        case .deletion: return "− "
        default: return "  "
        }
    }

    private func background(_ kind: DiffLine.Kind) -> Color {
        switch kind {
        case .addition: return Color.green.opacity(0.14)
        case .deletion: return Color.red.opacity(0.14)
        default: return Color.clear
        }
    }
}
