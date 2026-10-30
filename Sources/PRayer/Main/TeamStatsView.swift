import SwiftUI
import PRayerCore

/// 팀 통계 — 레포 하나의 주간·월간 커밋·PR·Approve·코멘트 순위. 메인 창의 상세 칸에 뜬다(툴바 "통계"·⌥⌘S).
///
/// 처음엔 별도 창으로 만들었다가 메인 창 안으로 옮겼다(사용자 선택, 2026-10-28 — 상세 칸 · 목록+상세 전체 ·
/// 레포 줄 전환 중 상세 칸). 목록이 그대로 남아 통계를 보다가 PR 을 누르면 바로 그 PR 로 돌아간다(AppModel+TeamStats).
/// 레포는 레포 줄을 따른다 — 탭 하나를 고르면 그 레포, "전체" 면 머리의 고르기 메뉴로 고른다.
struct TeamStatsView: View {
    @Environment(AppModel.self) private var model

    /// 순위표에 보일 사람 수. 내가 그 밖이면 점선 아래에 내 줄을 붙인다.
    private let visibleRows = 8

    /// 기간·받은 재료는 앱 모델에 있다 — PR 을 보다 돌아와도 다시 받지 않게.
    private var store: TeamStatsStore { model.teamStats }

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            ScrollView {
                VStack(alignment: .leading, spacing: 18) {
                    if store.prTruncated {
                        Label("PR 이 많아 GitHub 검색 상한(1,000건)에서 끊겼습니다. 오래된 기간의 Approve 가 덜 셌을 수 있습니다.",
                              systemImage: "exclamationmark.triangle")
                            .font(.callout)
                            .foregroundStyle(.orange)
                    }
                    myRankCards
                    // 상세 칸 폭에 따라 1~4 줄로 놓는다(목록을 접으면 넓어진다). 위 맞춤 — 가운데면 줄 수가 적은
                    // 칸의 머리가 옆 칸보다 내려앉는다.
                    LazyVGrid(columns: [GridItem(.adaptive(minimum: 300), spacing: 28, alignment: .top)],
                              alignment: .leading, spacing: 22) {
                        ForEach(TeamStatMetric.allCases) { column($0) }
                    }
                }
                .padding(20)
            }
            Divider()
            footer
        }
        .onAppear {
            syncRepo()
            store.load(model: model)
        }
        .onChange(of: stripRepos) {
            syncRepo()
            store.load(model: model)
        }
        .onChange(of: store.repo) { store.load(model: model) }
        .onChange(of: store.kind) { store.load(model: model) }
        .onChange(of: store.offset) { store.load(model: model) }
    }

    /// 레포 줄에서 보이게 둔 레포(하나도 없으면 켜 둔 레포 전부).
    private var stripRepos: [RepoID] {
        let repos = model.settings.enabledRepos.map(\.repo)
        let shown = repos.filter { model.isRepoShown($0) }
        return shown.isEmpty ? repos : shown
    }

    /// 고른 레포가 레포 줄에서 빠졌으면 남은 것 가운데 첫 번째로 옮긴다.
    private func syncRepo() {
        if let repo = store.repo, stripRepos.contains(repo) { return }
        store.repo = stripRepos.first
    }

    private var me: String? { model.githubAccount?.login }

    // MARK: - 머리

    private var header: some View {
        HStack(spacing: 12) {
            Picker("기간", selection: Binding(get: { store.kind }, set: { store.kind = $0 })) {
                ForEach(TeamStatPeriodKind.allCases) { Text($0.label).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .fixedSize()

            HStack(spacing: 2) {
                Button {
                    store.offset -= 1
                } label: {
                    Image(systemName: "chevron.left")
                }
                .disabled(!store.canGoBack)
                .help("이전 \(store.kind == .week ? "주" : "달")")
                periodLabel
                    .frame(minWidth: 170)
                Button {
                    store.offset += 1
                } label: {
                    Image(systemName: "chevron.right")
                }
                .disabled(!store.canGoForward)
                .help("다음 \(store.kind == .week ? "주" : "달")")
            }
            .buttonStyle(.borderless)

            Spacer(minLength: 8)

            // 레포 탭 하나를 골랐으면 고를 것이 없다 — 이름만 둔다.
            if stripRepos.count > 1 {
                Picker("레포", selection: Binding(get: { store.repo }, set: { store.repo = $0 })) {
                    ForEach(stripRepos) { repo in
                        Text(repo.name).tag(Optional(repo))
                    }
                }
                .labelsHidden()
                .fixedSize()
                .help("통계를 볼 레포")
            } else if let repo = store.repo {
                Text(repo.name)
                    .foregroundStyle(.secondary)
            }

            // 지난 기간은 저장해 둔 기록을 보인다. 늦게 푸시한 커밋 같은 것을 다시 반영하려면 이걸로 받는다.
            Button {
                store.load(model: model, force: true)
            } label: {
                if store.isLoading {
                    ProgressView().controlSize(.small)
                } else {
                    Label("새로고침", systemImage: "arrow.clockwise")
                }
            }
            .disabled(store.isLoading || store.repo == nil)
            .help("이 기간을 GitHub 에서 다시 받기")
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 10)
    }

    private var periodLabel: some View {
        HStack(spacing: 6) {
            Text(store.period.label(calendar: store.calendar))
                .font(.body.weight(.medium))
            if store.offset == 0 {
                Text("진행 중")
                    .font(.caption)
                    .foregroundStyle(.secondary)
            }
        }
    }

    // MARK: - 내 순위

    private var myRankCards: some View {
        HStack(spacing: 10) {
            ForEach(TeamStatMetric.allCases) { metric in
                myRankCard(metric)
            }
        }
    }

    private func myRankCard(_ metric: TeamStatMetric) -> some View {
        let rows = store.ranking(metric, in: store.period)
        let mine = me.flatMap { login in rows.first { $0.person == login } }
        let previous = me.flatMap { login in
            store.ranking(metric, in: store.previousPeriod).first { $0.person == login }
        }
        let loaded = store.state(metric) == .loaded
        return VStack(alignment: .leading, spacing: 3) {
            Text("내 \(metric.label)")
                .font(.caption)
                .foregroundStyle(.secondary)
            HStack(alignment: .firstTextBaseline, spacing: 6) {
                Text(loaded ? (mine.map { "\($0.rank)위" } ?? "–") : "…")
                    .font(.title2.weight(.semibold))
                    .monospacedDigit()
                if loaded {
                    Text("\(mine?.count ?? 0)")
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                }
            }
            Text(loaded ? "\(store.kind.previousLabel) \(previous.map { "\($0.rank)위" } ?? "–")" : " ")
                .font(.caption)
                .foregroundStyle(.tertiary)
        }
        .frame(maxWidth: .infinity, alignment: .leading)
        .padding(.horizontal, 12)
        .padding(.vertical, 9)
        .background(.quaternary.opacity(0.5), in: RoundedRectangle(cornerRadius: 8))
    }

    // MARK: - 순위표

    private func column(_ metric: TeamStatMetric) -> some View {
        let rows = store.ranking(metric, in: store.period)
        return VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: metric.symbol)
                    .foregroundStyle(.secondary)
                Text(metric.label)
                    .font(.headline)
                if store.state(metric) == .loaded {
                    Text("\(rows.count)명")
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                }
            }
            .padding(.leading, 6)
            .padding(.bottom, 2)

            switch store.state(metric) {
            case .idle, .loading:
                loadingRows(metric)
            case .failed(let message):
                VStack(alignment: .leading, spacing: 6) {
                    Text(message)
                        .font(.caption)
                        .foregroundStyle(.red)
                        .lineLimit(3)
                    Button("다시 받기") { store.load(model: model, force: true) }
                        .controlSize(.small)
                }
                .padding(6)
            case .loaded:
                rankingRows(rows)
            }

            Text(metric.note)
                .font(.caption)
                .foregroundStyle(.tertiary)
                .padding(.leading, 6)
                .padding(.top, 4)
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func loadingRows(_ metric: TeamStatMetric) -> some View {
        HStack(spacing: 8) {
            ProgressView().controlSize(.small)
            Text(metric == .commits && store.isFirstCommitClone
                 ? "커밋 기록을 처음 받는 중 (한 번만, 10초쯤)"
                 : "받는 중…")
                .font(.callout)
                .foregroundStyle(.secondary)
        }
        .padding(6)
        .frame(minHeight: 60, alignment: .topLeading)
    }

    @ViewBuilder
    private func rankingRows(_ rows: [TeamStatRow]) -> some View {
        if rows.isEmpty {
            Text("이 기간에는 없습니다.")
                .font(.callout)
                .foregroundStyle(.secondary)
                .padding(6)
        } else {
            let top = Array(rows.prefix(visibleRows))
            let maxCount = rows.first?.count ?? 1
            ForEach(top) { row in
                rankRow(row, maxCount: maxCount)
            }
            if let me, !top.contains(where: { $0.person == me }) {
                Divider()
                    .padding(.vertical, 2)
                // 이 기간에 하나도 없으면 순위 없이 0 으로 보인다 — 빠뜨린 게 아니라 0 이라는 걸 알 수 있게.
                rankRow(rows.first { $0.person == me } ?? TeamStatRow(person: me, count: 0, rank: 0),
                        maxCount: maxCount)
            }
        }
    }

    private func rankRow(_ row: TeamStatRow, maxCount: Int) -> some View {
        let isMe = row.person == me
        let fraction = maxCount > 0 ? CGFloat(row.count) / CGFloat(maxCount) : 0
        return HStack(spacing: 8) {
            Text(row.rank > 0 ? "\(row.rank)" : "–")
                .font(.caption)
                .foregroundStyle(isMe ? Color.accentColor : .secondary)
                .monospacedDigit()
                .frame(width: 20, alignment: .trailing)
            // 커밋에서 로그인을 못 찾은 사람(메일 앞부분, 점이 들어 있어 로그인일 수 없다)은 머리글자 칩.
            Avatar(login: row.person.contains(".") ? nil : row.person,
                   name: model.settings.displayName(row.person), size: 18)
            Text(model.settings.displayName(row.person))
                .fontWeight(isMe ? .semibold : .regular)
                .lineLimit(1)
                .truncationMode(.tail)
                .frame(width: 84, alignment: .leading)
                .help(row.person)
            GeometryReader { proxy in
                Capsule()
                    .fill(isMe ? Color.accentColor : Color.secondary.opacity(0.35))
                    .frame(width: max(row.count > 0 ? 4 : 0, proxy.size.width * fraction), height: 4)
                    .frame(maxHeight: .infinity, alignment: .center)
            }
            .frame(height: 16)
            Text("\(row.count)")
                .monospacedDigit()
                .frame(minWidth: 30, alignment: .trailing)
        }
        .foregroundStyle(isMe ? Color.accentColor : .primary)
        .padding(.horizontal, 6)
        .padding(.vertical, 3)
        .background(isMe ? Color.accentColor.opacity(0.12) : .clear, in: RoundedRectangle(cornerRadius: 6))
    }

    // MARK: - 바닥

    private var footer: some View {
        HStack(spacing: 10) {
            Text("봇 계정 제외 · 이 맥의 시간대 기준 · 주는 월요일부터")
                .font(.caption)
                .foregroundStyle(.tertiary)
            Spacer()
            footerStatus
                .font(.caption)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 8)
    }

    private static let koreanTime: Date.FormatStyle = .dateTime.hour().minute().locale(Locale(identifier: "ko_KR"))
    private static let koreanDayTime: Date.FormatStyle = .dateTime.month().day().hour().minute()
        .locale(Locale(identifier: "ko_KR"))

    @ViewBuilder
    private var footerStatus: some View {
        if store.isLoading {
            Text("받는 중…")
        } else if let saved = store.cachedAt {
            Text(store.hasFailure
                 ? "새로고침하지 못해 저장된 기록을 보입니다 (\(saved.formatted(Self.koreanDayTime)))"
                 : "저장된 기록 · \(saved.formatted(Self.koreanDayTime))")
        } else if let updated = store.updatedAt {
            Text("\(updated.formatted(Self.koreanTime)) 갱신")
        }
    }
}
