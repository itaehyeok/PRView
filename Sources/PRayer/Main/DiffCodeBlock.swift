import SwiftUI
import PRayerCore

/// 코멘트 속 ```diff 블록을 변경 파일 탭 diff 처럼 그린다 — 더한 줄·뺀 줄은 줄 전체에 옅은 초록·빨강, `@@` 줄은 회색 띠에
/// 흐린 글자(사용자 결정: diff 화면 쪽이 낫다). 줄은 옆으로 스크롤하지 않고 접는다(diff 화면과 같다).
///
/// `+++ b/경로` 줄이 있으면 그 확장자로 줄 안 코드도 diff 화면과 같은 색으로 칠한다. 없으면 글자는 기본색.
struct DiffCodeBlock: View {
    let code: String
    let font: Font
    /// 기준 글자 크기. 줄 여백을 여기에 맞춘다.
    let size: CGFloat

    private enum LineKind {
        case added, removed, header, context
    }

    private struct Line {
        let kind: LineKind
        /// 줄 머리(`+`·`-`·빈칸) 한 글자. 머리 줄(`@@`·`+++`)은 비워 두고 전체를 text 에 둔다.
        let marker: String
        let text: String
    }

    var body: some View {
        let lines = Self.lines(in: code)
        let profile = Self.profile(for: lines)
        VStack(alignment: .leading, spacing: 0) {
            ForEach(lines.indices, id: \.self) { index in
                row(lines[index], profile: profile)
            }
        }
        .padding(.vertical, size * 0.5)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04))
        .clipShape(RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private func row(_ line: Line, profile: SyntaxProfile?) -> some View {
        let content: Text = if line.kind == .header {
            Text(line.text)
        } else if let profile, !line.text.isEmpty {
            Text("\(Text(line.marker).foregroundStyle(.secondary))\(Text(SyntaxColors.attributed(line.text, profile: profile, font: font)))")
        } else {
            Text("\(Text(line.marker).foregroundStyle(.secondary))\(Text(line.text))")
        }
        content
            .font(font)
            .foregroundStyle(line.kind == .header ? AnyShapeStyle(.secondary) : AnyShapeStyle(.primary))
            .fixedSize(horizontal: false, vertical: true)
            .padding(.horizontal, size)
            .padding(.vertical, line.kind == .header ? 3 : 0.5)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(background(line.kind))
    }

    /// 변경 파일 탭 diff 의 줄 바탕과 같은 값(DiffRowView.background · hunk 머리글).
    private func background(_ kind: LineKind) -> AnyShapeStyle {
        switch kind {
        case .added: AnyShapeStyle(Color.green.opacity(0.14))
        case .removed: AnyShapeStyle(Color.red.opacity(0.14))
        case .header: AnyShapeStyle(.quaternary.opacity(0.35))
        case .context: AnyShapeStyle(Color.clear)
        }
    }

    private static func lines(in code: String) -> [Line] {
        code.split(separator: "\n", omittingEmptySubsequences: false).map { raw in
            let line = String(raw)
            if line.hasPrefix("+++") || line.hasPrefix("---") || line.hasPrefix("@@")
                || line.hasPrefix("diff --git") || line.hasPrefix("index ") {
                return Line(kind: .header, marker: "", text: line)
            }
            let marker = line.first.map(String.init) ?? ""
            let rest = String(line.dropFirst())
            switch marker {
            case "+": return Line(kind: .added, marker: marker, text: rest)
            case "-": return Line(kind: .removed, marker: marker, text: rest)
            case " ": return Line(kind: .context, marker: marker, text: rest)
            // 머리 글자 없이 붙여 넣은 줄은 그대로 둔다.
            default: return Line(kind: .context, marker: "", text: line)
            }
        }
    }

    /// `+++ b/App/Login.swift` 의 확장자로 색칠 규칙을 고른다(변경 파일 탭과 같은 고르기).
    private static func profile(for lines: [Line]) -> SyntaxProfile? {
        guard let header = lines.first(where: { $0.kind == .header && $0.text.hasPrefix("+++") }) else {
            return nil
        }
        let path = header.text.dropFirst(3).trimmingCharacters(in: .whitespaces)
        let trimmed = path.hasPrefix("b/") ? String(path.dropFirst(2)) : path
        return CodeSyntax.profile(forPath: trimmed)
    }
}
