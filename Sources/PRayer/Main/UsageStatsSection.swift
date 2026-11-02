import SwiftUI
import PRayerCore

/// 설정 › 알림·기타 맨 아래 "PRView 개선 돕기" — 스위치 하나, 설명 한 줄, "보낸 내용 보기".
///
/// GitHub Desktop·Firefox 처럼 간단하게 둔다(2026-11-02 시안). 메인 창 안내 줄은 두지 않는다 — 사용 통계가 화면에
/// 보이는 곳은 여기뿐이다(같은 날 사용자 결정).
/// 크래시 리포트 스위치는 크래시 기록을 읽어 보내는 부분이 생길 때 더한다 — 하는 일 없는 스위치를 먼저 두지 않는다.
struct UsageStatsSection: View {
    @Environment(AppModel.self) private var model
    @State private var showingSent = false

    var body: some View {
        Section("\(AppInfo.displayName) 개선 돕기") {
            Toggle("사용 통계 보내기", isOn: Binding(get: { model.usageStats.enabled },
                                               set: { model.setUsageEnabled($0) }))
            VStack(alignment: .leading, spacing: 4) {
                Group {
                    Text("하루 한 번, 기능별 사용 횟수만 보냅니다. 저장소, PR, 코멘트는 보내지 않습니다.")
                    if AppModel.usageConfig == nil {
                        Text("이 빌드는 보내지 않습니다(개발 빌드).")
                    }
                }
                .foregroundStyle(.secondary)
                // 설명 글의 회색을 받지 않게 따로 둔다 — 같이 칠하면 링크가 글처럼 보여 누를 수 있는 줄 모른다.
                Button("보낸 내용 보기") { showingSent = true }
                    .buttonStyle(.link)
            }
            .font(.caption)
        }
        .sheet(isPresented: $showingSent) {
            UsageSentSheet(sent: model.usageStats.lastSent)
        }
    }
}

/// 마지막으로 보낸 본문을 글자 그대로 보인다. 무엇이 나가는지 말보다 본문이 정확하다.
private struct UsageSentSheet: View {
    let sent: UsageStats.Sent?
    @Environment(\.dismiss) private var dismiss
    /// 앱의 기본 언어가 영어라 그냥 formatted() 하면 "Nov 2, 2026 at 9:40 AM" 이 된다(TeamStatsView 와 같은 꼴).
    private static let koreanDayTime: Date.FormatStyle = .dateTime.month().day().hour().minute()
        .locale(Locale(identifier: "ko_KR"))

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("보낸 내용").font(.headline)
            if let sent {
                Text("\(sent.day) 사용분 · \(sent.sentAt.formatted(Self.koreanDayTime))에 보냄")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                ScrollView {
                    Text(sent.body)
                        .font(.system(.caption, design: .monospaced))
                        .textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(minHeight: 260)
            } else {
                Text("아직 보낸 적이 없습니다. 하루치를 모아 다음 날 보냅니다.")
                    .foregroundStyle(.secondary)
            }
            HStack {
                Spacer()
                Button("닫기") { dismiss() }
                    .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
