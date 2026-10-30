import SwiftUI
import PRayerCore

/// AI 리뷰 탭 왼쪽 — GitHub 에 올라갈 리뷰 본문을 GitHub 리뷰 코멘트 상자 모양으로 보여 준다.
///
/// 아바타 + "<내 아이디> commented" 머리 줄 + 본문. 본문의 절(요약·잘된 점)은 오른쪽 코드 코멘트처럼
/// **바로 고치는 입력칸**이고, 넣을지는 칸 바로 위 "☑ 요약" 줄에서 고르고, 고친 칸은 그 줄의 "초기화" 로 되돌린다. "수정" 을 눌러야 고칠 수 있던 것과
/// 머리 줄 아래 칩 한 줄로 넣고 빼던 것은 둘 다 덜 직관적이었다(사용자 피드백, 2026-10-20).
/// 끈 절은 지우지 않고 흐리게 남긴다 — 무엇을 뺐는지, 켜면 어떻게 될지 보이게.
struct ReviewBodyCard: View {
    @Environment(AppModel.self) private var model
    let pr: PullRequestInfo
    let record: ReviewRecord
    let binding: Binding<ReviewRecord>
    /// GitHub 에 올리는 중이면 잠근다. 올리는 사이에 고친 글은 이미 떠난 본문에 들어가지 않는다.
    var isPosting = false
    /// 담은 줄의 자리를 적어 둘 곳 — 체크를 끈 줄 고스트의 출발점이자 체크한 카드 고스트의 도착점(`BasketFlight`).
    var basketFrames: BasketFrames? = nil
    /// 고스트가 날아오는 동안 숨겨 둘 담은 줄. 내려앉으면 nil 이 되어 나타난다.
    var hiddenIssueKey: String? = nil
    /// 변경 파일 탭에서 돌아왔을 때 잠깐 칠할 줄(`ReviewIssue.key`).
    var flashKey: String? = nil
    /// 담은 줄의 체크를 끔 — 오른쪽 코드 코멘트 제자리로 돌려보낸다. nil 이면 바로 뺀다.
    var onUnbasket: ((ReviewIssue) -> Void)? = nil
    /// 담은 줄의 자리를 누름 — 변경 파일 탭에서 그 줄을 연다(카드의 "코드에서 보기" 와 같다).
    var onJumpToCode: (ReviewIssue) -> Void = { _ in }

    /// "초기화" 를 누를 때마다 올린다. 입력칸은 이 값이나 PR 이 바뀔 때만 기록의 글로 다시 채운다 —
    /// "고쳤나" 여부를 키로 쓰면 처음 친 글자에서 칸을 다시 채워 끝 빈칸이 지워졌다.
    @State private var restoreToken = 0

    private var summary: String { record.effectiveSummary }
    private var strengths: [String] { record.effectiveStrengths }
    private var clearedNotes: [String] { record.orderedClearedNotes }
    private var composed: String { PostBuilder.composedBody(record: record) }
    private var login: String { model.githubAccount?.login ?? "나" }

    /// 옛 기록에서 본문에 켜 둔 우려사항·질문. 게시 본문(`PostBuilder.composedBody`)과 같은 모양으로 그린다.
    private var pickedLines: [String] {
        var lines: [String] = []
        if record.bodyIncludesConcerns {
            lines += record.bodyConcerns.map { "- [\($0.severity.label)] \(record.text(for: $0))" }
        }
        if record.bodyIncludesQuestions {
            lines += record.bodyQuestions.map { "- \(record.text(for: $0))" }
        }
        return lines
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            // 아바타는 머리 줄 안 이름 앞에 둔다. 상자 밖에 두면 왼쪽으로 튀어나와 오른쪽 패널·아래 게시 줄과
            // 왼쪽 선이 어긋났다(사용자 요청으로 안쪽에 넣어 봄, 2026-10-20).
            ReviewPanelBox {
                Avatar(login: login, name: model.settings.displayName(login), size: 20)
                Text(login)
                    .font(model.fonts.ui(weight: .semibold))
                // 내 PR 은 올리지 않으므로 "commented" 를 붙이지 않는다 — GitHub 에 단 글처럼 읽히지 않게.
                Text(record.isPosted ? "commented · 게시 완료" : (pr.viewerDidAuthor ? "리뷰 본문" : "commented · 리뷰 본문"))
                    .font(.callout)
                    .foregroundStyle(record.isPosted ? PostedStatusLabel.text : .secondary)
                Spacer()
                if isPosting {
                    Label("올리는 동안은 고칠 수 없어요", systemImage: "lock")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .fixedSize()
                } else {
                    Text(composed.isEmpty ? "본문 없음" : "\(composed.count)자")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.secondary)
                }
            } content: {
                VStack(alignment: .leading, spacing: 14) {
                    blocks
                }
                .disabled(isPosting)
                .opacity(isPosting ? 0.6 : 1)
                .padding(12)
                .frame(maxWidth: .infinity, alignment: .leading)
                basketSection
            }
        }
    }

    /// 오른쪽 카드에서 "리뷰에 담기" 한 줄 코멘트 — 이 리뷰를 게시할 때 함께 달린다. 본문과 같은 상자 안 맨 아래에 두어
    /// "이 상자가 곧 올라갈 리뷰" 라는 읽기를 지킨다. 담은 게 없으면 줄째 없다.
    @ViewBuilder
    private var basketSection: some View {
        let issues = record.isPosted || pr.viewerDidAuthor ? [] : record.basketIssues
        if !issues.isEmpty {
            Divider()
            VStack(alignment: .leading, spacing: 6) {
                HStack(spacing: 6) {
                    Image(systemName: "basket")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                    Text("담은 줄 코멘트")
                        .font(model.fonts.ui(weight: .semibold))
                    Text("\(issues.count)")
                        .font(.callout)
                        .foregroundStyle(.secondary)
                    Spacer()
                    Text("이 리뷰와 함께 코드 옆에 달려요")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
                ForEach(issues) { issue in
                    Divider()
                    basketRow(issue)
                        .id(ReviewRowID.of(issue.key))
                        .modifier(FlashHighlight(isOn: flashKey == issue.key))
                        .recordBasketFrame { basketFrames?.rows[issue.key] = $0 }
                        // 날아오는 고스트가 내려앉을 때까지 숨겨 둔다 — 둘이 겹쳐 보이지 않게.
                        .opacity(hiddenIssueKey == issue.key ? 0 : 1)
                }
            }
            .disabled(isPosting)
            .opacity(isPosting ? 0.6 : 1)
            .padding(12)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    /// 담은 줄 하나 — 머리 줄(☑ · 중요도 · 자리)과 그 아래 달 글. 카드가 통째로 넘어온 것이라 글은 여기서 그대로
    /// 고친다(오른쪽 카드와 같은 글). 코드 조각은 뺀다 — 자리를 누르면 변경 파일 탭에서 그 줄을 본다.
    /// 맨 앞 체크를 끄면 오른쪽 코드 코멘트 제자리로 돌아간다(카드의 "☐ 리뷰에 담기" 와 같은 체크).
    private func basketRow(_ issue: ReviewIssue) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 8) {
                Toggle(isOn: Binding(get: { true }, set: { isOn in
                    guard !isOn else { return }
                    if let onUnbasket { onUnbasket(issue) } else { model.setInBasket(false, issue: issue, pr: pr) }
                })) {
                    EmptyView()
                }
                .toggleStyle(.checkbox)
                .controlSize(.small)
                .labelsHidden()
                .help("체크를 끄면 담은 목록에서 빠져 오른쪽 코드 코멘트 제자리로 돌아갑니다. 고친 글은 그대로 남습니다.")
                Text(issue.importance.label)
                    .font(.caption.weight(.semibold))
                    .foregroundStyle(importanceColor(issue.importance))
                Button {
                    onJumpToCode(issue)
                } label: {
                    Text(issue.place ?? "자리 없음")
                        .font(.caption.monospaced())
                        .lineLimit(1)
                        .truncationMode(.head)
                }
                .buttonStyle(.link)
                .help("변경 파일 탭에서 이 줄을 봅니다")
                Spacer(minLength: 8)
            }
            GrowingTextEditor(text: Binding(get: { model.issueText(pr: pr, issue: issue) },
                                            set: { model.setIssueText($0, pr: pr, issue: issue) }),
                              minHeight: 28)
                .reviewFieldBox()
        }
    }

    /// 실제로 올라갈 글. 순서는 `PostBuilder.composedBody` 가 이어 붙이는 순서와 같아야 한다.
    @ViewBuilder
    private var blocks: some View {
        if composed.isEmpty {
            Text("켜 둔 절이 없어 본문 없이 올라갑니다 — 게시하면 리뷰 종류(Approve 등)만 남습니다.")
                .font(.caption)
                .foregroundStyle(.orange)
        }
        if !record.output.summaryKo.isEmpty {
            part(title: "요약", isOn: record.bodyIncludesSummary, isEdited: record.isSummaryEdited,
                 toggle: { mutate { $0.includeSummary = !$0.bodyIncludesSummary } },
                 restore: {
                     mutate { $0.setSummaryEdit(nil) }
                     restoreToken += 1
                 }) {
                LiveTextField(source: summary, resetKey: "\(record.id)|summary|\(restoreToken)",
                              minHeight: 40, isEditable: !record.isPosted) { text in
                    mutate { $0.setSummaryEdit(text) }
                }
            }
        }
        if !record.output.strengths.isEmpty {
            part(title: "잘된 점 \(strengths.count)", isOn: record.bodyIncludesStrengths, isEdited: record.isStrengthsEdited,
                 toggle: { mutate { $0.includeStrengths.toggle() } },
                 restore: {
                     mutate { $0.setStrengthsEdit(nil) }
                     restoreToken += 1
                 }) {
                // 한 줄이 항목 하나. 본문에는 줄마다 "- " 로 붙는다.
                LiveTextField(source: ReviewTextEdits.editorText(strengths: strengths),
                              resetKey: "\(record.id)|strengths|\(restoreToken)",
                              minHeight: 20, isEditable: !record.isPosted) { text in
                    mutate { $0.setStrengthsEdit(ReviewTextEdits.strengths(fromEditorText: text)) }
                }
            }
        }
        // 옛 기록에만 생긴다 — 지금은 우려사항·질문을 오른쪽 코드 코멘트로 단다. 끄면 다시 켤 곳이 없어 줄째 사라진다.
        if !pickedLines.isEmpty {
            part(title: "우려사항·질문 \(pickedLines.count)", isOn: true, isEdited: false,
                 toggle: {
                     mutate {
                         $0.includeConcerns = false
                         $0.includeQuestions = false
                         if $0.bodyIssueKeys != nil { $0.bodyIssueKeys = [] }
                     }
                 }, restore: nil) {
                MarkdownText(text: pickedLines.joined(separator: "\n"))
            }
        }
        if !clearedNotes.isEmpty {
            part(title: "\(PostBuilder.clearedHeading) \(clearedNotes.count)", isOn: record.bodyIncludesCleared,
                 isEdited: false,
                 toggle: { mutate { $0.includeCleared = !$0.bodyIncludesCleared } }, restore: nil) {
                MarkdownText(text: PostBuilder.bulletList(clearedNotes))
            }
        }
    }

    /// 본문의 절 하나 — 위에 "☑ 제목" 줄, 아래에 내용. 끄면 내용만 흐려진다(체크박스는 다시 켜는 손잡이라 그대로).
    private func part<Content: View>(title: String, isOn: Bool, isEdited: Bool,
                                     toggle: @escaping () -> Void, restore: (() -> Void)?,
                                     @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Toggle(isOn: Binding(get: { isOn }, set: { _ in toggle() })) {
                    Text(title)
                        .font(model.fonts.ui(weight: .semibold))
                }
                .toggleStyle(.checkbox)
                .disabled(record.isPosted)
                Spacer()
                if !isOn {
                    Text("올라가지 않음")
                        .font(.caption2)
                        .foregroundStyle(.secondary)
                }
                if isEdited, let restore, !record.isPosted {
                    ResetTextButton(action: restore)
                }
            }
            content()
                .opacity(isOn ? 1 : offOpacity)
        }
    }

    /// 끈 절의 투명도. 읽을 수는 있되 올라가는 글과는 한눈에 갈려야 한다.
    private var offOpacity: Double { 0.3 }

    /// 기록을 고쳐 저장한다(저장은 `AppModel.update` 가 모아서 한다).
    private func mutate(_ change: (inout ReviewRecord) -> Void) {
        var updated = binding.wrappedValue
        change(&updated)
        binding.wrappedValue = updated
    }
}

/// 두 패널 위 전체 폭의 Approve 안내 한 줄 — 머지를 막는 이슈가 있으면 붉은 띠, 없으면 초록 선.
///
/// 게시 버튼은 막는 이슈가 있으면 이미 '코멘트만' 으로 잡혀 있지만, 왜 그런지는 화면 어디에도 없었다. 확인 창이
/// 아니라 늘 보이는 줄로 둔다(사용자 결정, 2026-10-20). 문구는 사용자가 고른 "머지를 막는 이슈" 와, 하지 말라가
/// 아니라 언제 무엇을 하면 되는지("다 고쳐지면 아래 코멘트로 Approve") 로 쓴다.
/// 중요도 '필수' 를 막는 이슈로 센다(같은 사안의 우려사항+초안은 하나로).
struct ApprovalHint: View {
    let pr: PullRequestInfo
    let record: ReviewRecord
    /// "머지를 막는 이슈 N개" 를 누르면 오른쪽의 그 카드로 간다.
    var onShowBlockers: (() -> Void)? = nil

    /// 같은 사안의 우려사항과 초안은 하나로 센다(지적 목록 기준).
    private var blockers: Int { record.issues.filter(\.isBlocking).count }

    var body: some View {
        // 내 PR 은 Approve 할 수 없어 "Approve 하세요" 대신 고칠 일을 말한다(시안 1-B, 2026-10-29 사용자 결정).
        // 예전에는 줄을 통째로 숨겨 막는 이슈가 몇 개인지도 안 보였다.
        if pr.viewerDidAuthor {
            if blockers > 0 {
                blockerBox(advice: "고쳐서 새 커밋을 올리세요")
            } else {
                line(icon: "checkmark.circle", title: "머지를 막는 이슈 없음", detail: nil, color: .green)
            }
        } else if pr.viewerApprovedCurrentHead {
            line(icon: "checkmark.seal", title: "이미 Approve 함", detail: "이 커밋은 Approve 했습니다", color: .secondary)
        } else if blockers > 0 {
            blockerBox(advice: "다 고쳐지면 아래 코멘트로 Approve 하세요")
        } else {
            line(icon: "checkmark.circle", title: "머지를 막는 이슈 없음", detail: "Approve 해도 괜찮습니다", color: .green)
        }
    }

    /// 막는 이슈가 있을 때의 빨간 상자. 뒷말만 남의 PR(Approve 안내)과 내 PR(고칠 일)이 다르다.
    private func blockerBox(advice: String) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: "exclamationmark.octagon")
            // 숫자를 누르면 그 카드로 — 어느 것이 막는 이슈인지 바로 찾게(사용자 피드백).
            Button {
                onShowBlockers?()
            } label: {
                Text("머지를 막는 이슈 \(blockers)개")
                    .fontWeight(.semibold)
                    .underline()
            }
            .buttonStyle(.plain)
            .help("오른쪽 코드 코멘트에서 머지를 막는 이슈로 갑니다")
            Text("— \(advice)")
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .font(.callout)
        .foregroundStyle(Color.red)
        .padding(.horizontal, 10)
        .padding(.vertical, 7)
        .background(Color.red.opacity(0.08), in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Color.red.opacity(0.45)))
    }

    /// 왼쪽 선만 있는 조용한 줄. 늘 떠 있어도 거슬리지 않게. 뒷말이 없으면 제목만.
    private func line(icon: String, title: String, detail: String?, color: Color) -> some View {
        HStack(alignment: .firstTextBaseline, spacing: 6) {
            Image(systemName: icon)
            (Text(title).fontWeight(.semibold) + Text(detail.map { " — \($0)" } ?? ""))
                .fixedSize(horizontal: false, vertical: true)
            Spacer(minLength: 0)
        }
        .font(.callout)
        .foregroundStyle(color)
        .padding(.leading, 10)
        .padding(.vertical, 3)
        .overlay(alignment: .leading) {
            Rectangle().fill(color.opacity(0.7)).frame(width: 3)
        }
    }
}

/// 바로 고치는 입력칸. 오른쪽 코드 코멘트의 말풍선 칸과 같은 모양이다.
///
/// 친 글은 이 칸이 들고 있고 바뀔 때마다 `onCommit` 으로 넘긴다. 기록에서 다시 읽어 칸을 채우면, 잘된 점처럼
/// 줄 단위로 다시 쪼개 저장하는 글은 빈 줄을 치는 순간 지워져 커서가 튄다. 그래서 `resetKey` 가 바뀔 때
/// (다른 PR, "초기화") 만 기록의 글로 다시 채운다.
private struct LiveTextField: View {
    let source: String
    let resetKey: String
    var minHeight: CGFloat = 52
    var isEditable = true
    let onCommit: (String) -> Void

    @State private var text = ""
    @State private var loadedKey: String?

    var body: some View {
        GrowingTextEditor(text: $text, minHeight: minHeight)
            .reviewFieldBox()
            .disabled(!isEditable)
            .onAppear(perform: load)
            .onChange(of: resetKey) { load() }
            .onChange(of: text) { _, new in
                guard loadedKey == resetKey, new != source else { return }
                onCommit(new)
            }
    }

    private func load() {
        text = source
        loadedKey = resetKey
    }
}

/// 변경 파일 탭에서 돌아온 행을 잠깐 칠한다. 칠한 자리가 행보다 조금 넓어야 글자에 붙어 보이지 않는다.
struct FlashHighlight: ViewModifier {
    let isOn: Bool
    /// 칠한 자리를 행보다 얼마나 넓게. 글자 줄은 조금 넓어야 글자에 붙어 보이지 않고, 칸 경계가 있는 카드(코드 코멘트)는
    /// 0 이어야 한다 — 넓히면 위 칸(묶음 머리 '머지를 막는 이슈')까지 노랗게 넘어갔다(사용자 제보).
    var bleed: CGFloat = 5

    func body(content: Content) -> some View {
        content
            .background {
                RoundedRectangle(cornerRadius: bleed > 0 ? 6 : 0)
                    .fill(Color.yellow.opacity(isOn ? 0.28 : 0))
                    .padding(-bleed)
                    .allowsHitTesting(false)
            }
    }
}
