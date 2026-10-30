import SwiftUI
import PRayerCore

/// "이미 언급됨" 을 눌렀을 때 펼쳐지는 패널.
///
/// 그 지적이 PR 안에서 실제로 어떻게 오갔는지 보여 준다 — 누가 말했는지, 스레드가 통째로
/// (앞뒤 답글까지) 어떻게 이어졌는지, 그리고 어느 대목을 말하는지. 작성자 답변은 따로 표시한다.
///
/// **무엇을 칠할지는 AI 가 정한다.** 낱말 겹침으로 고르면 놓치고 헛짚는다(실측: 초안은
/// `.sink` 결과 미저장 얘기인데 같은 파일 스레드는 `addSubview` z-순서 얘기였다 — 낱말은
/// 하나도 겹치지 않지만 사람은 둘을 구분해야 한다). 대조를 아직 안 돌렸을 때만 낱말 겹침으로
/// 대충 칠하고, 그 사실을 화면에 적어 둔다.
///
/// 별도 `View` 로 둔다. 다른 뷰의 계산 프로퍼티 안에서 인스턴스를 만들어 쓰면
/// SwiftUI 가 환경을 심어 주지 않아 `@Environment` 를 읽는 순간 죽는다(실측).
struct RelatedDiscussionPanel: View {
    @Environment(AppModel.self) private var model
    let pr: PullRequestInfo
    let subject: DiscussionSubject
    /// 자리가 없는 항목(작성자 질문 등)은 갈 곳이 없다. nil 이면 버튼을 그리지 않는다.
    let onJump: (() -> Void)?

    private var key: String { model.relevanceKey(pr: pr, subject: subject) }
    private var result: DiscussionRelevance? { model.relevance(for: key) }
    private var isRunning: Bool { model.isMatchingRelevance(key) }

    /// AI 결과가 있으면 후보 전체를, 없으면 낱말이 겹친 것만 보여 준다.
    private var discussion: RelatedDiscussion {
        if result != nil || isRunning {
            return RelatedDiscussionBuilder.candidates(pr: pr, path: subject.path,
                                                       line: subject.line, prAuthor: pr.author)
        }
        return RelatedDiscussionBuilder.build(pr: pr, path: subject.path, line: subject.line,
                                              anchorText: subject.anchorText,
                                              commentBody: subject.body, prAuthor: pr.author)
    }

    var body: some View {
        let discussion = discussion
        VStack(alignment: .leading, spacing: 8) {
            header(discussion)
            aiRow

            if let result {
                Text(result.summaryKo)
                    .font(.caption)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if discussion.isEmpty {
                Text("이 지적과 이어지는 코멘트를 찾지 못했습니다. 이미 해결돼 정리된 스레드이거나, GitHub 에서 받아 온 범위를 벗어난 오래된 대화일 수 있습니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                ForEach(orderedThreads(discussion)) { thread in
                    threadCard(thread)
                }
                let comments = orderedComments(discussion)
                if !comments.isEmpty {
                    VStack(alignment: .leading, spacing: 6) {
                        Text("PR 대화")
                            .font(.caption2.weight(.semibold))
                            .foregroundStyle(.tertiary)
                        ForEach(comments) { message in
                            messageRow(message)
                        }
                    }
                }
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.orange.opacity(0.06), in: RoundedRectangle(cornerRadius: 6))
        .overlay {
            RoundedRectangle(cornerRadius: 6)
                .stroke(Color.orange.opacity(0.25), lineWidth: 1)
        }
    }

    // MARK: - 머리말

    private func header(_ discussion: RelatedDiscussion) -> some View {
        HStack(spacing: 6) {
            Image(systemName: "bubble.left.and.bubble.right.fill")
                .font(.caption2)
                .foregroundStyle(Color.orange)
            Text(discussion.isEmpty ? "오간 대화" : "오간 대화 \(discussion.messageCount)건")
                .font(.caption.weight(.semibold))
            if let result {
                Tag(text: result.verdict.label,
                    color: result.verdict == .alreadyResolved ? .green : .accentColor)
            } else if discussion.hasAuthorReply {
                Tag(text: "작성자 답변 있음", color: .accentColor)
            }
            Spacer()
            if let onJump {
                Button("Diff 에서 보기", action: onJump)
                    .buttonStyle(.link)
                    .font(.caption2)
            }
        }
    }

    /// 대조를 돌리는 줄. 무엇을 보내는지와 결과 시각을 함께 적는다.
    @ViewBuilder
    private var aiRow: some View {
        if isRunning {
            HStack(spacing: 6) {
                ProgressView().controlSize(.small)
                Text("AI 가 이어지는 대목을 고르는 중…").font(.caption2).foregroundStyle(.secondary)
            }
        } else if let result {
            HStack(spacing: 6) {
                Image(systemName: "sparkles").font(.system(size: 9)).foregroundStyle(Color.accentColor)
                Text("AI 가 고른 관련 대목 \(result.matches.count)건 · \(RelativeTime.ago(result.createdAt))")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                Button("다시 고르기") { model.matchRelevance(pr: pr, subject: subject) }
                    .buttonStyle(.link)
                    .font(.caption2)
                Spacer()
            }
        } else {
            HStack(spacing: 6) {
                Button {
                    model.matchRelevance(pr: pr, subject: subject)
                } label: {
                    Label("AI 로 관련 대목 찾기", systemImage: "sparkles").font(.caption2)
                }
                .buttonStyle(.link)
                .help("이 지적과 PR 의 코멘트들을 대조해, 정말 이어지는 대목과 칠할 문구를 골라 옵니다. 코드는 보내지 않습니다.")
                Text("· 지금은 겹치는 낱말만 칠해져 있습니다")
                    .font(.caption2)
                    .foregroundStyle(.tertiary)
                Spacer()
            }
        }
    }

    // MARK: - 정렬 — AI 가 고른 것을 앞으로

    private func orderedThreads(_ discussion: RelatedDiscussion) -> [RelatedDiscussion.Thread] {
        guard let result else { return discussion.threads }
        return discussion.threads.sorted { lhs, rhs in
            let l = lhs.messages.contains { result.match(for: $0.id) != nil }
            let r = rhs.messages.contains { result.match(for: $0.id) != nil }
            if l != r { return l }
            if lhs.relevance != rhs.relevance { return lhs.relevance < rhs.relevance }
            return (lhs.line ?? .max) < (rhs.line ?? .max)
        }
    }

    private func orderedComments(_ discussion: RelatedDiscussion) -> [RelatedDiscussion.Message] {
        guard result != nil else { return discussion.comments }
        // 대조를 돌렸으면 관련 없는 PR 대화까지 늘어놓지 않는다.
        return discussion.comments.filter { result?.match(for: $0.id) != nil }
    }

    // MARK: - 조각

    private func threadCard(_ thread: RelatedDiscussion.Thread) -> some View {
        VStack(alignment: .leading, spacing: 5) {
            HStack(spacing: 5) {
                Text(location(thread))
                    .font(model.fonts.code(size: max(9, model.settings.codeFontSize - 2)))
                    .foregroundStyle(.secondary)
                Tag(text: thread.relevance.label,
                    color: thread.relevance == .sameFile ? .secondary : .orange)
                if thread.isResolved { Tag(text: "해결됨", color: .green) }
                if thread.isOutdated { Tag(text: "오래된 자리", color: .secondary) }
                Spacer()
            }
            ForEach(thread.messages) { message in
                messageRow(message)
            }
        }
        .padding(7)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(.background.opacity(0.6), in: RoundedRectangle(cornerRadius: 5))
    }

    private func messageRow(_ message: RelatedDiscussion.Message) -> some View {
        let match = result?.match(for: message.id)
        // 대조를 돌렸는데 안 고른 메시지는 맥락으로만 남기고 흐리게 둔다.
        let isDimmed = result != nil && match == nil
        return HStack(alignment: .top, spacing: 6) {
            Avatar(login: message.author, name: model.settings.displayName(message.author), size: 16)
                .padding(.top, 1)
            VStack(alignment: .leading, spacing: 2) {
                HStack(spacing: 5) {
                    Text(model.settings.displayName(message.author))
                        .font(.caption.weight(.medium))
                        .help(message.author)
                    if let match {
                        Tag(text: match.relevance.label,
                            color: match.relevance == .resolution ? .green : .accentColor)
                    } else if message.isAuthorReply {
                        Tag(text: "작성자", color: .accentColor)
                    }
                    if let at = message.at {
                        RelativeTimeText(date: at, style: .ago)
                            .font(.caption2)
                            .foregroundStyle(.tertiary)
                            .help(at.formatted(date: .abbreviated, time: .shortened))
                    }
                    Spacer()
                }
                if let match, !match.whyKo.isEmpty {
                    Text(match.whyKo)
                        .font(.caption2)
                        .foregroundStyle(Color.accentColor)
                        .fixedSize(horizontal: false, vertical: true)
                }
                body(of: message, quotes: match?.quotes ?? message.highlights)
            }
        }
        .opacity(isDimmed ? 0.45 : 1)
        .padding(.leading, message.isAuthorReply ? 6 : 0)
        .overlay(alignment: .leading) {
            if message.isAuthorReply {
                RoundedRectangle(cornerRadius: 1)
                    .fill(Color.accentColor.opacity(0.5))
                    .frame(width: 2)
            }
        }
    }

    /// 어느 문구를 말하는지 형광펜으로 집어 준다.
    ///
    /// `Text` 를 `+` 로 이어 붙이는 방식은 배경색을 줄 수 없어서 AttributedString 으로 만든다.
    private func body(of message: RelatedDiscussion.Message, quotes: [String]) -> some View {
        var attributed = AttributedString()
        for segment in HighlightedText.split(message.body, quotes: quotes).segments {
            var piece = AttributedString(segment.text)
            if segment.isHighlighted {
                piece.backgroundColor = Color.yellow.opacity(0.35)
                piece.foregroundColor = Color.primary
                piece.inlinePresentationIntent = .stronglyEmphasized
            } else {
                piece.foregroundColor = Color.secondary
            }
            attributed.append(piece)
        }
        return Text(attributed)
            .font(model.fonts.comment(size: max(10, model.settings.commentFontSize - 1)))
            .textSelection(.enabled)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func location(_ thread: RelatedDiscussion.Thread) -> String {
        let name = (thread.path ?? subject.path).split(separator: "/").last.map(String.init) ?? subject.path
        guard let line = thread.line else { return name }
        return "\(name):\(line)"
    }
}
