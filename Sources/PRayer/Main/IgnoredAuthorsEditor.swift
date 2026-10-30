import SwiftUI
import PRayerCore

/// "PR 을 숨길 사람" 목록을 편집하는 화면.
///
/// 설정 창에 두지 않은 이유: 이 목록을 손보고 싶어지는 순간은 **목록을 보다가**이지
/// 설정을 뒤지다가가 아니다. 필터 팝오버에서 바로 열린다.
///
/// 로그인을 손으로 치는 것은 마지막 수단으로만 둔다 — 오타 한 글자면 아무도 안 걸리는데
/// 화면은 "넣었다" 고 말하므로, 왜 안 숨겨지는지 알 길이 없다.
struct IgnoredAuthorsEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var typed = ""

    /// 지금 받아 둔 PR 의 작성자 중 아직 안 넣은 사람. 내가 올린 것은 뺀다.
    private var candidates: [String] {
        let ignored = Set(model.settings.ignoredAuthors.map { $0.lowercased() })
        var seen = Set<String>()
        return model.prs
            .filter { !$0.viewerDidAuthor }
            .map(\.author)
            .filter { !ignored.contains($0.lowercased()) && seen.insert($0.lowercased()).inserted }
            .sorted { $0.lowercased() < $1.lowercased() }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("PR 을 숨길 사람").font(.title3.bold())
                Text("여기 넣은 사람이 올린 PR 은 'To review' 에서 빠집니다. 내가 올린 PR 은 영향받지 않습니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }

            section("지금 숨기는 사람 \(model.settings.ignoredAuthors.count)명",
                    rows: model.settings.ignoredAuthors.count) {
                if model.settings.ignoredAuthors.isEmpty {
                    Text("아직 없습니다. 아래에서 고르세요.")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                } else {
                    ForEach(model.settings.ignoredAuthors, id: \.self) { login in
                        row(login: login, symbol: "minus.circle.fill", tint: .red) {
                            model.toggleIgnoredAuthor(login)
                        }
                    }
                }
            }

            section("목록에 있는 사람", rows: candidates.count) {
                if candidates.isEmpty {
                    Text("받아 둔 PR 의 작성자가 모두 들어 있습니다.")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                } else {
                    ForEach(candidates, id: \.self) { login in
                        row(login: login, symbol: "plus.circle.fill", tint: .accentColor) {
                            model.toggleIgnoredAuthor(login)
                        }
                    }
                }
            }

            HStack(spacing: 6) {
                TextField("목록에 없는 사람의 GitHub 로그인", text: $typed)
                    .textFieldStyle(.roundedBorder)
                    .onSubmit(addTyped)
                Button("추가", action: addTyped)
                    .disabled(typed.trimmingCharacters(in: .whitespaces).isEmpty)
            }

            HStack {
                Spacer()
                Button("완료") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(18)
        .frame(width: 420)
    }

    private func addTyped() {
        let trimmed = typed.trimmingCharacters(in: .whitespaces)
        guard !trimmed.isEmpty, !model.settings.isIgnoredAuthor(trimmed) else { return }
        model.toggleIgnoredAuthor(trimmed)
        typed = ""
    }

    /// ScrollView 는 준 공간을 끝까지 먹는다. 높이를 고정하지 않으면 **비어 있어도**
    /// 상자가 그대로 커서 안내 한 줄에 132pt 를 쓴다(실측). 줄 수에 맞춰 준다.
    private func section<Content: View>(_ title: String,
                                        rows: Int,
                                        @ViewBuilder content: () -> Content) -> some View {
        let height = min(max(rows, 1), 6) * 24 + 14
        return VStack(alignment: .leading, spacing: 4) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            ScrollView {
                VStack(alignment: .leading, spacing: 2) { content() }
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(6)
            }
            .frame(height: CGFloat(height))
            .background(.quinary.opacity(0.6), in: RoundedRectangle(cornerRadius: 6))
        }
    }

    private func row(login: String, symbol: String, tint: Color, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol).foregroundStyle(tint)
                Text(model.settings.displayName(login)).font(.callout)
                // 별명을 쓰면 실제 로그인이 안 보인다. 동명이인을 가릴 수 있어야 한다.
                if model.settings.displayName(login) != login {
                    Text(login).font(.caption2).foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .padding(.vertical, 1)
    }
}
