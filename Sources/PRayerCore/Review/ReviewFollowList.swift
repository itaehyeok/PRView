import Foundation

/// AI 리뷰의 우려사항·질문 가운데 코드 자리가 있는 것. 변경 파일 탭에서 그 줄 아래에 펼쳐 놓고 하나씩 따라간다.
///
/// 우려사항은 자리가 하나(path·line), 질문은 근거마다 자리가 있다. 줄을 모르는 것은 넣지 않는다 —
/// "그 줄 아래에 펼쳐 보기" 라서 줄이 없으면 펼칠 곳이 없다(그런 근거는 예전처럼 파일만 연다).
public struct FollowableItem: Sendable, Hashable, Identifiable {
    public enum Kind: Sendable, Hashable {
        case concern, question

        public var label: String {
            switch self {
            case .concern: return "우려사항"
            case .question: return "질문"
            }
        }
    }

    public struct Location: Sendable, Hashable {
        public var path: String
        public var line: Int
        public var side: DiffSide
        /// 질문 근거의 한 줄 설명. 우려사항에는 없다.
        public var note: String?

        public init(path: String, line: Int, side: DiffSide, note: String? = nil) {
            self.path = path
            self.line = line
            self.side = side
            self.note = note
        }

        /// diff 화면이 줄을 찾는 키(`DiffKeys.key` 와 같은 꼴).
        public var diffKey: String { "\(path)#\(side.rawValue)#\(line)" }
        public var fileName: String { (path as NSString).lastPathComponent }
    }

    /// `ReviewItemKey` — 정리 표시·인라인으로 옮기기가 같은 키를 쓴다.
    public var key: String
    public var kind: Kind
    /// 우려사항은 제목, 질문은 질문 글.
    public var title: String
    /// 질문에는 심각도가 없다.
    public var severity: Severity?
    /// 질문의 "왜 물어보나". 우려사항에는 없다.
    public var rationale: String?
    public var isDuplicate: Bool
    public var existingNote: String?
    public var locations: [Location]

    public var id: String { key }
}

public enum ReviewFollowList {
    /// 따라갈 수 있는 항목들. 본문에 실리는 순서(우려사항 → 질문)를 따른다 —
    /// 리뷰 탭에서 위에서부터 읽던 순서와 diff 에서 ‹ › 로 넘기는 순서가 같아야 헷갈리지 않는다.
    public static func items(in output: ReviewOutput) -> [FollowableItem] {
        var result: [FollowableItem] = []
        for concern in output.concerns {
            guard let line = concern.line, !concern.path.isEmpty else { continue }
            result.append(FollowableItem(key: ReviewItemKey.concern(concern),
                                         kind: .concern,
                                         title: concern.title,
                                         severity: concern.severity,
                                         rationale: nil,
                                         isDuplicate: concern.isDuplicate,
                                         existingNote: concern.existingNote,
                                         // 모델이 side 를 빼먹으면 새 코드 쪽으로 본다 — 우려사항은 거의 늘 바뀐 코드를 가리킨다.
                                         locations: [.init(path: concern.path, line: line, side: concern.side ?? .right)]))
        }
        for question in output.questionsForAuthor ?? [] {
            // 근거에는 side 가 없다. 지금도 근거 링크는 새 코드 쪽(RIGHT)으로 연다.
            let locations = (question.evidence ?? []).compactMap { evidence -> FollowableItem.Location? in
                guard let line = evidence.line, !evidence.path.isEmpty else { return nil }
                return .init(path: evidence.path, line: line, side: .right, note: evidence.note)
            }
            guard !locations.isEmpty else { continue }
            result.append(FollowableItem(key: ReviewItemKey.question(question),
                                         kind: .question,
                                         title: question.question,
                                         severity: nil,
                                         rationale: question.rationaleKo,
                                         isDuplicate: question.isDuplicate,
                                         existingNote: question.existingNote,
                                         locations: locations))
        }
        return result
    }
}
