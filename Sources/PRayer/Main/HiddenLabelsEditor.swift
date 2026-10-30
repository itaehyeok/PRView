import SwiftUI
import PRayerCore

/// "PR 을 숨길 라벨" 목록을 편집하는 화면. `IgnoredAuthorsEditor` 와 같은 모양으로 둔다 —
/// 둘 다 "리뷰 대기에서 무엇을 뺄지" 를 고르는 일이라, 다르게 생기면 다른 기능처럼 읽힌다.
///
/// 라벨 이름은 팀마다 다르다(`DO NOT REVIEW`·`WIP`·`hold`·다른 파트 라벨…). 그래서 손으로
/// 치기보다 **지금 받아 둔 PR 에 실제로 붙은 라벨**에서 고르게 한다 — 오타 한 글자면 아무것도
/// 안 걸리는데 화면은 "넣었다" 고 말해서, 왜 안 숨겨지는지 알 길이 없다.
struct HiddenLabelsEditor: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    @State private var typed = ""

    private struct Candidate: Identifiable {
        var label: String
        var count: Int
        var id: String { label.lowercased() }
    }

    /// 받아 둔 PR 에 붙은 라벨 중 아직 안 넣은 것, 붙은 PR 수와 함께. 많이 쓰는 것부터.
    private var candidates: [Candidate] {
        var counts: [String: Candidate] = [:]
        for label in model.prs.flatMap(\.labels) where !model.settings.isHiddenLabel(label) {
            counts[label.lowercased(), default: Candidate(label: label, count: 0)].count += 1
        }
        return counts.values.sorted {
            $0.count != $1.count ? $0.count > $1.count : $0.id < $1.id
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            VStack(alignment: .leading, spacing: 3) {
                Text("PR 을 숨길 라벨").font(.title3.bold())
                Text("여기 넣은 라벨이 붙은 PR 은 'To review' 에서 빠지고, 상세 화면에 리뷰할 필요가 없다고 표시됩니다. 대소문자는 가리지 않습니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            section("지금 숨기는 라벨 \(model.settings.hiddenLabels.count)개",
                    rows: model.settings.hiddenLabels.count) {
                if model.settings.hiddenLabels.isEmpty {
                    HStack(spacing: 6) {
                        Text("아직 없습니다.").font(.callout).foregroundStyle(.tertiary)
                        // 처음 쓰는 팀이 가장 흔한 관례를 한 번에 넣을 수 있게.
                        ForEach(Settings.defaultHiddenLabels, id: \.self) { label in
                            Button("\(label) 넣기") { model.toggleHiddenLabel(label) }
                                .buttonStyle(.link)
                                .font(.callout)
                        }
                    }
                } else {
                    ForEach(model.settings.hiddenLabels, id: \.self) { label in
                        row(label, detail: nil, symbol: "minus.circle.fill", tint: .red) {
                            model.toggleHiddenLabel(label)
                        }
                    }
                }
            }

            section("받아 둔 PR 에 붙은 라벨", rows: candidates.count) {
                if candidates.isEmpty {
                    Text(model.prs.isEmpty ? "아직 받아 둔 PR 이 없습니다." : "붙은 라벨이 모두 들어 있습니다.")
                        .font(.callout)
                        .foregroundStyle(.tertiary)
                } else {
                    ForEach(candidates) { item in
                        row(item.label, detail: "\(item.count)건", symbol: "plus.circle.fill", tint: .accentColor) {
                            model.toggleHiddenLabel(item.label)
                        }
                    }
                }
            }

            HStack(spacing: 6) {
                TextField("목록에 없는 라벨 이름", text: $typed)
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
        guard !trimmed.isEmpty, !model.settings.isHiddenLabel(trimmed) else { return }
        model.toggleHiddenLabel(trimmed)
        typed = ""
    }

    /// 높이를 줄 수에 맞춘다 — ScrollView 는 준 공간을 끝까지 먹어서, 비어 있어도 상자가 커진다.
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

    private func row(_ label: String, detail: String?, symbol: String, tint: Color,
                     action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Image(systemName: symbol).foregroundStyle(tint)
                // 라벨 이름은 다른 자리와 같은 모양으로(PRLabels — 태그 아이콘, 경고성은 빨강).
                PRLabels.text([label], font: .callout) ?? Text(label).font(.callout)
                if let detail {
                    Text(detail).font(.caption2).foregroundStyle(.tertiary)
                }
                Spacer(minLength: 0)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}
