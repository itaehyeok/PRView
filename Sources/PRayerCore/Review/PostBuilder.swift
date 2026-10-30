import Foundation
import CryptoKit

public enum ReviewEvent: String, Sendable, CaseIterable, Identifiable {
    case comment = "COMMENT"
    case approve = "APPROVE"
    case requestChanges = "REQUEST_CHANGES"

    public var id: String { rawValue }

    public var label: String {
        switch self {
        case .comment: return "코멘트만"
        case .approve: return "Approve"
        case .requestChanges: return "변경 요청"
        }
    }

    public var explanation: String {
        switch self {
        case .comment: return "의견만 남깁니다. Approve 수에 영향이 없습니다."
        case .approve: return "Approve 1표로 집계됩니다."
        case .requestChanges: return "머지를 막습니다."
        }
    }

    public var needsExtraConfirmation: Bool { self == .requestChanges }
}

public enum PostBuilder {
    /// 게시하는 글 끝에 붙이는 숨은 마커(HTML 주석이라 GitHub 화면에는 안 보인다).
    /// 마커의 해시로 "이 초안을 이미 게시했는지" 판정할 수 있다.
    public static func marker(for body: String) -> String {
        let digest = SHA256.hash(data: Data(body.utf8))
        let hex = digest.map { String(format: "%02x", $0) }.joined()
        return "<!-- \(AppInfo.markerPrefix):\(AppInfo.markerVersion):\(hex.prefix(12)) -->"
    }

    /// 게시 본문 끝에 숨은 마커를 붙인다.
    ///
    /// **마커는 늘 붙인다.** 마커는 "이건 우리가 올린 글" 이라는 표식이라, 없으면 우리가 방금 올린 리뷰가 다음 번
    /// "다시 확인" 에서 남이 쓴 새 코멘트로 되돌아온다(자기가 한 말을 근거로 판단하게 된다). 눈에 보이는 표기
    /// (👥 / by Claude)는 없앴다 — 늘 붙이지 않는다(2026-10-20 사용자 결정).
    public static func decorate(_ body: String) -> String {
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed + "\n\n" + marker(for: trimmed)
    }

    /// 총평 기본값. 리뷰 봇이 이미 PR 마다 긴 총평을 올리는 레포가 많아 2~3문장으로 짧게 만든다.
    public static func defaultBody(output: ReviewOutput, includeStrengths: Bool) -> String {
        defaultBody(output: output, summary: output.summaryKo, strengths: output.strengths,
                    includeStrengths: includeStrengths)
    }

    /// 사용자가 본문에서 고친 글을 반영한 짧은 본문("요약과 함께 Approve" 가 쓴다).
    public static func defaultBody(record: ReviewRecord) -> String {
        defaultBody(output: record.output, summary: record.effectiveSummary,
                    strengths: record.effectiveStrengths, includeStrengths: true)
    }

    private static func defaultBody(output: ReviewOutput, summary rawSummary: String, strengths: [String],
                                    includeStrengths: Bool) -> String {
        let summary = rawSummary.trimmingCharacters(in: .whitespacesAndNewlines)
        var parts: [String] = []
        // 팀 승인 본문 중앙값이 288자다. 요약이 이미 충분하면 칭찬·마무리 문장을 덧붙이지 않는다.
        if includeStrengths, summary.count < 150, let first = strengths.first {
            parts.append(first.trimmingCharacters(in: .whitespacesAndNewlines))
        }
        if !summary.isEmpty { parts.append(summary) }
        if output.draftComments.isEmpty, output.concerns.isEmpty, summary.count < 60 {
            // "이슈 없습니다" 처럼 **없는 것**으로 끝내지 않는다. 읽는 사람은 자기 PR 을
            // 올려 둔 사람이라, 같은 승인인데도 "문제를 못 찾았다" 로 끝나면
            // "뭔가 걸리는데 넘어가 준다" 로 읽힌다.
            // "승인합니다" 라고는 하지 않는다 — 실제로 무엇으로 게시할지는 사용자가 고른다.
            parts.append("확인했고 문제없습니다.")
        }
        return parts.joined(separator: " ")
    }

    /// 요약 문단. 소개할 항목이 실제로 켜졌을 때만 그 안내 문장이 뒤에 붙는다.
    ///
    /// 요약이 꺼져 있으면 안내도 붙이지 않는다 — 안내는 요약 문장의 일부라서, 혼자 남으면
    /// "아래에 한 번 더 적었습니다" 가 본문 첫 줄로 튀어나온다.
    public static func summaryBlock(record: ReviewRecord, summary: String) -> String {
        var lines = [summary]
        // 인라인으로 다 옮겨 본문에 남은 우려사항·질문이 없으면 소개할 것도 없다.
        if record.bodyIncludesConcerns, !record.bodyConcerns.isEmpty,
           let note = record.output.concernsNoteKo?.trimmingCharacters(in: .whitespacesAndNewlines),
           !note.isEmpty {
            lines.append(note)
        }
        if record.bodyIncludesQuestions, !record.bodyQuestions.isEmpty,
           let note = record.output.questionsNoteKo?.trimmingCharacters(in: .whitespacesAndNewlines),
           !note.isEmpty {
            lines.append(note)
        }
        return lines.joined(separator: "\n")
    }

    /// "확인했고 문제없던 것" 절의 제목. 팀에서 이미 쓰고 있는 문구를 그대로 따른다.
    public static let clearedHeading = "확인했고 문제없던 것"

    /// 정리한 항목 하나를 본문 한 줄로 만들 때의 기본값. 사용자가 고쳐 쓰는 것이 전제다.
    public static func defaultClearedNote(topic: String) -> String {
        let trimmed = topic.trimmingCharacters(in: .whitespacesAndNewlines)
        let subject = trimmed.isEmpty ? "이 항목" : trimmed
        return "**\(subject)** — 확인했습니다. 문제 아닙니다"
    }

    /// 본문의 불릿 목록 한 덩어리. 리뷰 본문 상자(미리보기)도 이 함수로 그린다 — 예전 미리보기는
    /// 이 모양을 베껴 써서, 한쪽만 고치면 미리보기와 실제 게시가 어긋날 수 있었다.
    public static func bulletList(_ items: [String]) -> String {
        items.map { "- \($0)" }.joined(separator: "\n")
    }

    /// 체크박스 상태대로 조립한 최종 게시 본문. 미리보기와 실제 게시가 어긋나지 않도록
    /// 두 화면 모두 이 함수만 쓴다.
    public static func composedBody(record: ReviewRecord) -> String {
        let output = record.output
        var parts: [String] = []
        // 요약·잘된 점·우려사항 제목·질문은 사용자가 고친 글이 있으면 그것을 쓴다(`ReviewTextEdits`).
        if record.bodyIncludesSummary {
            let summary = record.effectiveSummary
            if !summary.isEmpty { parts.append(summaryBlock(record: record, summary: summary)) }
        }
        let strengths = record.effectiveStrengths
        if record.bodyIncludesStrengths, !strengths.isEmpty {
            parts.append(bulletList(strengths))
        }
        // 인라인 코멘트로 옮긴 항목은 뺀다 — 같은 지적이 본문과 코드 옆에 두 번 올라간다.
        let concerns = record.bodyConcerns
        if record.bodyIncludesConcerns, !concerns.isEmpty {
            // 이미 오간 얘기는 빼지 않고 그렇다고 **표시**한다. 빼 버리면 리뷰어가 올리려던 것이
            // 조용히 사라지고, 표시 없이 올리면 작성자는 같은 지적을 처음 보는 것으로 읽는다.
            parts.append(concerns
                .map { "- [\($0.severity.label)] \(record.text(for: $0))\($0.isDuplicate ? " (이미 언급된 사안)" : "")" }
                .joined(separator: "\n"))
        }
        let questions = record.bodyQuestions
        if record.bodyIncludesQuestions, !questions.isEmpty {
            parts.append(questions
                .map { "- \(record.text(for: $0))\($0.isDuplicate ? " (이미 언급된 사안)" : "")" }
                .joined(separator: "\n"))
        }
        // 읽어 보고 넘긴 것들. 이 절만 제목을 다는데, 위의 목록들과 뜻이 정반대라
        // 제목 없이 불릿만 이어 붙이면 작성자가 지적으로 읽는다.
        if record.bodyIncludesCleared {
            let cleared = record.orderedClearedNotes
            if !cleared.isEmpty {
                parts.append(("### " + clearedHeading + "\n") + bulletList(cleared))
            }
        }
        return parts.joined(separator: "\n\n")
    }

    // 처음 골라 둘 리뷰 종류는 설정값(`suggestedEvent`)이 아니라 게시 버튼과 같은 판단(`PostActionPlan.current`)을 쓴다.
    // 예전에는 "전송 내용 자세히" 창만 설정값을 읽어, 버튼은 "코멘트+Approve" 인데 창은 "코멘트만" 으로 열렸다.

    /// 고를 수 있는 리뷰 종류.
    /// 내가 만든 PR 은 GitHub 이 승인도 변경 요청도 거부해 코멘트만 남는다. 이미 같은 커밋을 승인했으면 또 승인할 이유가 없다.
    public static func availableEvents(viewerDidAuthor: Bool, alreadyApprovedHead: Bool = false) -> [ReviewEvent] {
        if viewerDidAuthor { return [.comment] }
        if alreadyApprovedHead { return ReviewEvent.allCases.filter { $0 != .approve } }
        return ReviewEvent.allCases
    }

    /// 게시 payload. 검증을 통과하고 사용자가 포함하기로 한 코멘트만 담는다.
    /// GitHub 은 event 가 COMMENT/REQUEST_CHANGES 일 때 body 를 필수로 요구한다(APPROVE 만 생략 가능).
    public static func requiresBody(_ event: ReviewEvent) -> Bool { event != .approve }

    /// 이번 게시에 실릴 인라인 코멘트 수. payload 와 같은 거름을 쓴다 —
    /// 확인 창이 말하는 건수와 실제로 나가는 건수가 다르면 확인의 의미가 없다.
    public static func inlineCount(record: ReviewRecord, includeComments: Bool) -> Int {
        includeComments ? record.comments.filter(\.isPostable).count : 0
    }

    /// `commitID` 를 주지 않으면 리뷰한 커밋에 남긴다. 새 커밋이 올라온 뒤 "그대로 올림" 을 고르면
    /// 다른 커밋을 줄 수 있다(`HeadDrift.postingCommit`).
    /// `basket` — 코드 코멘트 카드에서 "리뷰에 담기" 한 줄 코멘트(`ReviewRecord.basketComments`). 초안 체크와 따로 붙는다.
    public static func payload(record: ReviewRecord,
                               event: ReviewEvent,
                               body: String,
                               includeComments: Bool = true,
                               basket: [ReviewPayload.Comment] = [],
                               commitID: String? = nil) -> ReviewPayload {
        let comments = (includeComments ? record.comments : [])
            .filter(\.isPostable)
            .map { state in
                ReviewPayload.Comment(path: state.comment.path,
                                      line: state.comment.line,
                                      side: state.comment.side.rawValue,
                                      start_line: state.comment.startLine,
                                      start_side: state.comment.startLine == nil ? nil : state.comment.side.rawValue,

                                      body: decorate(state.editedBody))
            } + basket
        let trimmed = body.trimmingCharacters(in: .whitespacesAndNewlines)
        let effectiveBody: String
        if !trimmed.isEmpty {
            effectiveBody = trimmed
        } else if requiresBody(event) {
            // 빈 본문으로 COMMENT/REQUEST_CHANGES 를 보내면 422 로 거부된다.
            effectiveBody = comments.isEmpty ? "확인했습니다." : "인라인 코멘트를 남겼습니다."
        } else {
            effectiveBody = ""
        }
        let decoratedBody = effectiveBody.isEmpty ? "" : decorate(effectiveBody)
        return ReviewPayload(commitID: commitID ?? record.headSha,
                             event: event.rawValue,
                             body: decoratedBody,
                             comments: comments)
    }
}
