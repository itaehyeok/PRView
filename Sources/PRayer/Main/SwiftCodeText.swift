import SwiftUI
import PRayerCore

/// Swift 코드 한 덩어리를 색칠해서 그린다. 색은 Xcode 기본 테마에 가깝게 잡되
/// 라이트/다크 모두에서 읽히도록 시스템 색을 쓴다.
struct SwiftCodeText: View {
    let code: String
    var profile: SyntaxProfile = CodeSyntax.swift
    var font: Font = .system(size: 11.5, design: .monospaced)

    var body: some View {
        // base64 로 그림을 박은 SVG 처럼, 읽을 것이 없는 긴 줄은 요약으로 바꿔서 넘긴다.
        Text(SyntaxColors.attributed(DiffElision.summarized(code), profile: profile, font: font))
            .font(font)
            .textSelection(.enabled)
    }
}

/// diff 한 줄. 색칠 결과를 캐시해 스크롤 중 같은 줄을 다시 계산하지 않는다.
struct CodeLineText: View {
    let text: String
    let profile: SyntaxProfile?
    var font: Font = .system(size: 11.5, design: .monospaced)
    var dimmed = false

    var body: some View {
        // 자원이 통째로 박힌 줄(base64 그림 등)은 내용을 그리지 않는다.
        // 읽을 것이 없는데 색칠·배치 비용만 크고, 옆줄까지 같이 느려진다.
        if let elided = DiffElision.elision(for: text) {
            Text(elided.label)
                .font(font)
                .foregroundStyle(.secondary)
                .padding(.horizontal, 5)
                .padding(.vertical, 1)
                .background(Color.secondary.opacity(0.12), in: RoundedRectangle(cornerRadius: 4))
                .help("\(elided.characterCount)자 — 사람이 읽을 내용이 아니라 가렸습니다")
        } else if let profile, !text.isEmpty {
            Text(SyntaxColors.cachedAttributed(text, profile: profile, font: font))
                .opacity(dimmed ? 0.75 : 1)
        } else {
            // 색칠 규칙이 없는 파일(.md 등)도 받은 글꼴로 그린다 — 빼먹으면 둘레 글꼴을 물려받아,
            // 제목 속 코드의 미리보기에서 줄이 제목 크기로 커졌다.
            Text(text)
                .font(font)
        }
    }
}

@MainActor
enum SyntaxColors {
    static func color(for kind: SyntaxKind) -> Color {
        switch kind {
        case .keyword: return .pink
        case .type: return .teal
        case .string: return .red
        case .number: return .orange
        case .comment: return .secondary
        case .attribute: return .purple
        // 아래는 마크다운 코드 블록 프로파일만 낸다(CodeSyntax+Languages).
        case .constant: return .pink
        case .meta: return .purple
        case .inserted: return .green
        case .deleted: return .red
        case .function, .property, .tag, .plain: return .primary
        }
    }

    private struct CacheKey: Hashable {
        let profile: String
        let code: String
        let font: Font
    }

    private static var cache: [CacheKey: AttributedString] = [:]

    /// diff 는 같은 줄을 반복해 그린다. 줄 단위로 캐시해 스크롤을 가볍게 유지한다.
    /// 글꼴도 키에 넣는다. 색칠한 글에는 글꼴이 박혀 있어서, 빼면 글꼴·크기(⌘+ / ⌘-)를 바꿔도
    /// 이미 한 번 그린 줄은 옛 글꼴로 남는다.
    static func cachedAttributed(_ code: String, profile: SyntaxProfile, font: Font) -> AttributedString {
        let key = CacheKey(profile: profile.id, code: code, font: font)
        if let hit = cache[key] { return hit }
        let value = attributed(code, profile: profile, font: font)
        // 아주 큰 파일에서 무한히 늘지 않게 상한을 둔다.
        if cache.count > 6_000 { cache.removeAll(keepingCapacity: true) }
        cache[key] = value
        return value
    }

    /// 토큰 구간만 색을 덧칠한다. 구간이 없으면 원문 그대로다.
    static func attributed(_ code: String, profile: SyntaxProfile = CodeSyntax.swift, font: Font) -> AttributedString {
        var result = AttributedString(code)
        result.font = font
        let characters = Array(code)
        for span in CodeSyntax.spans(in: code, profile: profile) {
            guard span.length > 0,
                  span.start >= 0,
                  span.start + span.length <= characters.count else { continue }
            let view = result.characters
            guard let lower = view.index(view.startIndex, offsetBy: span.start, limitedBy: view.endIndex),
                  let upper = view.index(lower, offsetBy: span.length, limitedBy: view.endIndex)
            else { continue }
            result[lower..<upper].foregroundColor = color(for: span.kind)
        }
        return result
    }
}
