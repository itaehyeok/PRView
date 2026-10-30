import Foundation

public enum Verdict: String, Sendable, Codable, CaseIterable {
    case approve
    case comment
    case requestChanges = "request_changes"
}

public enum Severity: String, Sendable, Codable, CaseIterable {
    case blocker
    case major
    case minor
    case nit

    public var rank: Int {
        switch self {
        case .blocker: return 0
        case .major: return 1
        case .minor: return 2
        case .nit: return 3
        }
    }

    public var label: String {
        switch self {
        case .blocker: return "치명"
        case .major: return "높음"
        case .minor: return "보통"
        case .nit: return "사소"
        }
    }

    /// 머지를 막을 수준인가.
    public var isBlocking: Bool { self == .blocker || self == .major }
}

public enum DiffSide: String, Sendable, Codable {
    case left = "LEFT"
    case right = "RIGHT"
}

public struct Concern: Sendable, Codable, Hashable, Identifiable {
    public var issueKey: String
    public var severity: Severity
    public var title: String
    public var path: String
    public var line: Int?
    public var side: DiffSide?
    public var anchorText: String?
    /// 이미 누가 지적한 사안인가. 예전에는 초안 코멘트에만 있었는데, 우려사항에도 있어야
    /// "이거 아까 그 얘기 아닌가?" 를 화면에서 알 수 있다.
    public var duplicatesExisting: Bool?
    /// 누가 무엇을 지적했는지 한 줄.
    public var existingNote: String?

    public var id: String { issueKey }
    public var isDuplicate: Bool { duplicatesExisting == true }

    enum CodingKeys: String, CodingKey {
        case issueKey = "issue_key"
        case severity, title, path, line, side
        case anchorText = "anchor_text"
        case duplicatesExisting = "duplicates_existing"
        case existingNote = "existing_note"
    }

    public init(issueKey: String, severity: Severity, title: String, path: String,
                line: Int? = nil, side: DiffSide? = nil, anchorText: String? = nil,
                duplicatesExisting: Bool? = nil, existingNote: String? = nil) {
        self.issueKey = issueKey
        self.severity = severity
        self.title = title
        self.path = path
        self.line = line
        self.side = side
        self.anchorText = anchorText
        self.duplicatesExisting = duplicatesExisting
        self.existingNote = existingNote
    }
}

/// 코멘트·질문의 근거가 되는 코드 위치. 사용자가 눌러서 diff 로 이동한다.
public struct CodeEvidence: Sendable, Codable, Hashable, Identifiable {
    public var path: String
    public var line: Int?
    /// 이 위치가 왜 근거가 되는지 한 줄.
    public var note: String

    public var id: String { "\(path)#\(line ?? -1)#\(note)" }
    public var fileName: String { (path as NSString).lastPathComponent }

    public init(path: String, line: Int? = nil, note: String) {
        self.path = path
        self.line = line
        self.note = note
    }
}

/// 작성자에게 물어볼 것 1건. 옛 기록에는 문자열로만 저장돼 있어 둘 다 읽는다.
public struct AuthorQuestion: Sendable, Codable, Hashable, Identifiable {
    /// 항목을 가리키는 안정된 이름. 옛 기록과 옛 형식(문자열 하나)에는 없어서 optional 이다.
    /// 없을 때 쓸 값은 `stableKey` 가 만든다.
    public var issueKey: String?
    public var question: String
    /// 왜 묻는지 — 코드를 잘 모르는 상태에서도 판단할 수 있게 쉬운 말로.
    public var rationaleKo: String?
    public var evidence: [CodeEvidence]?
    /// 이미 누가 물었거나 답한 사안인가.
    public var duplicatesExisting: Bool?
    public var existingNote: String?

    public var id: String { stableKey }
    public var isDuplicate: Bool { duplicatesExisting == true }

    /// 무언가를 이 질문에 매달아 저장할 때 쓰는 열쇠.
    ///
    /// `id` 를 질문 본문으로 두면 본문이 한 글자만 바뀌어도 딴 항목이 되고, 저장해 둔
    /// 재확인 결과가 통째로 미아가 된다. 모델이 준 `issue_key` 를 우선 쓰고,
    /// 없으면 본문에서 **실행에 무관한** 해시를 만들어 쓴다(FNV-1a).
    public var stableKey: String {
        if let issueKey, !issueKey.isEmpty { return issueKey }
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in question.trimmingCharacters(in: .whitespacesAndNewlines).utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        return "q:" + String(hash, radix: 16)
    }

    enum CodingKeys: String, CodingKey {
        case issueKey = "issue_key"
        case question
        case rationaleKo = "rationale_ko"
        case evidence
        case duplicatesExisting = "duplicates_existing"
        case existingNote = "existing_note"
    }

    public init(question: String, rationaleKo: String? = nil, evidence: [CodeEvidence]? = nil,
                issueKey: String? = nil, duplicatesExisting: Bool? = nil, existingNote: String? = nil) {
        self.issueKey = issueKey
        self.question = question
        self.rationaleKo = rationaleKo
        self.evidence = evidence
        self.duplicatesExisting = duplicatesExisting
        self.existingNote = existingNote
    }

    public init(from decoder: Decoder) throws {
        // 옛 형식: 그냥 문자열 하나.
        if let single = try? decoder.singleValueContainer(), let text = try? single.decode(String.self) {
            issueKey = nil
            question = text
            rationaleKo = nil
            evidence = nil
            duplicatesExisting = nil
            existingNote = nil
            return
        }
        let container = try decoder.container(keyedBy: CodingKeys.self)
        issueKey = try? container.decodeIfPresent(String.self, forKey: .issueKey)
        question = try container.decode(String.self, forKey: .question)
        rationaleKo = try? container.decodeIfPresent(String.self, forKey: .rationaleKo)
        evidence = try? container.decodeIfPresent([CodeEvidence].self, forKey: .evidence)
        duplicatesExisting = try? container.decodeIfPresent(Bool.self, forKey: .duplicatesExisting)
        existingNote = try? container.decodeIfPresent(String.self, forKey: .existingNote)
    }
}

public struct DraftComment: Sendable, Codable, Hashable, Identifiable {
    public var issueKey: String
    public var path: String
    public var line: Int
    public var startLine: Int?
    public var side: DiffSide
    public var body: String
    public var severity: Severity
    public var anchorText: String
    /// 이미 사람 리뷰 스레드에서 지적된 사안인지. true 면 본문이 "이미 언급된 사항인데…" 형태여야 한다.
    public var duplicatesExisting: Bool?
    /// 어떤 기존 코멘트와 겹치는지(작성자·요약).
    public var existingNote: String?
    /// 왜 이 코멘트를 다는지 — 게시 전에 사용자가 스스로 판단할 수 있게 쉬운 말로 설명한다.
    public var rationaleKo: String?
    /// 그 판단의 근거가 되는 코드 위치.
    public var evidence: [CodeEvidence]?

    public var id: String { issueKey }
    public var isDuplicate: Bool { duplicatesExisting == true }

    enum CodingKeys: String, CodingKey {
        case issueKey = "issue_key"
        case path, line
        case startLine = "start_line"
        case side, body, severity
        case anchorText = "anchor_text"
        case duplicatesExisting = "duplicates_existing"
        case existingNote = "existing_note"
        case rationaleKo = "rationale_ko"
        case evidence
    }

    public init(issueKey: String, path: String, line: Int, startLine: Int? = nil, side: DiffSide,
                body: String, severity: Severity, anchorText: String,
                duplicatesExisting: Bool? = nil, existingNote: String? = nil,
                rationaleKo: String? = nil, evidence: [CodeEvidence]? = nil) {
        self.issueKey = issueKey
        self.path = path
        self.line = line
        self.startLine = startLine
        self.side = side
        self.body = body
        self.severity = severity
        self.anchorText = anchorText
        self.duplicatesExisting = duplicatesExisting
        self.existingNote = existingNote
        self.rationaleKo = rationaleKo
        self.evidence = evidence
    }
}

/// 리뷰 엔진의 구조화 출력.
public struct ReviewOutput: Sendable, Codable, Hashable {
    public var verdict: Verdict
    public var summaryKo: String
    public var concerns: [Concern]
    public var strengths: [String]
    public var draftComments: [DraftComment]
    public var questionsForAuthor: [AuthorQuestion]?
    /// 우려사항·질문을 본문에 넣을 때만 요약 뒤에 붙는 안내 한 문장.
    ///
    /// 요약 본문은 다른 항목을 가리키면 안 된다 — 사용자가 요약만 켜서 승인으로 올리는 일이
    /// 많은데, "아래에 질문으로 남깁니다" 같은 문장이 섞여 있으면 본문에 없는 것을 가리키게 된다(실측).
    /// 그래서 소개하는 말은 소개할 항목이 실제로 켜졌을 때만 따라 붙게 떼어 둔다. 옛 기록에는 없다.
    public var concernsNoteKo: String?
    public var questionsNoteKo: String?

    enum CodingKeys: String, CodingKey {
        case verdict
        case summaryKo = "summary_ko"
        case concerns, strengths
        case draftComments = "draft_comments"
        case questionsForAuthor = "questions_for_author"
        case concernsNoteKo = "concerns_note_ko"
        case questionsNoteKo = "questions_note_ko"
        case codeComments = "code_comments"
    }

    /// 두 형식을 다 읽는다.
    ///
    /// 새 형식(2026-10-20~): 작성자에게 남길 말은 모두 `code_comments` 한 목록이고, 하나하나가 바뀐 코드 줄에 달린다.
    /// 중요도는 필수·권장·참고 세 가지뿐이다(사용자 결정). 앱 안에서는 지금까지처럼 인라인 초안(`draftComments`)으로
    /// 바꿔 담는다 — 화면·게시·검증이 모두 초안을 보고 있어서, 그 길을 그대로 탄다.
    /// 옛 형식(우려사항·질문·초안 셋)은 저장된 리뷰를 열 때 그대로 읽는다. 저장은 늘 옛 키로 한다(`encode`).
    public init(from decoder: Decoder) throws {
        let c = try decoder.container(keyedBy: CodingKeys.self)
        verdict = try c.decode(Verdict.self, forKey: .verdict)
        summaryKo = try c.decode(String.self, forKey: .summaryKo)
        strengths = try c.decodeIfPresent([String].self, forKey: .strengths) ?? []
        concerns = try c.decodeIfPresent([Concern].self, forKey: .concerns) ?? []
        let code = try c.decodeIfPresent([CodeComment].self, forKey: .codeComments) ?? []
        draftComments = code.map(\.draftComment)
            + (try c.decodeIfPresent([DraftComment].self, forKey: .draftComments) ?? [])
        questionsForAuthor = try c.decodeIfPresent([AuthorQuestion].self, forKey: .questionsForAuthor)
        concernsNoteKo = try c.decodeIfPresent(String.self, forKey: .concernsNoteKo)
        questionsNoteKo = try c.decodeIfPresent(String.self, forKey: .questionsNoteKo)
    }

    public func encode(to encoder: Encoder) throws {
        var c = encoder.container(keyedBy: CodingKeys.self)
        try c.encode(verdict, forKey: .verdict)
        try c.encode(summaryKo, forKey: .summaryKo)
        try c.encode(concerns, forKey: .concerns)
        try c.encode(strengths, forKey: .strengths)
        try c.encode(draftComments, forKey: .draftComments)
        try c.encodeIfPresent(questionsForAuthor, forKey: .questionsForAuthor)
        try c.encodeIfPresent(concernsNoteKo, forKey: .concernsNoteKo)
        try c.encodeIfPresent(questionsNoteKo, forKey: .questionsNoteKo)
    }

    public init(verdict: Verdict, summaryKo: String, concerns: [Concern], strengths: [String],
                draftComments: [DraftComment], questionsForAuthor: [AuthorQuestion]? = nil,
                concernsNoteKo: String? = nil, questionsNoteKo: String? = nil) {
        self.verdict = verdict
        self.summaryKo = summaryKo
        self.concerns = concerns
        self.strengths = strengths
        self.draftComments = draftComments
        self.questionsForAuthor = questionsForAuthor
        self.concernsNoteKo = concernsNoteKo
        self.questionsNoteKo = questionsNoteKo
    }

    /// "완전허용" — 코멘트 없이 approve 해도 전혀 상관없는 상태.
    /// 이 리뷰가 아무 지적도 남기지 않았는가.
    ///
    /// 이미 언급된 사안(`duplicates_existing`)도 그대로 센다. 먼저 말한 사람이 누구든
    /// 아직 열려 있는 지적이면 "완전허용" 은 아니기 때문이다. 대신 프롬프트에서
    /// 이미 지적된 minor·nit 은 concerns 에 넣지 못하게 막아, 사소한 중복 때문에
    /// 완전허용이 깨지는 일은 생기지 않는다.
    public var isFullyOK: Bool {
        verdict == .approve && draftComments.isEmpty && concerns.isEmpty
    }

    /// 본문에 그대로 붙는 글 필드에서 짝 없이 새어 들어온 따옴표를 걷어 낸다.
    ///
    /// 프롬프트가 예시를 따옴표 안에 적어 두어, 모델이 닫는 따옴표까지 따라 쓴 적이 있다
    /// (실측: 요약이 `…했습니다."` 로 끝났다). 그대로 두면 게시 본문 끝에 `"` 하나가
    /// 덩그러니 나간다. 짝이 맞는 따옴표(`"알 수 없는 오류" 알럿`)는 인용이라 건드리지 않는다.
    public func tidied() -> ReviewOutput {
        let prose = { (text: String) in Self.strippingStrayQuotes(Self.cuttingLeakedMarkup(text)) }
        var copy = self
        copy.summaryKo = prose(summaryKo)
        copy.strengths = strengths.map(prose)
        copy.concernsNoteKo = concernsNoteKo.map(prose)
        copy.questionsNoteKo = questionsNoteKo.map(prose)
        // 본문으로 올라가는 나머지 글에도 같은 조각이 섞일 수 있다.
        copy.draftComments = draftComments.map { comment in
            var comment = comment
            comment.body = Self.cuttingLeakedMarkup(comment.body)
            return comment
        }
        copy.concerns = concerns.map { concern in
            var concern = concern
            concern.title = Self.cuttingLeakedMarkup(concern.title)
            return concern
        }
        copy.questionsForAuthor = questionsForAuthor?.map { question in
            var question = question
            question.question = Self.cuttingLeakedMarkup(question.question)
            return question
        }
        return copy
    }

    /// 출력 형식의 조각(필드 이름이 든 태그)이 값 안에 흘러 들어왔으면 그 자리부터 잘라 낸다.
    ///
    /// 실측(14회차): 요약이 `…보완해 승인합니다.</summary_ko... let me fix>` 로 끝났다.
    /// 모델이 값을 쓰다 말고 스스로 고치려던 흔적이다. 그대로 두면 이 글자가 GitHub 에 올라간다.
    /// 필드 이름이 든 태그는 리뷰 글에 정당하게 나올 일이 없어서, 코드의 `Array<Int>` 같은
    /// 꺾쇠는 건드리지 않고 이것만 본다.
    static func cuttingLeakedMarkup(_ text: String) -> String {
        let fields = "summary_ko|strengths|concerns_note_ko|questions_note_ko|verdict|code_comments|draft_comments|concerns|questions_for_author|parameter|invoke"
        guard let regex = try? NSRegularExpression(pattern: "</?\\s*(\(fields))\\b", options: [.caseInsensitive]),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text) else { return text }
        return String(text[..<range.lowerBound]).trimmingCharacters(in: .whitespacesAndNewlines)
    }

    static func strippingStrayQuotes(_ text: String) -> String {
        let quotes: Set<Character> = ["\"", "“", "”"]
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let first = trimmed.first, let last = trimmed.last else { return text }
        let inner = trimmed.dropFirst().dropLast()
        // 통째로 둘렀으면 벗긴다. 안에 다른 따옴표가 있으면 인용이 섞인 것이라 두지 않는다.
        if trimmed.count >= 2, quotes.contains(first), quotes.contains(last),
           !inner.contains(where: quotes.contains) {
            return String(inner).trimmingCharacters(in: .whitespaces)
        }
        // 짝이 안 맞을 때만 양 끝의 하나를 뗀다. 짝이 맞으면 어딘가를 인용한 것이다.
        guard trimmed.filter(quotes.contains).count % 2 == 1 else { return text }
        if quotes.contains(last) { return String(trimmed.dropLast()).trimmingCharacters(in: .whitespaces) }
        if quotes.contains(first) { return String(trimmed.dropFirst()).trimmingCharacters(in: .whitespaces) }
        return text
    }
}

/// 새 출력 형식의 코드 코멘트 한 개(`code_comments` 의 항목). 앱 안에서는 인라인 초안으로 바꿔 쓴다.
struct CodeComment: Decodable {
    /// 중요도 — 필수·권장·참고. 심각도 네 단계로 옮겨 담는다: 필수 → blocker, 권장 → minor, 참고 → nit.
    /// 권장을 major 가 아니라 minor 로 두는 까닭: 권장은 머지를 막지 않는다. major 는 앱·검사기가 "가볍지 않은 지적"
    /// 으로 세어 요약 맺음말을 막는데, 새 형식에서 그 몫은 필수만 한다. 화면에서는 minor 도 '권장' 으로 보인다.
    enum Importance: String, Decodable, CaseIterable {
        case required, recommended, informational

        var severity: Severity {
            switch self {
            case .required: return .blocker
            case .recommended: return .minor
            case .informational: return .nit
            }
        }
    }

    var issueKey: String
    var importance: Importance
    var path: String
    var line: Int
    var startLine: Int?
    var side: DiffSide
    var body: String
    var anchorText: String
    var duplicatesExisting: Bool?
    var existingNote: String?
    var rationaleKo: String?
    var evidence: [CodeEvidence]?

    enum CodingKeys: String, CodingKey {
        case issueKey = "issue_key"
        case importance, path, line
        case startLine = "start_line"
        case side, body
        case anchorText = "anchor_text"
        case duplicatesExisting = "duplicates_existing"
        case existingNote = "existing_note"
        case rationaleKo = "rationale_ko"
        case evidence
    }

    var draftComment: DraftComment {
        DraftComment(issueKey: issueKey, path: path, line: line, startLine: startLine, side: side,
                     body: body, severity: importance.severity, anchorText: anchorText,
                     duplicatesExisting: duplicatesExisting, existingNote: existingNote,
                     rationaleKo: rationaleKo, evidence: evidence)
    }
}
