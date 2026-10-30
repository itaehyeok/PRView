import Foundation

/// diff 에서 **내용을 보여 줄 이유가 없는 줄**을 가려낸다.
///
/// 아이콘 작업 PR 에 그림을 base64 로 통째로 박은 SVG 가 들어온 적이 있다. 한 줄이
/// 481,449자였다. 사람이 읽을 것은 없는데 화면은 그 줄을 색칠하고 배치하려 든다.
/// 그런 줄은 내용 대신 "무엇이 몇 자 있다" 만 남긴다.
public enum DiffElision {
    /// 이 길이를 넘으면 내용 대신 요약을 보여 준다.
    ///
    /// 실측으로 정한 값이다. 캐시된 diff 181개 파일에서 이 값을 넘는 줄은 셋뿐이고
    /// 셋 다 사람이 읽는 줄이 아니었다(base64 그림 481,449자 · pbxproj 2,795자 · SVG 2,627자).
    /// 반대로 가장 긴 "읽는 줄" 은 1,662자여서, 2,000 은 둘 사이에 넉넉히 들어간다.
    public static let characterLimit = 2_000

    public struct Elided: Sendable, Hashable {
        /// 줄 전체 길이(자).
        public var characterCount: Int
        /// base64 로 박힌 자원의 종류. `image/png` 처럼 온다. 못 알아보면 `nil`.
        public var embeddedType: String?

        /// 화면에 대신 그릴 한 줄.
        public var label: String {
            let size = characterCount.formatted(.number.grouping(.automatic))
            guard let embeddedType else { return "긴 줄 \(size)자 — 내용 생략" }
            return "\(embeddedType) 데이터 \(size)자 — 내용 생략"
        }
    }

    /// 이 줄을 가릴 것인가. 가릴 필요가 없으면 `nil`.
    public static func elision(for line: String) -> Elided? {
        let count = line.count
        guard count > characterLimit else { return nil }
        return Elided(characterCount: count, embeddedType: embeddedType(in: line))
    }

    /// `data:image/png;base64,` 같은 자리에서 종류를 꺼낸다.
    ///
    /// 길이만으로도 가리기는 하지만, 종류를 알면 "왜 안 보이는지" 가 화면에서 바로 읽힌다.
    /// 긴 줄이라 `prefix` 안에서만 찾는다 — 자원 URI 는 줄 앞쪽에 온다.
    static func embeddedType(in line: String) -> String? {
        let head = String(line.prefix(4_000))
        guard let start = head.range(of: "data:"),
              let marker = head.range(of: ";base64,", range: start.upperBound..<head.endIndex)
        else { return nil }
        let type = head[start.upperBound..<marker.lowerBound]
        return type.isEmpty ? nil : String(type)
    }

    /// 여러 줄 덩어리에서 가릴 줄만 요약으로 바꾼다(SVG 소스 보기 같은 곳).
    /// 가릴 줄이 없으면 원문을 그대로 돌려준다 — 큰 문자열을 괜히 다시 만들지 않는다.
    public static func summarized(_ text: String) -> String {
        guard text.count > characterLimit else { return text }
        let lines = text.split(separator: "\n", omittingEmptySubsequences: false)
        guard lines.contains(where: { $0.count > characterLimit }) else { return text }
        return lines
            .map { line -> String in
                guard let elided = elision(for: String(line)) else { return String(line) }
                return "⟨\(elided.label)⟩"
            }
            .joined(separator: "\n")
    }
}
