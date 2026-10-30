import AppKit
import SwiftUI

/// 사람 한 명을 나타내는 원형 아바타. 목록 행·PR 상세 헤더·코멘트가 함께 쓴다.
///
/// GitHub 프로필 사진을 보여 주고, 사진이 오기 전·못 받았을 때·데모 모드에서는 머리글자 칩을 보여 준다.
/// 칩 색은 이름에서 뽑는다 — 팀원을 이름을 읽지 않고 색으로 알아보게 하는 것이 목적이다.
/// 그래서 색은 **실행을 넘어 늘 같아야** 한다.
struct Avatar: View {
    /// 사진을 찾을 GitHub 아이디. nil 이면 늘 머리글자 칩이다.
    let login: String?
    /// 머리글자·칩 색을 뽑을 이름. 호출부는 축약된 표시 이름(`settings.displayName`)을 넘긴다.
    let name: String
    var size: CGFloat = 24

    @State private var loaded: NSImage?

    init(login: String?, name: String, size: CGFloat = 24) {
        self.login = login
        self.name = name
        self.size = size
    }

    private static let palette: [Color] = [.blue, .purple, .pink, .orange, .green, .teal, .indigo, .brown]

    var body: some View {
        // 이미 받아 둔 사진은 첫 그림부터 쓴다 — 목록을 스크롤할 때마다 칩이 잠깐 비치지 않게.
        let image = loaded ?? login.flatMap { AvatarImages.shared.cached(login: $0) }
        Group {
            if let image {
                Image(nsImage: image)
                    .resizable()
                    .interpolation(.high)
                    .scaledToFill()
                    .frame(width: size, height: size)
                    .clipShape(Circle())
                    // 흰 바탕 기본 아바타(identicon)가 밝은 화면에 묻히지 않게 가는 테두리를 두른다.
                    .overlay(Circle().strokeBorder(Color.primary.opacity(0.12), lineWidth: 0.5))
            } else {
                initialsChip
            }
        }
        .task(id: login) {
            guard let login, !login.isEmpty, !DemoMode.isOn else {
                return
            }
            loaded = await AvatarImages.shared.load(login: login)
        }
    }

    private var initialsChip: some View {
        Circle()
            .fill(Self.palette[paletteIndex].gradient)
            .frame(width: size, height: size)
            .overlay {
                Text(initials)
                    .font(.system(size: size * 0.42, weight: .semibold))
                    .foregroundStyle(.white)
            }
    }

    /// 첫 토큰의 앞 두 글자.
    ///
    /// 하이픈 조각마다 첫 글자를 뽑으면 안 된다 — 조직 로그인은 `rio-1-acme` 꼴이라
    /// "R1" 처럼 숫자가 섞인 의미 없는 글자가 나온다. 첫 토큰만 보면 "RE" 가 된다.
    /// 호출부는 축약된 표시 이름(`settings.displayName`)을 넘겨서 아바타·이름·색이 한 사람을
    /// 가리키게 한다.
    private var initials: String {
        let first = name.split(whereSeparator: { $0 == "-" || $0 == "." || $0 == "_" || $0 == " " }).first
        let token = first.map(String.init) ?? name
        let letters = token.prefix(2)
        return letters.isEmpty ? "?" : letters.uppercased()
    }

    /// 팔레트에서 몇 번째 색인가.
    ///
    /// `String.hashValue` 를 쓰면 안 된다. Swift 의 문자열 해시는 프로세스마다 시드가 달라서
    /// 앱을 다시 켤 때마다 같은 사람이 다른 색으로 나온다 — 색으로 사람을 알아보는 게
    /// 아예 성립하지 않는다. 실행에 무관한 FNV-1a 로 직접 계산한다.
    /// 대소문자는 무시한다(`Rio` 와 `rio` 가 다른 색이면 안 된다).
    private var paletteIndex: Int {
        var hash: UInt64 = 0xcbf2_9ce4_8422_2325
        for byte in name.lowercased().utf8 {
            hash ^= UInt64(byte)
            hash = hash &* 0x100_0000_01b3
        }
        return Int(hash % UInt64(Self.palette.count))
    }
}

/// GitHub 프로필 사진 보관소. 한 사람 사진은 한 번만 받아서 앱 안의 모든 아바타가 나눠 쓴다.
///
/// `https://github.com/<아이디>.png` 는 토큰 없이 `avatars.githubusercontent.com` 으로 넘어가 PNG 를 준다
/// (회사 조직 계정도 같다, 2026-10-27 실측). 그래서 `gh` 를 부르지 않는다.
/// 목록 한 화면에 같은 사람이 여러 번 나오므로 받는 중인 요청은 합치고, 못 받은 사람은 한동안 다시 묻지 않는다.
@MainActor
final class AvatarImages {
    static let shared = AvatarImages()

    /// 가장 큰 아바타(24pt)를 Retina 로 그려도 흐리지 않을 크기.
    private nonisolated static let pixelSize = 64
    /// 못 받은 사람을 다시 물을 때까지 기다리는 시간. 오프라인이었다가 돌아오면 이 뒤에 사진이 붙는다.
    private static let retryAfter: TimeInterval = 10 * 60

    private var images: [String: NSImage] = [:]
    private var failedAt: [String: Date] = [:]
    private var loading: [String: Task<Data?, Never>] = [:]

    func cached(login: String) -> NSImage? {
        images[login.lowercased()]
    }

    func load(login: String) async -> NSImage? {
        let key = login.lowercased()
        if let image = images[key] {
            return image
        }
        if let failed = failedAt[key], Date().timeIntervalSince(failed) < Self.retryAfter {
            return nil
        }
        if let task = loading[key] {
            return await task.value.flatMap(NSImage.init(data:))
        }
        let task = Task { await Self.fetch(login: login) }
        loading[key] = task
        let image = await task.value.flatMap(NSImage.init(data:))
        loading[key] = nil
        if let image {
            images[key] = image
            failedAt[key] = nil
        } else {
            failedAt[key] = Date()
        }
        return image
    }

    /// 사진 바이트. `NSImage` 는 Sendable 이 아니라서 메인 액터로 넘길 때는 `Data` 로 넘긴다.
    private nonisolated static func fetch(login: String) async -> Data? {
        var components = URLComponents()
        components.scheme = "https"
        components.host = "github.com"
        components.path = "/\(login).png"
        components.queryItems = [URLQueryItem(name: "size", value: String(pixelSize))]
        guard let url = components.url,
              let (data, response) = try? await URLSession.shared.data(from: url),
              (response as? HTTPURLResponse)?.statusCode == 200 else {
            return nil
        }
        return data
    }
}
