import SwiftUI
import AppKit
import PRayerCore

/// 문제 기록 창. 앱이 손본 리뷰 결과와 실행 중 실패를 종류별로 모아 보여 준다.
///
/// 경고가 뜨면 무슨 뜻인지, 얼마나 자주 나는지 알 길이 없었다(사용자 요청 — 모아서 고치고 싶다).
/// 이 맥에만 쌓인다. "문제 보고 복사" 는 종류·횟수·버전만 담아, 팀원이 슬랙 등으로 보내 줄 수 있게 한다.
struct ProblemsView: View {
    @Environment(AppModel.self) private var model
    @State private var entries: [ProblemEntry] = []
    @State private var showClearConfirm = false
    @State private var showReport = false
    @State private var copied = false

    private let days = 30

    private struct Row: Identifiable {
        let kind: ProblemKind
        let count: Int
        let last: Date
        let lastDetail: String?
        var id: String { kind.rawValue }
    }

    private var recent: [ProblemEntry] {
        let cutoff = Date().addingTimeInterval(-Double(days) * 86_400)
        return entries.filter { $0.at >= cutoff }
    }

    private func rows(reviewCheck: Bool) -> [Row] {
        Dictionary(grouping: recent.filter { $0.kind.isReviewCheck == reviewCheck }, by: \.kind)
            .compactMap { kind, hits -> Row? in
                guard let latest = hits.max(by: { $0.at < $1.at }) else { return nil }
                return Row(kind: kind, count: hits.count, last: latest.at, lastDetail: latest.detail)
            }
            .sorted { $0.count != $1.count ? $0.count > $1.count : $0.last > $1.last }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack(spacing: 8) {
                Text("최근 \(days)일 · \(recent.count)건")
                    .font(.headline)
                Spacer()
                Button(copied ? "복사했습니다" : "문제 보고 복사") {
                    model.copyProblemReport(days: days)
                    copied = true
                    Task { @MainActor in
                        try? await Task.sleep(for: .seconds(2))
                        copied = false
                    }
                }
                .help("종류·횟수·앱 버전만 담은 글을 복사합니다. 슬랙이나 메신저에 붙여 넣어 보내 주세요.")
                Button("기록 지우기", role: .destructive) { showClearConfirm = true }
                    .disabled(entries.isEmpty)
            }
            Text("아래 설명(파일 이름·PR 번호)은 이 맥에서만 봅니다. 보고에는 종류·횟수·앱 버전만 들어갑니다.")
                .font(.caption)
                .foregroundStyle(.secondary)

            if recent.isEmpty {
                ContentUnavailableView("최근 \(days)일 동안 기록된 문제가 없습니다", systemImage: "checkmark.seal")
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            } else {
                List {
                    section("리뷰 결과 검사 — 모델 출력을 앱이 손본 것", rows: rows(reviewCheck: true))
                    section("실행 중 실패", rows: rows(reviewCheck: false))
                }
            }

            DisclosureGroup("보고에 담기는 내용 미리 보기", isExpanded: $showReport) {
                ScrollView {
                    Text(model.problemReportText(days: days))
                        .font(.caption.monospaced())
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 160)
            }
            .font(.caption)
        }
        .padding(16)
        .frame(minWidth: 540, minHeight: 440)
        .onAppear(perform: reload)
        // 기록은 어느 스레드에서든 쌓인다. 창이 열려 있으면 바로 다시 읽는다.
        .onReceive(NotificationCenter.default.publisher(for: ProblemLog.didChangeNotification)
            .receive(on: RunLoop.main)) { _ in reload() }
        .confirmationDialog("문제 기록을 지울까요?", isPresented: $showClearConfirm) {
            Button("지우기", role: .destructive) { ProblemLog.shared.clear() }
            Button("취소", role: .cancel) {}
        } message: {
            Text("이 맥에 모아 둔 기록만 지웁니다. 초안과 앱 로그는 그대로입니다.")
        }
    }

    @ViewBuilder
    private func section(_ title: String, rows: [Row]) -> some View {
        if !rows.isEmpty {
            Section(title) {
                ForEach(rows) { row in
                    VStack(alignment: .leading, spacing: 3) {
                        HStack(spacing: 8) {
                            Text(row.kind.label)
                            Spacer()
                            Text("\(row.count)회")
                                .monospacedDigit()
                            Text("마지막 \(RelativeTime.ago(row.last))")
                                .font(.caption)
                                .foregroundStyle(.secondary)
                        }
                        if let detail = row.lastDetail, !detail.isEmpty {
                            Text(detail)
                                .font(.caption)
                                .foregroundStyle(.secondary)
                                .lineLimit(2)
                                .textSelection(.enabled)
                        }
                    }
                    .padding(.vertical, 2)
                }
            }
        }
    }

    private func reload() {
        entries = ProblemLog.shared.entries()
    }
}
