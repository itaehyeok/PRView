import Foundation
@testable import PRayerCore

/// 리뷰 결과가 **사용자가 원한 문체**를 지켰는지 본다. 프롬프트를 고친 뒤 실제 모델 출력을
/// 사람 눈 대신 같은 잣대로 재려고 둔다.
///
/// 규칙 출처는 전부 사용자가 직접 짚은 것이다.
/// - 요약: 부정형("머지를 막을 이슈는 없습니다")으로 끝내지 않는다. 괜찮으면 괜찮다고 한다.
/// - 요약: 질문·우려·부탁을 가리키지 않는다(요약만 켜고 승인으로 올리는 일이 가장 많다).
/// - 요약: "승인합니다" 는 verdict 가 approve 일 때만. LGTM 이면 승인하는 말로 끝낸다.
/// - 잘된 점: 명사형으로 끝내지 않고, 평가하는 말이 들어가야 한다.
/// - 안내 문장: 우려·질문이 있을 때만, 그 항목을 소개하는 말로.
///
/// 판정은 **보수적으로** 한다. 헛잡으면 멀쩡한 프롬프트를 고치러 가게 된다 — 애매하면
/// `soft` 로 두고 사람이 읽는다.
struct ReviewStyleCheck {
    struct Issue: CustomStringConvertible {
        enum Level: String { case hard = "✗", soft = "△" }
        let level: Level
        let rule: String
        let detail: String
        var description: String { "\(level.rawValue) [\(rule)] \(detail)" }
    }

    /// 판정을 "없는 것" 으로 세우는 꼴. 정규식으로 **판정 어미까지** 잡는다 —
    /// "메모리 이슈는 없어졌습니다" 처럼 고친 것을 설명하는 문장까지 잡으면 안 된다.
    static let negativeClosings = [
        // "없어 " 는 뒤에 띄어쓰기가 올 때만 — "없어졌습니다" 는 고친 것을 설명하는 말이다.
        "머지를 막을", "이슈는 없(습니다|어 |어서|고|으며|음|으니)", "이슈가 없(습니다|어 |어서|고|으며)",
        "이슈 없습니다", "특이사항(은|이)? 없", "문제될 부분", "막을 이유",
    ]
    /// 판정일 수도, 변경 설명일 수도 있는 말("화면에 보이지 않던 버튼을…").
    /// 같은 문장에 이슈·문제 같은 말이 있을 때만 판정으로 본다.
    static let negativeIfAboutIssues = ["보이지 않", "찾지 못", "없어 보입니다", "없어 보이고"]
    static let issueWords = ["이슈", "문제", "결함", "사안", "우려", "지장", "blocker", "major", "블로커"]
    /// 요약이 "아직 안 끝났다" 로 읽히게 만드는 말. 블로커가 없을 때만 문제다.
    static let openingPhrases = [
        "확인 부탁", "부탁드려요", "부탁드립니다", "공유해 주", "주시겠어요", "주세요",
        "질문으로", "아래 코멘트", "코멘트로 남", "한 번 더 짚", "확인이 필요한 부분",
        "확인할 수 없", "확인 불가", "후속 작업", "후속으로",
    ]
    /// comment 이고 minor·nit 만 남았을 때 닫는 말. 사용자가 고른 두 꼴만 쓴다 — "그대로 가도 좋겠습니다"
    /// 한 문장으로 굳어 comment 4건이 모두 같은 말로 끝났다(실측). "머지를 막을 …" 은 이때만 부정형이 아니다.
    static let commentClosings = ["머지를 막을 만한 부분은 없습니다", "이대로 머지해도 문제없겠습니다"]
    /// LGTM 을 **승인하는 말**로 끝냈는지. "승인해요" 는 사용자 리뷰 규칙이 해요체를 정했을 때의 같은 말이다.
    static let approvalPhrases = [
        "승인합니다", "승인해요", "반영하면 되겠", "반영해도 좋", "가도 좋겠", "가도 되겠", "가면 되겠",
        "머지해도 좋", "머지해도 되", "머지해도 문제없", "머지를 막을 만한 부분은 없",
    ]
    /// 진행을 권하는 말. major 이상이 남았으면 쓰면 안 된다.
    static let goAheadPhrases = [
        "승인합니다", "그대로 가도", "그대로 가면", "진행해도 좋", "진행해도 되",
        "반영하면 되", "반영해도 좋", "머지해도", "머지를 막을 만한",
    ]
    /// 중립이 아니라 긍정으로 끝내라 했다. 미지근한 말.
    static let lukewarmWords = ["무난", "나쁘지 않", "큰 문제 없", "크게 걸리는"]
    /// 프롬프트의 ○ 예시 문장. 요약이 이걸 **글자 그대로** 가져오면 어느 PR 에나 붙는
    /// 틀에 박힌 글이 된다(실측: "기존 패턴을 그대로 따라가 안전하게 처리해 승인합니다.").
    static let promptExamples: [String] = {
        let root = URL(fileURLWithPath: #filePath)
            .deletingLastPathComponent().deletingLastPathComponent().deletingLastPathComponent()
        guard let text = try? String(contentsOf: root.appendingPathComponent("Resources/review.md"),
                                     encoding: .utf8) else { return [] }
        return text.split(whereSeparator: \.isNewline).flatMap { line -> [String] in
            let trimmed = line.trimmingCharacters(in: .whitespaces)
            // `○ "…"` 뿐 아니라 `○ 요약: "…"` · `○ summary_ko: "…"` 도 예시다.
            guard trimmed.hasPrefix("○"), let open = trimmed.firstIndex(of: "\""),
                  let close = trimmed.lastIndex(of: "\""), open < close else { return [] }
            // 두 문장짜리 예시가 있다. 요약의 판정 문장과 견주므로 문장마다 따로 둔다.
            return trimmed[trimmed.index(after: open)..<close]
                .components(separatedBy: CharacterSet(charactersIn: ".?!"))
                .map(normalized)
        }.filter { $0.count >= 12 }
    }()

    static func normalized(_ text: String) -> String {
        text.filter { !$0.isWhitespace && !".…,·\"".contains($0) }
    }

    /// 평가하는 말. 프롬프트가 권하는 끝맺음과 **같은 목록**이어야 한다 — 계약 테스트도 이걸 쓴다.
    static let praiseWords = [
        "잘 ", "잘했", "잘해", "잘된", "잘되", "깔끔", "꼼꼼", "빠짐없", "빈틈없", "세심", "좋", "훌륭", "탄탄",
        "돋보", "반갑", "빠릅", "빠른 대응", "명쾌", "인상적", "든든",
    ]

    /// 판정 문장에서 평가로 치는 말. 잘된 점보다 넓다 — "원인을 정확히 짚어 승인합니다" 는
    /// 판정 문장에서는 잘했다는 말로 읽힌다(잘된 점에서는 "어떻게 했는지" 라 따로 평가가 필요하다).
    static let closingPraiseWords = praiseWords + ["정확", "명확", "안전", "매끄", "촘촘", "성실", "정교", "알맞", "제대로"]

    static func check(_ output: ReviewOutput) -> [Issue] {
        var issues: [Issue] = []
        let summary = output.summaryKo.trimmingCharacters(in: .whitespacesAndNewlines)
        let hasBlocker = output.verdict == .requestChanges
            || output.concerns.contains { $0.severity == .blocker }
            || output.draftComments.contains { $0.severity == .blocker }
        let heavy = output.concerns.contains { $0.severity == .blocker || $0.severity == .major }
            || output.draftComments.contains { $0.severity == .blocker || $0.severity == .major }
        /// comment 에 minor·nit 만 남은 경우. 이때만 "머지를 막을 만한 부분은 없습니다" 로 닫을 수 있다.
        let lightComment = output.verdict == .comment && !heavy && !hasBlocker

        // ── 요약
        let parts = sentences(of: summary)
        let negativeTarget = lightComment
            ? summary.replacingOccurrences(of: "머지를 막을 만한 부분은 없", with: "")
            : summary
        for hit in negativeHits(in: negativeTarget) {
            issues.append(Issue(level: .hard, rule: "요약-부정형", detail: "“\(hit)” — \(tail(summary))"))
        }
        if !hasBlocker {
            for phrase in openingPhrases where summary.contains(phrase) {
                issues.append(Issue(level: .hard, rule: "요약-열어둠", detail: "“\(phrase)” — \(tail(summary))"))
            }
        }
        // comment 인데 우려가 따로 있으면, 확인이 필요하다는 말은 우려 안내가 한다(켰을 때만 붙는다).
        // 요약이 그 말을 하면 우려를 끄고 올려도 우려 내용이 남는다(실측 5회차).
        // 우려 없이 인라인 코멘트로만 major 가 있으면 안내가 붙을 자리가 없어 요약이 말해도 된다.
        // 말만 피하고 내용을 그대로 적는 경우도 있다 — "다만 …사전 검사는 그대로 남아 있습니다"
        // (실측 6회차). 그래서 글자가 아니라 **내용**으로 본다: 판정 문장이 열린 신호를
        // 품었거나, 우려 제목과 같은 식별자를 쓰면 우려를 가리킨 것이다.
        // 새 형식(code_comments)에는 우려가 없다 — 줄에 달린 코멘트도 같은 이유로 요약이 가리키면 안 된다.
        // 코멘트 본문은 식별자가 많아 겹침으로 보면 헛잡으니, 열린 신호로만 본다.
        if !hasBlocker, output.concerns.isEmpty, !output.draftComments.isEmpty, let verdictSentence = parts.last,
           let signal = ["확인이 필요", "다만 ", "남아 있어", "남아 있습니다", "남아 있는", "그대로 남"].first(where: verdictSentence.contains) {
            issues.append(Issue(level: .hard, rule: "요약-코멘트가리킴",
                                detail: "필수가 없는데 판정 문장이 코멘트 내용을 말한다(“\(signal)”) — 달지 않고 올려도 남는다 — \(tail(summary))"))
        }
        if !hasBlocker, !output.concerns.isEmpty, let verdictSentence = parts.last {
            // "남아 있던" 은 고친 버그의 원인을 적는 과거형이라 열린 신호가 아니다(15회차 헛잡이:
            // "…캐시에 남아 있던 이전 상태 때문에 … 원래 버그를 … 잡아 두셨습니다").
            let openSignals = ["확인이 필요", "다만 ", "남아 있어", "남아 있습니다", "남아 있는", "그대로 남"]
            let concernTokens = Set(output.concerns.flatMap { identifierTokens(in: $0.title) })
            let shared = identifierTokens(in: verdictSentence).filter(concernTokens.contains)
            if let signal = openSignals.first(where: verdictSentence.contains) {
                issues.append(Issue(level: .hard, rule: "요약-우려가리킴",
                                    detail: "comment 인데 판정 문장이 우려를 말한다(“\(signal)”) — 끄고 올려도 남는다 — \(tail(summary))"))
            } else if let token = shared.first {
                issues.append(Issue(level: .hard, rule: "요약-우려가리킴",
                                    detail: "판정 문장이 우려 제목의 “\(token)” 를 쓴다 — 끄고 올려도 남는다 — \(tail(summary))"))
            }
        }
        if output.verdict != .approve, summary.contains("승인합니다") {
            issues.append(Issue(level: .hard, rule: "요약-판정불일치",
                                detail: "verdict=\(output.verdict.rawValue) 인데 “승인합니다”"))
        }
        if output.verdict == .approve, !approvalPhrases.contains(where: summary.contains) {
            issues.append(Issue(level: .soft, rule: "요약-LGTM문구",
                                detail: "approve 인데 승인하는 말이 없다 — \(tail(summary))"))
        }
        // 막는 판정인데 요약이 칭찬만 하면, 받는 사람은 무엇을 고쳐야 하는지 모른다(실측).
        // 이때만은 요약을 닫지 않고 무엇을 확인해야 하는지 말해야 한다.
        if hasBlocker, !["확인이 필요", "고쳐 주", "수정이 필요", "바꿔 주"].contains(where: summary.contains) {
            issues.append(Issue(level: .hard, rule: "요약-블로커",
                                detail: "막는 판정인데 무엇을 확인해야 하는지 말하지 않는다 — \(tail(summary))"))
        }
        if parts.count > 3 {
            issues.append(Issue(level: .soft, rule: "요약-길이", detail: "\(parts.count)문장(목표 2문장)"))
        }
        // "…처리했습니다. 승인합니다." — 승인이 혼자 떨어져 3문장이 되고, 성의 없이 붙인 말로
        // 읽힌다. 프롬프트는 평가와 승인을 한 문장에 담게 한다("…해서 승인합니다").
        // 판정이 혼자 떨어진 짧은 문장("승인합니다." "그대로 가도 좋겠습니다.")이면 잡는다.
        if parts.count >= 2, let last = parts.last, last.count <= 16,
           goAheadPhrases.contains(where: last.contains) {
            issues.append(Issue(level: .hard, rule: "요약-판정분리", detail: "“\(last).” 가 따로 떨어져 있다 — \(tail(summary))"))
        }
        if let last = parts.last {
            let key = normalized(last)
            // 요약 문장이 예시 **전체**를 담고 있을 때만 복사로 본다. 반대 방향(예시의 끝부분과
            // 같음)으로 보면 "그대로 반영하면 되겠습니다" 같은 흔한 마무리까지 헛잡는다.
            if let copied = promptExamples.first(where: { key == $0 || key.hasSuffix($0) }) {
                issues.append(Issue(level: .hard, rule: "요약-예시복사",
                                    detail: "프롬프트 예시를 그대로 가져왔다 — “\(last).” (\(copied.count)자)"))
            }
        }
        for word in lukewarmWords where summary.contains(word) {
            issues.append(Issue(level: .hard, rule: "요약-미지근", detail: "“\(word)” — \(tail(summary))"))
        }
        // 가벼운 지적만 남은 comment 는 고른 두 꼴 중 하나로 닫는다. 다른 말이면 사람이 읽어 본다(soft).
        if lightComment, let last = parts.last, !commentClosings.contains(where: { last.contains($0.dropLast(3)) }) {
            issues.append(Issue(level: .soft, rule: "요약-맺음말",
                                detail: "comment(minor·nit) 인데 두 맺음말 밖이다 — \(tail(last))"))
        }
        if heavy, let phrase = goAheadPhrases.first(where: summary.contains) {
            issues.append(Issue(level: .hard, rule: "요약-major진행권유",
                                detail: "major 이상이 남았는데 “\(phrase)” — \(tail(summary))"))
        }
        // 승인하는 판정 문장에 평가가 없으면 "한 일 + 승인합니다" 라 중립으로 읽힌다(8~11회차 승인
        // 23건 중 14건: "…끊어 두어 승인합니다", "…정리해 승인합니다"). 사용자가 원한 것은 긍정이다.
        // 한 줄짜리 변경은 범위가 좁다는 것 자체가 판정이라(프롬프트 ①) soft 로 둔다.
        if !heavy, let last = parts.last, approvalPhrases.contains(where: last.contains),
           !closingPraiseWords.contains(where: last.contains) {
            issues.append(Issue(level: .soft, rule: "요약-평가없음", detail: "승인 문장에 평가하는 말이 없다 — \(tail(last))"))
        }
        // 평가를 넣으라 했더니 "승인합니다" 를 꾸몄다(12회차: "…끊어 두어 탄탄하게 승인합니다").
        // 승인을 탄탄하게 하는 것이 아니라 한 일이 탄탄한 것이다. 1~11회차에는 0건이던 꼴이다.
        if let modified = matches("(잘|깔끔하게|꼼꼼하게|빠짐없이|세심하게|안전하게|탄탄하게|매끄럽게|정확하게|명확하게|정확히|명확히|훌륭하게) (승인합니다|그대로 가도|반영하면|반영해도|이대로 머지해도|머지를 막을)", in: summary) {
            issues.append(Issue(level: .hard, rule: "요약-승인수식", detail: "“\(modified)” — 평가가 한 일이 아니라 승인을 꾸민다"))
        }
        if let honorific = firstHonorific(in: summary) {
            issues.append(Issue(level: .hard, rule: "님", detail: "“\(honorific)”"))
        }

        // 값 안에 출력 형식의 조각·혼잣말이 섞였다(14회차 : "…승인합니다.</summary_ko... let me fix>").
        // 앱이 태그부터 잘라 내지만(ReviewOutput.tidied), 태그 없이 혼잣말만 남는 꼴은 못 자른다.
        for text in [summary, output.concernsNoteKo ?? "", output.questionsNoteKo ?? ""] + output.strengths {
            if let leak = matches("(?i)</?\\s*(summary_ko|strengths|concerns_note_ko|questions_note_ko|parameter|invoke)\\b|let me |I'll |I will ", in: text) {
                issues.append(Issue(level: .hard, rule: "출력-조각", detail: "“\(leak)” — \(tail(text))"))
            }
        }

        // ── 잘된 점
        for strength in output.strengths {
            let text = strength.trimmingCharacters(in: .whitespacesAndNewlines)
            let bare = text.hasSuffix(".") ? String(text.dropLast()) : text
            if !(bare.hasSuffix("다") || bare.hasSuffix("요")) {
                issues.append(Issue(level: .hard, rule: "잘된점-명사형", detail: "“\(text.suffix(30))”"))
            }
            if !praiseWords.contains(where: text.contains) {
                issues.append(Issue(level: .hard, rule: "잘된점-평가없음", detail: "“\(text)”"))
            }
            if text.count < 15 {
                issues.append(Issue(level: .soft, rule: "잘된점-빈말", detail: "“\(text)”"))
            }
            // 형용사 끝맺음을 동작 바로 뒤에 붙이면 무엇이 그런지가 빠져 문장이 어긋난다
            // (실측 7회차: "…죽은 상태가 남지 않게 깔끔합니다"). 주어를 끼워 넣어도
            // "~게" 가 걸려 있으면 마찬가지다(8회차: "…원인 추적이 쉽게 문서화가 꼼꼼합니다").
            // 1~8회차 잘된 점 131개에서 이 둘만 잡힌다.
            if let broken = matches("(게|도록) ([가-힣]+[이가] )?(깔끔|꼼꼼|세심|탄탄|돋보|반갑)(합니다|입니다|습니다)", in: text) {
                issues.append(Issue(level: .hard, rule: "잘된점-어긋난끝", detail: "“…\(broken)” — \(tail(text))"))
            }
        }

        // 잘된 점이 요약과 같은 말을 한다 — 기본 본문이 "요약 + 잘된 점" 이라 켜고 올리면
        // 같은 사실이 두 번 나간다(실측: "riley 가 지적한 … 순서 문제를 … 전부 반영").
        // 한글 표현만 견준다. 코드 식별자(statusBadgeLabel 등)는 길어서, 같은 주어만 써도
        // 기준을 넘어 헛잡는다(실측: "statusBadgeLabel 노출 중" 19자가 겹쳤을 뿐).
        let summaryKey = hangulOnly(summary)
        let summaryTokens = contentTokens(in: summary)
        for strength in output.strengths {
            let overlap = longestCommonRun(hangulOnly(strength), summaryKey)
            // 10자: 정당하게 겹친 것은 최대 6자("실행순서경합")였고, 같은 사실을 되풀이한 것은
            // 10자부터 나왔다(6회차: "대상판정을한곳으로모").
            if overlap >= 10 {
                issues.append(Issue(level: .hard, rule: "잘된점-요약중복",
                                    detail: "요약과 \(overlap)자가 겹친다 — “\(strength.prefix(50))…”"))
                continue
            }
            // 말을 바꿔 되풀이한 것은 글자가 이어서 겹치지 않는다(7회차 8건 중 6건 —
            // "초기화 시점을 세션 단위로" ↔ "세션 시작 시점에서만 초기화"). 내용어가 얼마나
            // 같은지로 본다. 식별자가 같다고 다 되풀이는 아니라서 사람이 읽게 soft 로 둔다.
            // 기준(4개 이상 · 40% 이상): 5~7회차에서 되풀이가 아닌 것은 최고 38% 였다(7회차 s2).
            let tokens = contentTokens(in: strength)
            let shared = tokens.intersection(summaryTokens)
            if shared.count >= 4, Double(shared.count) / Double(tokens.count) >= 0.40 {
                issues.append(Issue(level: .soft, rule: "잘된점-요약겹침",
                                    detail: "내용어 \(shared.count)/\(tokens.count)개가 요약과 같다(\(shared.sorted().prefix(5).joined(separator: "·"))) — “\(strength.prefix(40))…”"))
            }
        }

        // 주석 칭찬은 쉬워서 쏠린다(11~13회차 잘된 점의 55%, 리뷰 19건 중 9건이 주석 칭찬뿐).
        // 한 리뷰에 두 번이면 코드가 한 일을 칭찬할 자리를 주석이 차지한 것이다.
        let commentPraises = output.strengths.filter { $0.contains("주석") || $0.contains("문서") || $0.contains("doc ") }
        if commentPraises.count >= 2 {
            issues.append(Issue(level: .soft, rule: "잘된점-주석두번",
                                detail: "잘된 점 \(output.strengths.count)개 중 \(commentPraises.count)개가 주석 칭찬이다"))
        }

        // 잘된 점 여러 개가 같은 말로 끝나면 틀에 박힌 칭찬으로 읽힌다
        // (실측: 여러 리뷰에서 "…점이 좋습니다" 가 두 번씩).
        let endings = output.strengths.map { strength -> String in
            let bare = strength.trimmingCharacters(in: .whitespacesAndNewlines)
                .trimmingCharacters(in: CharacterSet(charactersIn: "."))
            return String(bare.suffix(6))
        }
        let repeated = Dictionary(grouping: endings, by: { $0 }).filter { $0.value.count >= 2 }.keys
        for ending in repeated.sorted() {
            issues.append(Issue(level: .hard, rule: "잘된점-같은끝", detail: "“…\(ending)” 가 여러 번"))
        }

        // 과거형 오타("고쳐습니다" ← 고쳤습니다). 프롬프트로는 못 막고 사람이 봐야 한다.
        // 맞는 꼴은 늘 받침 있는 과거형(었·았·였·했·쳤·졌…) 뒤에 "습니다" 가 온다.
        for text in [summary] + output.strengths {
            if let typo = matches("(쳐|져|어|여|와|워|봐|해)습니다", in: text) {
                issues.append(Issue(level: .soft, rule: "맞춤법", detail: "“\(typo)” — \(tail(text))"))
            }
        }

        // ── 안내 문장
        let concernNote = output.concernsNoteKo?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let questionNote = output.questionsNoteKo?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        let questions = output.questionsForAuthor ?? []
        if !output.concerns.isEmpty, concernNote.isEmpty {
            issues.append(Issue(level: .soft, rule: "안내-우려없음", detail: "우려 \(output.concerns.count)건인데 소개 문장이 없다"))
        }
        if !questions.isEmpty, questionNote.isEmpty {
            issues.append(Issue(level: .soft, rule: "안내-질문없음", detail: "질문 \(questions.count)건인데 소개 문장이 없다"))
        }
        let heavyConcern = output.concerns.contains { $0.severity == .blocker || $0.severity == .major }
        let asksToCheck = ["확인이 필요", "확인 부탁", "확인해 주"]
        if output.verdict == .requestChanges, asksToCheck.contains(where: summary.contains),
           asksToCheck.contains(where: concernNote.contains) {
            issues.append(Issue(level: .hard, rule: "안내-중복",
                                detail: "요약이 이미 확인이 필요하다고 했는데 우려 안내가 되풀이한다 — \(concernNote)"))
        }
        if heavyConcern, output.verdict != .requestChanges, !concernNote.isEmpty,
           !asksToCheck.contains(where: concernNote.contains) {
            issues.append(Issue(level: .hard, rule: "안내-중요도",
                                detail: "major 이상인데 확인이 필요하다고 말하지 않는다 — \(concernNote)"))
        }
        if output.concerns.isEmpty, !concernNote.isEmpty {
            issues.append(Issue(level: .hard, rule: "안내-빈항목", detail: "우려가 없는데 우려 안내가 있다"))
        }
        if questions.isEmpty, !questionNote.isEmpty {
            issues.append(Issue(level: .hard, rule: "안내-빈항목", detail: "질문이 없는데 질문 안내가 있다"))
        }
        // 안내 문장이 무엇에 대한 것인지 말하지 않고 자기 형식을 설명한다
        // (실측 6회차: "major 항목 하나를 질문 형태로 남겼고…", "누가 어디서 말했는지와").
        let selfDescribing = ["질문 형태로", "항목 하나를", "형태로 남겼", "누가 어디서 말했는지"]
        for note in [concernNote, questionNote] where !note.isEmpty {
            if let phrase = selfDescribing.first(where: note.contains) {
                issues.append(Issue(level: .hard, rule: "안내-자기설명", detail: "“\(phrase)” — \(note)"))
            }
            // 본문에는 [높음] 같은 한국어 등급 표시가 따로 붙는다. 영어 등급 이름은 소음이다.
            if let grade = ["blocker", "major", "minor", "nit"].first(where: { note.lowercased().contains($0) }) {
                issues.append(Issue(level: .soft, rule: "안내-등급이름", detail: "“\(grade)” — \(note)"))
            }
        }

        // 안내 문장은 "왜 묻는지" 를 설명하느라 "diff 에 보이지 않는" 같은 말을 정당하게 쓴다.
        // 판정 꼴(머지를 막을 …)만 잡는다.
        for note in [concernNote, questionNote] where !note.isEmpty {
            for pattern in negativeClosings where matches(pattern, in: note) != nil {
                issues.append(Issue(level: .hard, rule: "안내-부정형", detail: note))
            }
        }

        // ── 인라인 코멘트 말투
        for comment in output.draftComments {
            if let honorific = firstHonorific(in: comment.body) {
                issues.append(Issue(level: .hard, rule: "님", detail: "코멘트 “\(honorific)”"))
            }
            // 필수가 아닌 코멘트는 "(비블로커)" 나 "[질문]" 으로 시작한다 — 받는 사람이 막는 말인지 바로 안다.
            let body = comment.body.trimmingCharacters(in: .whitespacesAndNewlines)
            if comment.severity != .blocker, !body.hasPrefix("(비블로커)"), !body.hasPrefix("[질문]") {
                issues.append(Issue(level: .soft, rule: "코멘트-접두", detail: "\(comment.issueKey): “\(body.prefix(30))…”"))
            }
        }

        // ── 판정과 중요도 — 필수가 있으면 request_changes, 권장이 있으면 comment, 그 밖은 approve.
        // 옛 형식(우려가 따로 있던 때)은 규칙이 달라 새 형식에서만 본다.
        if output.concerns.isEmpty, (output.questionsForAuthor ?? []).isEmpty {
            let severities = output.draftComments.map(\.severity)
            let expected: Verdict = severities.contains(.blocker) ? .requestChanges
                : severities.contains(where: { $0 == .major || $0 == .minor }) ? .comment
                : .approve
            if output.verdict != expected {
                issues.append(Issue(level: .hard, rule: "판정-중요도",
                                    detail: "코멘트 중요도로는 \(expected.rawValue) 인데 verdict=\(output.verdict.rawValue)"))
            }
        }
        return issues
    }

    /// 코드 식별자처럼 보이는 영문 토큰(5자 이상). 우려 제목과 요약이 같은 것을 가리키는지 볼 때 쓴다.
    static func identifierTokens(in text: String) -> [String] {
        text.split(whereSeparator: { !($0.isLetter && $0.isASCII) && $0 != "-" && $0 != "_" })
            .map(String.init)
            .filter { $0.count >= 5 }
            .map { $0.lowercased() }
    }

    /// 문장의 내용어 — 영문 식별자(소문자로)와 한글 낱말의 앞 두 글자.
    ///
    /// 앞 두 글자만 보는 것은 활용을 한데 묶으려고다("초기화를"·"초기화해" → 초기).
    /// 조사를 먼저 떼고, 어느 문장에나 나오는 말(변경·승인·깔끔…)은 뺀다.
    static func contentTokens(in text: String) -> Set<String> {
        var tokens = Set<String>()
        var ascii = "", hangul = ""
        func flush() {
            let word = ascii.drop(while: \.isNumber)
            if word.count >= 2 { tokens.insert(word.lowercased()) }
            ascii = ""
            var stem = Substring(hangul)
            if let particle = particles.first(where: { stem.hasSuffix($0) && stem.count - $0.count >= 2 }) {
                stem = stem.dropLast(particle.count)
            }
            if stem.count >= 2 {
                let head = String(stem.prefix(2))
                if !commonStems.contains(head) { tokens.insert(head) }
            }
            hangul = ""
        }
        for character in text {
            if character.isASCII, character.isLetter || character.isNumber || character == "_" {
                if !hangul.isEmpty { flush() }
                ascii.append(character)
            } else if let scalar = character.unicodeScalars.first, (0xAC00...0xD7A3).contains(scalar.value) {
                if !ascii.isEmpty { flush() }
                hangul.append(character)
            } else {
                flush()
            }
        }
        flush()
        return tokens
    }

    /// 긴 것부터 — "으로" 를 "로" 보다 먼저 뗀다.
    private static let particles = ["으로도", "에서", "으로", "까지", "부터", "에도", "이나", "만을", "에만",
                                    "처럼", "보다", "마다", "이며", "을", "를", "이", "가", "은", "는", "의",
                                    "에", "로", "와", "과", "도", "만", "나", "인"]

    /// 어느 요약·칭찬에나 나오는 말. 겹쳐도 같은 사실을 말했다는 증거가 아니다.
    private static let commonStems: Set<String> = [
        "변경", "승인", "처리", "정리", "했습", "합니", "있습", "없습", "같은", "모두", "함께", "그대", "이번",
        "위해", "통해", "대해", "경우", "부분", "코드", "하나", "점이", "좋습", "깔끔", "꼼꼼", "세심", "탄탄",
        "빠짐", "두셨", "주셔", "수정", "추가", "이후", "기존", "문제", "고친", "고쳐", "바꾼", "바꿔", "확인",
        "구조", "방식", "흐름", "남겨", "남기", "하게", "해서", "하는", "하고", "이유", "다시", "새로", "모든",
        "여러", "반갑", "돋보", "좋은", "선택", "입니", "됩니", "되어", "되었", "않게", "않도", "없이", "없게",
        "않고", "한번", "그것", "이것", "해당", "각각", "전부", "직접", "바로", "먼저", "실제", "제대", "정확",
        "명확", "일관", "동일", "구체",
    ]

    static func hangulOnly(_ text: String) -> String {
        String(text.unicodeScalars.filter { (0xAC00...0xD7A3).contains($0.value) }.map(Character.init))
    }

    /// 두 문자열에 이어서 똑같이 나오는 가장 긴 구간의 길이.
    static func longestCommonRun(_ a: String, _ b: String) -> Int {
        let x = Array(a), y = Array(b)
        guard !x.isEmpty, !y.isEmpty else { return 0 }
        var previous = [Int](repeating: 0, count: y.count + 1)
        var best = 0
        for i in 1...x.count {
            var current = [Int](repeating: 0, count: y.count + 1)
            for j in 1...y.count where x[i - 1] == y[j - 1] {
                current[j] = previous[j - 1] + 1
                best = max(best, current[j])
            }
            previous = current
        }
        return best
    }

    static func negativeHits(in text: String) -> [String] {
        var hits: [String] = []
        for pattern in negativeClosings {
            if let hit = matches(pattern, in: text) { hits.append(hit) }
        }
        for sentence in sentences(of: text) where issueWords.contains(where: sentence.contains) {
            for phrase in negativeIfAboutIssues where sentence.contains(phrase) { hits.append(phrase) }
        }
        return hits
    }

    /// 문장으로 나눈다. 마침표 뒤에 빈칸이나 끝이 올 때만 자른다 — "2.3.0-beta1" · "build.sh" 에서
    /// 자르면 문장 수가 부풀고(9회차 가 4문장으로 잡혔다) 판정 문장을 엉뚱한 조각으로 본다.
    static func sentences(of text: String) -> [String] {
        guard let regex = try? NSRegularExpression(pattern: "[.?!](?=\\s|$)|\\n") else { return [text] }
        var pieces: [String] = []
        var start = text.startIndex
        for match in regex.matches(in: text, range: NSRange(text.startIndex..., in: text)) {
            guard let range = Range(match.range, in: text) else { continue }
            pieces.append(String(text[start..<range.lowerBound]))
            start = range.upperBound
        }
        pieces.append(String(text[start...]))
        return pieces.map { $0.trimmingCharacters(in: .whitespaces) }.filter { !$0.isEmpty }
    }

    private static func matches(_ pattern: String, in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: pattern),
              let match = regex.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)),
              let range = Range(match.range, in: text) else { return nil }
        return String(text[range])
    }

    /// "riley님이" 같은 호칭 — 영문 이름·아이디 뒤에는 "님" 을 붙이지 않는다(review.md 의 앱 기본 규칙).
    /// 한글 이름 뒤의 "님" 은 맞는 말이라 잡지 않는다(영문자로 시작하는 이름만 본다).
    private static func firstHonorific(in text: String) -> String? {
        guard let regex = try? NSRegularExpression(pattern: "[A-Za-z][A-Za-z0-9_-]*님") else { return nil }
        let range = NSRange(text.startIndex..., in: text)
        guard let match = regex.firstMatch(in: text, range: range),
              let swiftRange = Range(match.range, in: text) else { return nil }
        return String(text[swiftRange])
    }

    private static func tail(_ text: String) -> String {
        text.count > 60 ? "…" + text.suffix(60) : text
    }
}
