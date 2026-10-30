import SwiftUI
import PRayerCore

/// 전체 리뷰를 처음 누를 때 한 번 뜨는 창 — "현재 PR의 스냅샷을 클론합니다".
///
/// 클론은 몇십 초 걸리고 디스크를 쓴다. 사용자가 알고 고르게 묻는다(사용자 결정 — 문구·모양은 시안으로 정했다).
/// 무거운 클론이 아니라는 걸 숫자로 보인다: 받을 코드 크기와, 다 받지 않는 레포 전체 크기. 크기는 창을 띄운 뒤
/// GitHub 에 물어 채운다(1초 남짓). 못 물으면 그 두 줄만 빼고 그대로 쓴다 — 크기 때문에 리뷰를 막지 않는다.
struct SnapshotCloneConfirm: View {
    @Environment(AppModel.self) private var model
    @Environment(\.dismiss) private var dismiss
    let request: PendingSnapshotClone

    private enum SizeState: Equatable {
        case loading
        case loaded(code: CodeSize, repoBytes: Int64?)
        case unavailable
    }

    @State private var size: SizeState = .loading

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(alignment: .top, spacing: 12) {
                Image(systemName: "arrow.triangle.branch")
                    .font(.system(size: 20))
                    .foregroundStyle(Color.accentColor)
                    .frame(width: 40, height: 40)
                    .background(Color.accentColor.opacity(0.12), in: RoundedRectangle(cornerRadius: 9))
                VStack(alignment: .leading, spacing: 8) {
                    Text("현재 PR의 스냅샷을 클론합니다")
                        .font(.headline)
                    if let missing = request.missingLinkedPath {
                        Text("전에 연결한 클론 폴더(\((missing as NSString).abbreviatingWithTildeInPath))를 찾을 수 없어서, 리뷰 전용으로 새로 클론합니다.")
                            .font(.callout)
                            .foregroundStyle(.orange)
                            .fixedSize(horizontal: false, vertical: true)
                    }
                    Text("전체 리뷰는 프로젝트 전체를 읽어서, 처음 한 번 클론이 필요합니다. 다음 리뷰부터는 이미 받은 코드와 달라진 파일만 받아서 대개 몇 초면 됩니다.")
                        .font(.callout)
                        .fixedSize(horizontal: false, vertical: true)
                    sizeBox
                    Text("\(AppInfo.displayName) 리뷰 전용 폴더(\((ReviewClone.directory.path as NSString).abbreviatingWithTildeInPath))에 둡니다.")
                        .font(.caption)
                        .foregroundStyle(.secondary)
                }
            }
            HStack {
                Spacer()
                Button("취소", role: .cancel) {
                    model.cancelPendingSnapshotClone()
                    dismiss()
                }
                .keyboardShortcut(.cancelAction)
                Button("클론하고 리뷰 시작") {
                    model.confirmPendingSnapshotClone()
                    dismiss()
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 440)
        .task { await loadSize() }
    }

    @ViewBuilder
    private var sizeBox: some View {
        switch size {
        case .loading:
            sizeLines(main: "용량 확인 중…", sub: nil, muted: true)
        case .loaded(let code, let repoBytes):
            sizeLines(main: "받을 코드 약 \(ByteSizeText.short(code.bytes))\(code.truncated ? " 이상" : "") · 파일 \(code.files.formatted())개",
                      sub: repoBytes.map { "레포 전체(\(ByteSizeText.short($0)))를 다 받지는 않습니다." },
                      muted: false)
        case .unavailable:
            EmptyView()
        }
    }

    private func sizeLines(main: String, sub: String?, muted: Bool) -> some View {
        VStack(alignment: .leading, spacing: 3) {
            Label(main, systemImage: "internaldrive")
                .font(.callout.monospacedDigit())
                .foregroundStyle(muted ? Color.secondary : Color.primary)
            if let sub {
                Text(sub)
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .padding(.leading, 24)
            }
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.secondary.opacity(0.08), in: RoundedRectangle(cornerRadius: 6))
    }

    private func loadSize() async {
        let github = model.github
        let repo = request.pr.repo
        let head = request.pr.headRefOid
        async let code = try? github.codeSize(repo, ref: head)
        async let total = try? github.repositorySize(repo)
        let (codeSize, repoBytes) = await (code, total)
        if let codeSize {
            size = .loaded(code: codeSize, repoBytes: repoBytes)
        } else {
            size = .unavailable
        }
    }
}
