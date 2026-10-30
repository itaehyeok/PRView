import SwiftUI
import PRayerCore

/// 변경 파일 탭에서 따라가는 리뷰 항목과 그 자리(질문이면 몇 번째 근거인지).
///
/// 예전에는 우려사항·질문의 코드 링크를 누르면 그 줄로 스크롤만 했다. 줄 강조도 없고 항목 글도
/// diff 에 없어서, 무엇 때문에 왔는지 보려면 AI 리뷰 탭으로 다시 가야 했다(사용자 피드백).
/// 이제 그 줄 아래에 항목을 펼쳐 놓고, 위쪽 따라가기 줄에서 ‹ › 로 다음 항목으로 넘긴다.
struct ReviewFollow: Equatable {
    var itemKey: String
    var locationIndex: Int
}

/// AI 리뷰 탭의 행 id. 변경 파일 탭에서 돌아올 때 이 id 로 스크롤한다.
enum ReviewRowID {
    static func of(_ itemKey: String) -> String { "review-row:\(itemKey)" }
}

/// 리뷰 항목의 자리 이름("우려사항 2"). 옮겨 만든 초안에 어디서 옮겼는지 붙인다.
enum ReviewPlaceName {
    static func of(_ key: String, in record: ReviewRecord) -> String {
        if let index = record.output.concerns.firstIndex(where: { ReviewItemKey.concern($0) == key }) {
            return "우려사항 \(index + 1)"
        }
        if let index = (record.output.questionsForAuthor ?? []).firstIndex(where: { ReviewItemKey.question($0) == key }) {
            return "질문 \(index + 1)"
        }
        if record.comments.contains(where: { ReviewItemKey.draft($0.comment) == key }) {
            return "인라인 초안"
        }
        return "AI 리뷰"
    }
}

/// 심각도 색. 우려사항 행·초안 카드와 같은 값이다.
func reviewSeverityColor(_ severity: Severity) -> Color {
    switch severity {
    case .blocker: return .red
    case .major: return .orange
    case .minor, .nit: return .secondary
    }
}

/// 따라가는 항목 하나를 diff 줄 아래에 그릴 재료. 변경 파일 탭(DiffTab)이 리뷰 기록에서 만든다.
struct FollowTarget {
    let item: FollowableItem
    let locationIndex: Int
    /// 따라가기 목록에서 몇 번째인가(1부터).
    let position: Int
    let total: Int
    /// 인라인 초안으로 옮겼으면 그 초안.
    let moved: DraftCommentState?
    let isCleared: Bool
    /// 그 줄이 diff 안에 있는가. 밖이면 인라인 코멘트를 달 수 없다(GitHub 이 리뷰 전체를 거부한다).
    let canAttach: Bool
    /// 그 줄에 이미 다른 인라인 초안이 있는가. 모델은 같은 사안을 우려사항과 초안 두 곳에 같이 적곤 해서,
    /// 그대로 옮기면 같은 줄에 같은 얘기가 두 번 달린다(실측: 우려사항과 같은 줄·같은 얘기의 초안).
    let hasOtherDraftHere: Bool
    let isPosted: Bool
    let onMove: () -> Void
    let onUndoMove: () -> Void
    let onClear: () -> Void
    let onUnclear: () -> Void
    let onEditMoved: (String) -> Void
    let onPickLocation: (Int) -> Void
    let onNext: () -> Void

    var location: FollowableItem.Location { item.locations[locationIndex] }

    /// 이 diff 행이 따라가는 줄인가. 맥락 줄은 왼쪽·오른쪽이 같은 줄이다.
    func matches(_ row: DiffRow) -> Bool {
        guard row.kind != .hunk else { return false }
        switch location.side {
        case .right: return row.right?.newLine == location.line && row.right?.kind != .deletion
        case .left: return row.left?.oldLine == location.line && row.left?.kind != .addition
        }
    }

    /// 줄 하나를 칠할지. 나란히 보기에서는 한 행에 옛 줄·새 줄이 같이 있어 그 쪽 칸만 칠한다.
    func highlights(_ line: DiffLine?, kind: DiffLine.Kind) -> Bool {
        guard let line else { return false }
        switch location.side {
        case .right: return line.newLine == location.line && kind != .deletion
        case .left: return line.oldLine == location.line && kind != .addition
        }
    }
}

/// 따라가는 줄 바로 아래에 펼치는 리뷰 항목 카드.
///
/// 보라색으로 그린다 — 사람 코멘트(파랑)·AI 인라인 초안(주황)과 달리 **아직 리뷰 본문에 있는** 항목이다.
/// 여기서 그 줄의 인라인 코멘트로 옮기거나("이 줄에 코멘트로 달기"), 문제없음으로 정리한다.
struct ReviewItemInlineCard: View {
    let target: FollowTarget

    private var item: FollowableItem { target.item }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Tag(text: item.kind.label, color: .purple)
                if let severity = item.severity {
                    Tag(text: severity.label, color: reviewSeverityColor(severity))
                }
                if item.isDuplicate {
                    Tag(text: "이미 언급됨", color: .orange)
                }
                Text(item.title)
                    .font(.callout.weight(.semibold))
                    .strikethrough(target.isCleared, color: .secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .textSelection(.enabled)
                Spacer(minLength: 0)
                Text("리뷰 본문 항목")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .fixedSize()
            }

            if let note = item.existingNote, !note.isEmpty {
                Label(note, systemImage: "bubble.left.and.bubble.right")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            if item.kind == .question {
                questionContext
            }

            if let moved = target.moved {
                movedBox(moved)
            } else if target.isCleared {
                clearedBox
            } else {
                actions
            }
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.purple.opacity(0.06), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.purple.opacity(0.28)))
        .padding(.horizontal, 12)
        .padding(.vertical, 6)
    }

    /// 질문은 "왜 묻는지" 가 판단의 절반이다. 근거가 여러 곳이면 여기서 옮겨 다닌다.
    @ViewBuilder
    private var questionContext: some View {
        VStack(alignment: .leading, spacing: 6) {
            if let rationale = item.rationale, !rationale.isEmpty {
                HStack(alignment: .top, spacing: 4) {
                    Image(systemName: "lightbulb")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text(rationale)
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                        .textSelection(.enabled)
                }
            }
            if item.locations.count > 1 {
                HStack(spacing: 6) {
                    Text("근거 \(target.locationIndex + 1)/\(item.locations.count)")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    ForEach(Array(item.locations.enumerated()), id: \.offset) { index, location in
                        Button {
                            target.onPickLocation(index)
                        } label: {
                            Text("\(location.fileName):\(location.line)")
                                .font(.caption.monospaced())
                                .padding(.horizontal, 6)
                                .padding(.vertical, 2)
                                .background(index == target.locationIndex ? Color.purple.opacity(0.15) : Color.clear,
                                            in: RoundedRectangle(cornerRadius: 4))
                                .overlay(RoundedRectangle(cornerRadius: 4)
                                    .strokeBorder(index == target.locationIndex ? Color.purple.opacity(0.4) : Color.secondary.opacity(0.3)))
                                .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .help(location.note ?? location.path)
                    }
                }
            } else if let note = target.location.note, !note.isEmpty {
                Text(note)
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
        .padding(8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.yellow.opacity(0.09), in: RoundedRectangle(cornerRadius: 6))
    }

    @ViewBuilder
    private var actions: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(statusText)
                .font(.caption)
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            if target.hasOtherDraftHere, !target.isPosted {
                Label("이 줄에는 이미 인라인 초안이 있습니다. 같은 얘기라면 옮기지 말고 본문에서 빼거나 정리하세요 — 옮기면 같은 줄에 두 번 달립니다.",
                      systemImage: "exclamationmark.bubble")
                    .font(.caption)
                    .foregroundStyle(.orange)
                    .fixedSize(horizontal: false, vertical: true)
            }
            HStack(spacing: 8) {
                if !target.isPosted {
                    Button(item.kind == .question ? "이 줄에 질문으로 달기" : "이 줄에 코멘트로 달기",
                           action: target.onMove)
                        .buttonStyle(.borderedProminent)
                        .tint(.purple)
                        .controlSize(.small)
                        .disabled(!target.canAttach)
                        .help(target.canAttach
                              ? "이 줄의 인라인 코멘트 초안으로 옮깁니다. 리뷰 본문에서는 빠집니다."
                              : "이 줄은 diff 밖이라 인라인 코멘트를 달 수 없습니다. 리뷰 본문에 남겨 두세요.")
                    Button("문제없음으로 정리", action: target.onClear)
                        .controlSize(.small)
                        .help("본문의 '\(PostBuilder.clearedHeading)' 에 한 줄로 남깁니다. 문구는 AI 리뷰 탭에서 고칠 수 있습니다.")
                }
                Spacer()
                if target.total > 1 {
                    Button(action: target.onNext) {
                        HStack(spacing: 2) {
                            Text("다음 항목")
                            Image(systemName: "chevron.right")
                                .font(.system(size: 9, weight: .semibold))
                        }
                    }
                    .buttonStyle(.link)
                    .font(.caption)
                }
            }
        }
    }

    private var statusText: String {
        if target.isPosted { return "이미 게시한 리뷰라 바꿀 수 없습니다." }
        if !target.canAttach { return "이 줄은 diff 밖이라 인라인 코멘트로는 달 수 없습니다. 리뷰 본문에 한 줄로 올라갑니다." }
        return "지금은 리뷰 본문에 한 줄로 올라갑니다. 이 줄에 달면 작성자가 코드 옆에서 바로 봅니다."
    }

    /// 옮긴 뒤. 본문이 항목 글 그대로라 다듬어야 해서, 그 자리에서 고치게 한다.
    @ViewBuilder
    private func movedBox(_ moved: DraftCommentState) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Image(systemName: "text.bubble.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
                Text("이 줄의 인라인 코멘트 초안으로 옮겼습니다")
                    .font(.caption.weight(.semibold))
                Text("· 리뷰 본문에서는 빠집니다")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                Spacer()
                if !target.isPosted {
                    Button("본문으로 되돌리기", action: target.onUndoMove)
                        .buttonStyle(.link)
                        .font(.caption)
                }
            }
            TextEditor(text: Binding(get: { moved.editedBody }, set: target.onEditMoved))
                .font(.callout)
                .frame(minHeight: 56)
                .scrollContentBackground(.hidden)
                .padding(6)
                .background(Color(nsColor: .textBackgroundColor), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.orange.opacity(0.35)))
                .disabled(target.isPosted)
            Text("항목 글을 그대로 옮겼습니다. 코드 옆에 다는 말로 다듬어 주세요 — 체크한 초안만 게시됩니다.")
                .font(.caption2)
                .foregroundStyle(.secondary)
        }
        .padding(8)
        .background(Color.orange.opacity(0.07), in: RoundedRectangle(cornerRadius: 6))
    }

    private var clearedBox: some View {
        HStack(spacing: 6) {
            Image(systemName: "checkmark.seal.fill")
                .font(.caption)
                .foregroundStyle(.green)
            Text("문제없음으로 정리했습니다 — 본문의 '\(PostBuilder.clearedHeading)' 에 올라갑니다.")
                .font(.caption)
            Spacer()
            if !target.isPosted {
                Button("정리 취소", action: target.onUnclear)
                    .buttonStyle(.link)
                    .font(.caption)
            }
        }
        .padding(6)
        .background(Color.green.opacity(0.09), in: RoundedRectangle(cornerRadius: 5))
    }
}
