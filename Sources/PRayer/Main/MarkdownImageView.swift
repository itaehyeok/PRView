import SwiftUI
import PRayerCore

/// 코멘트 그림이 들어 있는 PR. 비공개 레포의 첨부 그림은 그 PR 의 본문·대화를 HTML 로 받아야
/// 서명 주소를 얻는다(GitHubAttachment). 상세 화면이 환경 값으로 내려 준다.
struct MarkdownImagePR: Hashable {
    let repo: RepoID
    let number: Int
}

private struct MarkdownImagePRKey: EnvironmentKey {
    static let defaultValue: MarkdownImagePR? = nil
}

extension EnvironmentValues {
    var markdownImagePR: MarkdownImagePR? {
        get { self[MarkdownImagePRKey.self] }
        set { self[MarkdownImagePRKey.self] = newValue }
    }
}

/// 그림만 있는 줄. 여럿이면 GitHub 처럼 옆으로 나란히 놓고, 칸이 모자라면 같이 줄어든다.
struct MarkdownImagesView: View {
    let images: [MarkdownImage]

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            ForEach(images.indices, id: \.self) { index in
                MarkdownImageView(image: images[index])
            }
        }
        .frame(maxWidth: .infinity, alignment: .leading)
    }
}

/// 그림 하나. 누르면 브라우저에서 연다(그림을 감싼 링크가 있으면 그 링크).
struct MarkdownImageView: View {
    @Environment(AppModel.self) private var model
    @Environment(\.markdownImagePR) private var pr
    let image: MarkdownImage

    @State private var loaded: NSImage?
    @State private var failed = false

    /// 세로로 긴 스크린샷이 대화를 통째로 밀어내지 않게 높이는 여기서 멈춘다(폭은 비율대로 준다).
    private static let maxHeight: CGFloat = 560

    var body: some View {
        Group {
            if let loaded {
                Image(nsImage: loaded)
                    .resizable()
                    .interpolation(.high)
                    .aspectRatio(contentMode: .fit)
                    .frame(maxWidth: displayWidth(of: loaded), maxHeight: Self.maxHeight, alignment: .topLeading)
                    .accessibilityLabel(image.alt)
            } else {
                placeholder
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { NSWorkspace.shared.open(image.link ?? image.url) }
        .help(image.alt.isEmpty ? "브라우저에서 열기" : "\(image.alt) — 브라우저에서 열기")
        .task(id: image.url) {
            if let cached = CommentImages.shared.cached(image.url) {
                loaded = cached
                return
            }
            loaded = await CommentImages.shared.load(image.url, pr: pr, github: model.github)
            failed = loaded == nil
        }
    }

    /// GitHub 은 그림을 픽셀 수만큼(CSS px) 그리고 칸 폭에서 줄인다. `width` 속성이 있으면 그 폭.
    /// 점(pt) 크기로 재면 Retina 캡처(144dpi)가 절반으로 작아져 GitHub 과 달라진다.
    private func displayWidth(of nsImage: NSImage) -> CGFloat {
        if let width = image.width {
            return width
        }
        let pixels = nsImage.representations.map(\.pixelsWide).max() ?? 0
        return pixels > 0 ? CGFloat(pixels) : nsImage.size.width
    }

    private var placeholder: some View {
        HStack(spacing: 6) {
            if failed {
                Image(systemName: "photo")
                    .foregroundStyle(.secondary)
            } else {
                ProgressView().controlSize(.small)
            }
            VStack(alignment: .leading, spacing: 2) {
                if !image.alt.isEmpty {
                    Text(image.alt)
                        .lineLimit(2)
                }
                if failed {
                    Text("그림을 불러오지 못했습니다 — 눌러서 브라우저로 열기")
                        .font(model.fonts.ui(delta: -2))
                        .foregroundStyle(.secondary)
                }
            }
        }
        .font(model.fonts.ui(delta: -1))
        .padding(10)
        .frame(maxWidth: min(image.width ?? 360, 360), minHeight: 64, alignment: .leading)
        .background(.quaternary.opacity(0.35), in: RoundedRectangle(cornerRadius: 6))
    }
}

/// 코멘트 그림 보관소. 같은 그림은 한 번만 받는다(AvatarImages 와 같은 방식).
///
/// 비공개 첨부(GitHubAttachment.assetID 가 있는 주소)는 PR 의 bodyHTML 에서 서명 주소를 얻어 받는다.
/// 한 PR 의 그림 여럿이 같이 물어도 bodyHTML 조회는 한 번이고, 서명이 5분짜리라 4분 동안만 다시 쓴다.
@MainActor
final class CommentImages {
    static let shared = CommentImages()

    /// 큰 스크린샷이 많다(실측 한 장 1.8MB). 오래 안 본 그림부터 버린다.
    private static let keepCount = 40
    private static let signedFor: TimeInterval = 4 * 60
    /// 못 받은 그림을 다시 물을 때까지. 서명 주소가 늦게 생기는(코멘트를 막 단) 경우를 위해 짧게 둔다.
    private static let retryAfter: TimeInterval = 2 * 60

    private var images: [URL: NSImage] = [:]
    private var recent: [URL] = []
    private var failedAt: [URL: Date] = [:]
    private var loading: [URL: Task<Data?, Never>] = [:]
    private var signed: [MarkdownImagePR: (urls: [String: URL], at: Date)] = [:]
    private var signing: [MarkdownImagePR: Task<[String: URL], Never>] = [:]

    func cached(_ url: URL) -> NSImage? {
        images[url]
    }

    func load(_ url: URL, pr: MarkdownImagePR?, github: GitHubClient) async -> NSImage? {
        if let image = images[url] {
            return image
        }
        if let failed = failedAt[url], Date().timeIntervalSince(failed) < Self.retryAfter {
            return nil
        }
        if let task = loading[url] {
            return await task.value.flatMap(NSImage.init(data:))
        }
        let task = Task { await fetch(url, pr: pr, github: github) }
        loading[url] = task
        let image = await task.value.flatMap(NSImage.init(data:))
        loading[url] = nil
        if let image {
            images[url] = image
            failedAt[url] = nil
            recent.removeAll { $0 == url }
            recent.append(url)
            if recent.count > Self.keepCount {
                images[recent.removeFirst()] = nil
            }
        } else {
            failedAt[url] = Date()
        }
        return image
    }

    private func fetch(_ url: URL, pr: MarkdownImagePR?, github: GitHubClient) async -> Data? {
        // 첨부면 서명 주소부터 받는다. 원래 주소는 공개 레포에서만 받아지고 비공개면 404 라 헛걸음이다.
        if let id = GitHubAttachment.assetID(of: url), let pr,
           let signedURL = await signedURL(id, pr: pr, github: github),
           let data = await Self.download(signedURL) {
            return data
        }
        return await Self.download(url)
    }

    private func signedURL(_ id: String, pr: MarkdownImagePR, github: GitHubClient) async -> URL? {
        if let entry = signed[pr], Date().timeIntervalSince(entry.at) < Self.signedFor, let url = entry.urls[id] {
            return url
        }
        let task = signing[pr] ?? Task { (try? await github.attachmentImageURLs(pr.repo, number: pr.number)) ?? [:] }
        signing[pr] = task
        let urls = await task.value
        signing[pr] = nil
        signed[pr] = (urls, Date())
        return urls[id]
    }

    /// 그림일 때만 바이트를 준다. 로그인 화면 같은 HTML 이 200 으로 오는 일이 있다(첨부 주소에 토큰을 붙였을 때).
    private nonisolated static func download(_ url: URL) async -> Data? {
        var request = URLRequest(url: url)
        request.timeoutInterval = 20
        guard let (data, response) = try? await URLSession.shared.data(for: request),
              let http = response as? HTTPURLResponse, http.statusCode == 200,
              http.mimeType?.hasPrefix("image/") ?? false else {
            return nil
        }
        return data
    }
}
