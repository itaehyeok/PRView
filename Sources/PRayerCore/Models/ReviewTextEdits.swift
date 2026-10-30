import Foundation

/// 사용자가 리뷰 본문에서 고친 글.
///
/// 모델 출력(`ReviewRecord.output`)은 건드리지 않고 고친 값만 여기에 따로 둔다. 항목 키(`ReviewItemKey`)가
/// 원문에서 나와서 — 질문 키는 문장의 해시다 — 원문을 바꾸면 정리 표시·인라인으로 옮김·diff 에서 봄 같은
/// 항목에 붙은 상태를 전부 잃는다. "Claude 원문으로" 되돌릴 자리도 남아야 한다.
public struct ReviewTextEdits: Sendable, Codable, Equatable {
    /// 요약 문단. nil 이면 원문.
    public var summary: String?
    /// 잘된 점 목록. nil 이면 원문.
    public var strengths: [String]?
    /// 우려사항 제목·질문 문장. `ReviewItemKey` → 고친 문장.
    public var items: [String: String]

    public init(summary: String? = nil, strengths: [String]? = nil, items: [String: String] = [:]) {
        self.summary = summary
        self.strengths = strengths
        self.items = items
    }

    var isEmpty: Bool { summary == nil && strengths == nil && items.isEmpty }

    /// 잘된 점 편집기에 넣는 글. 한 줄이 항목 하나다 — 게시 본문의 불릿 모양 그대로 보여 준다.
    public static func editorText(strengths: [String]) -> String {
        strengths.map { "- \($0)" }.joined(separator: "\n")
    }

    /// 편집기 글 → 잘된 점 목록. 불릿 기호는 앞에 쳤든 안 쳤든 받아 준다(본문에는 늘 "- " 로 붙는다).
    public static func strengths(fromEditorText text: String) -> [String] {
        text.split(whereSeparator: \.isNewline).compactMap { raw in
            var line = raw.trimmingCharacters(in: .whitespaces)
            for bullet in ["- ", "* ", "• ", "-", "*", "•"] where line.hasPrefix(bullet) {
                line = String(line.dropFirst(bullet.count)).trimmingCharacters(in: .whitespaces)
                break
            }
            return line.isEmpty ? nil : line
        }
    }
}

extension ReviewRecord {
    /// 본문에 올라갈 요약. 고쳤으면 고친 값.
    public var effectiveSummary: String {
        (textEdits?.summary ?? output.summaryKo).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    public var effectiveStrengths: [String] { textEdits?.strengths ?? output.strengths }

    public func text(for concern: Concern) -> String {
        textEdits?.items[ReviewItemKey.concern(concern)] ?? concern.title
    }

    public func text(for question: AuthorQuestion) -> String {
        textEdits?.items[ReviewItemKey.question(question)] ?? question.question
    }

    public var isSummaryEdited: Bool { textEdits?.summary != nil }
    public var isStrengthsEdited: Bool { textEdits?.strengths != nil }

    public func isEdited(itemKey: String) -> Bool { textEdits?.items[itemKey] != nil }

    /// 원문과 같아지면 고친 값을 지운다 — "수정함" 표시가 내용이 아니라 실제로 다른지를 말하게.
    public mutating func setSummaryEdit(_ text: String?) {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        let original = output.summaryKo.trimmingCharacters(in: .whitespacesAndNewlines)
        updateEdits { $0.summary = (trimmed == nil || trimmed == original) ? nil : trimmed }
    }

    public mutating func setStrengthsEdit(_ strengths: [String]?) {
        let original = output.strengths.map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        updateEdits { $0.strengths = (strengths == nil || strengths == original) ? nil : strengths }
    }

    /// 우려사항 제목·질문 문장. `original` 은 그 항목의 원문.
    public mutating func setItemEdit(_ text: String?, for key: String, original: String) {
        let trimmed = text?.trimmingCharacters(in: .whitespacesAndNewlines)
        let source = original.trimmingCharacters(in: .whitespacesAndNewlines)
        updateEdits { edits in
            if let trimmed, !trimmed.isEmpty, trimmed != source {
                edits.items[key] = trimmed
            } else {
                edits.items.removeValue(forKey: key)
            }
        }
    }

    private mutating func updateEdits(_ change: (inout ReviewTextEdits) -> Void) {
        var edits = textEdits ?? ReviewTextEdits()
        change(&edits)
        // 다 되돌렸으면 필드째 비운다. 옛 기록과 같은 모양이 된다.
        textEdits = edits.isEmpty ? nil : edits
    }
}
