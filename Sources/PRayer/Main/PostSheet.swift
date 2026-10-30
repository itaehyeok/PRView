import SwiftUI
import PRayerCore

/// 게시 시트. 버튼 이름은 "게시" 이고, GitHub 리뷰 종류는 매번 명시적으로 고른다.
struct PostSheet: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let pr: PullRequestInfo
    let record: ReviewRecord

    @State private var event: ReviewEvent = .comment
    @State private var body_: String = ""
    @State private var isPosting = false
    @State private var errorMessage: String?
    @State private var headWarning: String?
    @State private var showRequestChangesConfirm = false
    @State private var checkedHead = false
    @State private var headBlocked = false
    @State private var pendingDrift: PendingDrift?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 14) {
                    eventSection
                    composeSection
                    bodySection
                    commentsSection
                    payloadSection
                }
                .padding(16)
            }
            Divider()
            footer
        }
        .frame(width: 640, height: 620)
        .task {
            // 게시 버튼에 지금 골라져 있는 것과 같은 종류로 연다. 예전에는 이 창만 설정의 "리뷰 종류 기본값" 을
            // 읽어, 버튼은 "코멘트+Approve" 인데 창은 "코멘트만" 으로 열렸다.
            event = PostActionPlan.current(saved: record.plannedAction,
                                           in: PostActionPlan.context(record: record, pr: pr)).event
            // 게시 전이면 리뷰 탭의 본문 상자(체크·고친 글)와 같은 글로 연다. `bodyDraft` 는 리뷰가 끝난 순간의
            // 원문으로 만든 값이라, 이걸로 열면 체크를 끈 절과 본문에서 고친 글이 이 창에서만 되살아났다.
            body_ = record.isPosted && !record.bodyDraft.isEmpty ? record.bodyDraft : composedBody()
            await verifyHead()
        }
        .sheet(item: $pendingDrift) { pending in
            NewCommitsSheet(prompt: pending.prompt, onConfirm: pending.confirm)
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("리뷰 게시")
                .font(.headline)
            Text(verbatim: "#\(pr.number) \(pr.title)")
                .font(.callout)
                .foregroundStyle(.secondary)
                .lineLimit(1)
            if let headWarning {
                Label(headWarning, systemImage: "exclamationmark.triangle.fill")
                    .font(.caption)
                    .foregroundStyle(.orange)
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(16)
    }

    private var eventSection: some View {
        GroupBox("리뷰 종류") {
            VStack(alignment: .leading, spacing: 8) {
                // 내가 만든 PR 은 승인 옵션 자체를 제외한다(Picker 를 비활성화하면 오히려 종류를 바꿀 수 없다).
                Picker("", selection: $event) {
                    ForEach(PostBuilder.availableEvents(viewerDidAuthor: pr.viewerDidAuthor)) { option in
                        Text(option.label).tag(option)
                    }
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                Text(event.explanation)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                if pr.viewerDidAuthor {
                    Text("내가 만든 PR 이라 Approve·변경 요청은 선택할 수 없습니다(GitHub 가 거부).")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                if PostBuilder.requiresBody(event), body_.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                    Text("이 종류는 본문이 필수입니다. 비워 두면 기본 문구가 들어갑니다.")
                        .font(.caption)
                        .foregroundStyle(.orange)
                }
                Text("각 코멘트 끝에 숨은 마커(GitHub 화면에는 안 보임)가 붙습니다.")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// 체크한 항목만 모아 본문을 만든다.
    /// 미리보기와 같은 조립 함수를 쓴다. 두 화면이 다른 본문을 보여주면 확인의 의미가 없다.
    private func composedBody() -> String {
        PostBuilder.composedBody(record: record)
    }

    /// 항목 체크는 AI 리뷰 탭 맨 위 "리뷰 본문" 상자에서 한다(한 곳에서만 고르게 둔다).
    /// 여기서는 무엇이 들어갔는지만 보여주고, 본문은 아래에서 직접 고칠 수 있다.
    private var composeSection: some View {
        GroupBox("본문 구성") {
            VStack(alignment: .leading, spacing: 4) {
                HStack(spacing: 10) {
                    included("요약", record.bodyIncludesSummary)
                    included("잘된 점 \(record.output.strengths.count)", record.bodyIncludesStrengths)
                    // 인라인으로 옮긴 것은 본문에 안 들어가므로 세지 않는다.
                    included("우려사항 \(record.bodyConcerns.count)", record.bodyIncludesConcerns)
                    included("작성자 질문 \(record.bodyQuestions.count)",
                             record.bodyIncludesQuestions)
                    if !record.orderedClearedNotes.isEmpty {
                        included("확인함 \(record.orderedClearedNotes.count)", record.bodyIncludesCleared)
                    }
                    Spacer()
                }
                Text("무엇을 넣을지는 AI 리뷰 탭 맨 위 '리뷰 본문' 상자에서 체크합니다. 본문은 아래에서 직접 고칠 수 있습니다.")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func included(_ title: String, _ isOn: Bool) -> some View {
        HStack(spacing: 3) {
            Image(systemName: isOn ? "checkmark.circle.fill" : "circle")
                .font(.caption2)
                .foregroundStyle(isOn ? Color.accentColor : Color.secondary)
            Text(title)
                .font(.caption)
                .foregroundStyle(isOn ? Color.primary : Color.secondary)
        }
    }

    private var bodySection: some View {
        GroupBox("총평 (본문)") {
            VStack(alignment: .leading, spacing: 4) {
                TextEditor(text: $body_)
                    .font(.callout)
                    .frame(minHeight: 72)
                    .scrollContentBackground(.hidden)
                    .padding(6)
                    .background(.quaternary.opacity(0.4), in: RoundedRectangle(cornerRadius: 6))
                HStack {
                    Text("\(body_.count)자")
                        .font(.caption2.monospacedDigit())
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("claude[bot] 총평이 이미 있으니 짧게 유지합니다.")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
            }
            .padding(6)
        }
    }

    private var postable: [DraftCommentState] {
        record.comments.filter(\.isPostable)
    }

    private var commentsSection: some View {
        GroupBox("인라인 코멘트 \(postable.count)건") {
            VStack(alignment: .leading, spacing: 6) {
                if postable.isEmpty {
                    Text("인라인 코멘트 없이 본문만 올립니다.")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                }
                ForEach(postable) { state in
                    VStack(alignment: .leading, spacing: 2) {
                        HStack(spacing: 6) {
                            Tag(text: state.comment.severity.label, color: .secondary)
                            Text("\(state.comment.path):\(state.comment.line)")
                                .font(.caption.monospaced())
                                .lineLimit(1)
                        }
                        Text(state.editedBody)
                            .font(.caption)
                            .lineLimit(2)
                            .foregroundStyle(.secondary)
                    }
                }
                let excluded = record.comments.filter { !$0.isPostable }
                if !excluded.isEmpty {
                    Text("제외됨 \(excluded.count)건 (체크 해제 또는 앵커 불명)")
                        .font(.caption2)
                        .foregroundStyle(.orange)
                }
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var payloadSection: some View {
        GroupBox("전송될 내용") {
            VStack(alignment: .leading, spacing: 4) {
                LabeledContent("event") { Text(event.rawValue).font(.caption.monospaced()) }
                LabeledContent("commit_id") { Text(record.headSha).font(.caption.monospaced()).lineLimit(1) }
                LabeledContent("comments") { Text("\(postable.count)").font(.caption.monospaced()) }
                LabeledContent("대상") { Text("\(record.repo.full) #\(record.number)").font(.caption.monospaced()) }
            }
            .padding(6)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private var footer: some View {
        HStack {
            if let errorMessage {
                Text(errorMessage)
                    .font(.caption)
                    .foregroundStyle(.red)
                    .lineLimit(3)
            }
            Spacer()
            Button("취소") { dismiss() }
            // 새 커밋은 막지 않는다(게시할 때 확인 창이 묻는다). 막히는 것은 확인을 못 했거나 닫힌 PR 이다.
            if headBlocked {
                Button("다시 확인") {
                    Task { await verifyHead() }
                }
                .buttonStyle(.borderedProminent)
            } else {
                Button {
                    if event.needsExtraConfirmation {
                        showRequestChangesConfirm = true
                    } else {
                        submit()
                    }
                } label: {
                    if isPosting {
                        ProgressView().controlSize(.small)
                    } else {
                        Text(submitLabel).fixedSize()
                    }
                }
                .buttonStyle(.borderedProminent)
                .disabled(isPosting || !checkedHead || (body_.isEmpty && postable.isEmpty))
                .confirmationDialog("변경 요청으로 게시하면 머지가 막힙니다. 계속할까요?",
                                    isPresented: $showRequestChangesConfirm) {
                    Button("변경 요청으로 게시", role: .destructive) { submit() }
                    Button("취소", role: .cancel) {}
                }
            }
        }
        .padding(16)
    }

    private var submitLabel: String {
        switch event {
        case .comment: return postable.isEmpty ? "코멘트 게시" : "코멘트 \(postable.count)개 게시"
        case .approve: return postable.isEmpty ? "Approve" : "코멘트와 함께 Approve"
        case .requestChanges: return "변경 요청 게시"
        }
    }

    private func verifyHead() async {
        checkedHead = false
        headWarning = nil
        headBlocked = false
        switch await model.checkHead(for: record) {
        case .same:
            break
        case .changed(let sha):
            headWarning = "리뷰한 커밋 이후 새 커밋(\(sha.prefix(7)))이 올라왔습니다. 게시할 때 무엇이 올라왔는지 보여 드리고 한 번 더 묻습니다."
        case .closed(let state):
            headWarning = PostError.closed(number: pr.number, state: state).localizedDescription
            headBlocked = true
        case .unknown(let message):
            // 확인하지 못한 것을 "같음" 으로 취급하면 stale 초안이 그대로 게시된다.
            headWarning = "현재 커밋을 확인하지 못했습니다(\(message)). 확인 전에는 게시할 수 없습니다."
            headBlocked = true
        }
        checkedHead = true
    }

    private func submit(acceptingHead: String? = nil) {
        isPosting = true
        errorMessage = nil
        Task {
            var updated = record
            updated.bodyDraft = body_
            // 줄 코멘트는 지적 카드가 하나씩 바로 단다. 이 창은 본문과 리뷰 종류만 올린다.
            let result = await model.post(record: updated, event: event, body: body_,
                                          includeComments: false,
                                          acceptingHead: acceptingHead)
            isPosting = false
            switch result {
            case .success:
                dismiss()
            case .failure(.headDrift(let drift)):
                headWarning = "리뷰한 커밋 이후 새 커밋(\(drift.shortHead))이 올라왔습니다."
                let subject = HeadDriftPrompt.Subject.review(
                    event: event, label: submitLabel,
                    inlineCount: 0)
                pendingDrift = PendingDrift(drift: drift,
                                            prompt: HeadDriftPrompt.make(drift: drift, subject: subject),
                                            confirm: { submit(acceptingHead: drift.headSha) })
            case .failure(let error):
                errorMessage = error.localizedDescription
                switch error {
                case .headUnknown, .closed, .reviewedCommitGone: headBlocked = true
                default: break
                }
            }
        }
    }
}
