import SwiftUI
import AppKit
import PRayerCore

/// 이미지 파일은 코드로 보여 봐야 읽을 수 없다. 실제 그림과 크기·용량을 보여준다.
struct ImageDiffView: View {
    @Environment(AppModel.self) private var model
    let file: DiffFile
    let pr: PullRequestInfo

    @State private var asset: LoadedImage?
    @State private var error: String?
    @State private var isLoading = false
    @State private var showsSource = false

    struct LoadedImage {
        var image: NSImage
        var byteCount: Int
        var isVector: Bool
        var source: String?

        /// 벡터는 픽셀이 없다. 포인트 크기를 쓴다.
        var dimensionText: String {
            if let rep = image.representations.first, rep.pixelsWide > 0 {
                return "\(rep.pixelsWide) × \(rep.pixelsHigh) px"
            }
            let size = image.size
            return String(format: "%.0f × %.0f pt (벡터)", size.width, size.height)
        }
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            facts
            Divider()
            content
        }
        .task(id: file.path) { await load() }
    }

    private var facts: some View {
        HStack(spacing: 10) {
            Tag(text: file.isNew ? "추가됨" : (file.isDeleted ? "삭제됨" : "변경됨"),
                color: file.isNew ? .green : (file.isDeleted ? .red : .orange))
            if let asset {
                Text(asset.dimensionText)
                    .font(model.fonts.ui(delta: -2).monospacedDigit())
                Text(ImageFiles.byteSizeText(asset.byteCount))
                    .font(model.fonts.ui(delta: -2).monospacedDigit())
                    .foregroundStyle(.secondary)
            }
            Spacer()
            if asset?.source != nil {
                Toggle("소스 보기", isOn: $showsSource)
                    .toggleStyle(.button)
                    .controlSize(.small)
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 7)
    }

    @ViewBuilder
    private var content: some View {
        if isLoading {
            ProgressView("이미지를 불러오는 중")
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        } else if let error {
            ContentUnavailableView {
                Label("이미지를 불러오지 못했습니다", systemImage: "photo.badge.exclamationmark")
            } description: {
                Text(error)
            } actions: {
                Button("다시 시도") { Task { await load(force: true) } }
            }
        } else if let asset {
            if showsSource, let source = asset.source {
                ScrollView {
                    SwiftCodeText(code: source,
                                  profile: CodeSyntax.markup,
                                  font: model.fonts.code())
                        .padding(12)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            } else {
                ScrollView([.horizontal, .vertical]) {
                    Image(nsImage: asset.image)
                        .resizable()
                        .interpolation(.high)
                        .aspectRatio(contentMode: .fit)
                        .frame(maxWidth: 720, maxHeight: 720)
                        .padding(20)
                        // 투명 배경 이미지가 안 보이지 않도록 체크무늬 대신 옅은 판을 깐다.
                        .background(Color(nsColor: .textBackgroundColor),
                                    in: RoundedRectangle(cornerRadius: 8))
                        .overlay(RoundedRectangle(cornerRadius: 8).stroke(.separator, lineWidth: 0.5))
                        .padding(16)
                }
            }
        } else {
            ContentUnavailableView("미리보기가 없습니다", systemImage: "photo")
        }
    }

    private func load(force: Bool = false) async {
        guard asset == nil || force else { return }
        isLoading = true
        error = nil
        defer { isLoading = false }

        // SVG 가 추가된 경우는 diff 만으로 내용을 복원할 수 있다. API 를 부르지 않는다.
        if let text = ImageFiles.reconstructedText(from: file), let image = NSImage(data: Data(text.utf8)) {
            asset = LoadedImage(image: image, byteCount: text.utf8.count, isVector: true, source: text)
            return
        }
        // 삭제된 파일은 base 커밋에서, 나머지는 head 커밋에서 가져온다.
        let ref = file.isDeleted ? pr.baseRefName : pr.headRefOid
        do {
            let data = try await model.github.fileContent(repo: pr.repo, path: file.path, ref: ref)
            guard let image = NSImage(data: data) else {
                error = "이 형식은 미리보기를 만들 수 없습니다 (\(ImageFiles.byteSizeText(data.count)))."
                return
            }
            let source = ImageFiles.isVector(file.path) ? String(data: data, encoding: .utf8) : nil
            asset = LoadedImage(image: image, byteCount: data.count,
                                isVector: ImageFiles.isVector(file.path), source: source)
        } catch {
            self.error = error.localizedDescription
        }
    }
}
