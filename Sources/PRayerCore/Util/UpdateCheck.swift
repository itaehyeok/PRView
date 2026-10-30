import Foundation

/// 새 버전이 나왔는지 GitHub Release 에 물어본다.
///
/// github.com 릴리스를 조회한다. 비공개 저장소도 볼 수 있도록 gh 인증을 먼저 쓰고,
/// 공개 저장소에서는 인증이 없어도 HTTPS 조회로 돌아갈 수 있다.
public struct UpdateCheck: Sendable {
    /// 배포본을 받는 공개 저장소. 소스도 여기 있다(2026-10-30 소스 공개 때 옮김).
    ///
    /// 0.6.0~0.6.3 앱은 `terry-yes/PRView` 에서 같은 이름의 zip 을 찾는다(asset 주소의 저장소까지 본다). 그래서
    /// release.sh 가 공개할 때 그쪽에도 같은 zip 을 올린다(다리) — 깔린 앱이 그걸로 올라오면 그다음부터는 여기를 본다.
    public static let repo = "itaehyeok/PRView"
    /// 공개 저장소에 올리는 zip 이름. 안에 든 앱 파일은 업데이트 호환 때문에 여전히 `PRayer.app` 이다.
    public static func assetName(version: String) -> String { "PRView-\(version).zip" }
    public struct Release: Sendable, Equatable {
        public var version: String
        public var tag: String
        public var url: URL?
        public var notes: String?
        public var assetURL: URL?
        /// 비공개 저장소이면 gh 인증으로 받은 파일이어야 한다.
        public var downloadWithCLI = false
        public var authAccount: String?
    }

    /// 지금 도는 앱의 버전(CFBundleShortVersionString).
    public static func currentVersion(bundle: Bundle = .main) -> String {
        bundle.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0"
    }

    /// 베타 번호 — `release.sh --beta` 가 빌드할 때 박는다(v0.5.0-beta.3 이면 3).
    ///
    /// 베타는 다음 공개 번호를 미리 달고 나온다(0.5.0-beta.1, 0.5.0-beta.2 … → 공개 0.5.0). 베타를 몇 번 내든
    /// 공개 번호가 따라 오르지 않게 하려는 것이다(사용자 결정, 2026-10-02 — 그 전에는 베타마다 0.4.12 … 0.4.31 로
    /// 올라서 다음 공개가 0.4.11 → 0.4.31 로 건너뛰게 돼 있었다). 버전이 같은 베타끼리는 이 번호로 가른다.
    /// 번호 없는 빌드(개발 빌드, 바로 공개한 빌드, 이 방식 전의 베타)는 nil.
    public static func betaNumber(bundle: Bundle = .main) -> Int? {
        betaNumber(info: bundle.infoDictionary)
    }

    static func betaNumber(info: [String: Any]?) -> Int? {
        // 베타가 아닌 빌드는 정의되지 않은 빌드 변수가 빈 값으로 풀려 들어온다.
        guard let raw = info?["PRayerBetaNumber"] as? String, let number = Int(raw), number > 0 else { return nil }
        return number
    }

    /// 최신 릴리스. 못 받으면 nil — **조용히 넘어간다.**
    /// 업데이트 확인은 거들 뿐이라, 실패했다고 빨간 배너를 띄우면 정작 할 일을 가린다.
    public static func latest(ghPath: String, session: URLSession = .shared) async -> Release? {
        // 공개/비공개 저장소 양쪽에서 동작한다. GitHub Enterprise 로그인과 섞이지 않도록
        // github.com 을 지정하고, 현재 계정에 접근 권한이 없으면 저장소 소유자 계정도 본다.
        for account in [nil, repo.split(separator: "/").first.map(String.init)] as [String?] {
            guard let result = await gh(ghPath, ["api", "repos/\(repo)/releases/latest"], account: account),
                  result.succeeded,
                  var release = parse(Data(result.stdout.utf8)) else { continue }
            release.downloadWithCLI = true
            release.authAccount = account
            return release
        }
        guard let url = URL(string: "https://api.github.com/repos/\(repo)/releases/latest") else { return nil }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await session.data(for: request),
              (response as? HTTPURLResponse)?.statusCode == 200 else { return nil }
        return parse(data)
    }

    static func parse(_ data: Data) -> Release? {
        struct Payload: Decodable {
            struct Asset: Decodable {
                let name: String
                let browser_download_url: String
            }
            let tag_name: String?
            let body: String?
            let draft: Bool?
            let prerelease: Bool?
            let html_url: String?
            let assets: [Asset]?
        }
        guard let payload = try? JSONDecoder().decode(Payload.self, from: data),
              payload.draft != true, payload.prerelease != true,
              let tag = payload.tag_name else { return nil }
        let version = tag.hasPrefix("v") ? String(tag.dropFirst()) : tag
        guard version.range(of: #"^\d+\.\d+\.\d+$"#, options: .regularExpression) != nil else { return nil }
        let expectedName = assetName(version: version)
        let assetURL = payload.assets?
            .first(where: { $0.name == expectedName })
            .flatMap { URL(string: $0.browser_download_url) }
            .flatMap { url -> URL? in
                guard url.scheme == "https", url.host == "github.com",
                      url.path == "/\(repo)/releases/download/\(tag)/\(expectedName)" else { return nil }
                return url
            }
        return Release(version: version,
                       tag: tag,
                       url: payload.html_url.flatMap(URL.init(string:)),
                       notes: payload.body,
                       assetURL: assetURL)
    }

    /// 지금 도는 버전이 공개 저장소에 정식 릴리스로 올라가 있는가.
    ///
    /// 베타와 정식은 **같은 zip** 이라(베타를 써 보고 그대로 승격한다) 빌드할 때 "베타" 라고 박아 둘 수
    /// 없다. 그래서 돌면서 공개 저장소에 이 버전의 태그가 있는지로 가른다 — 승격하면 같은 앱이 저절로
    /// 정식으로 바뀐다. 다른 사람은 공개된 버전만 받으므로 늘 정식이다. 베타 번호(`betaNumber`)는 빌드에
    /// 박혀 승격한 정식에도 남지만, 어느 베타를 올렸는지 알려 줄 뿐 베타인지 가르는 데는 쓰지 않는다.
    public enum PublishState: Sendable, Equatable {
        /// 공개 저장소에 이 버전이 있다 — 정식.
        case published
        /// 없다 — 베타(공개 전). 비공개 소스 저장소에서 받은 것이다.
        case unpublished
        /// 묻지 못했다(오프라인, 한도 초과 등). 베타라고 단정하지 않는다.
        case unknown
    }

    public static func publishState(of version: String, ghPath: String,
                                    session: URLSession = .shared) async -> PublishState {
        let path = "repos/\(repo)/releases/tags/v\(version)"
        // gh 로 먼저 묻는다. 로그인 없는 API 는 회사처럼 IP 하나를 여럿이 쓰면 한도가 금방 찬다.
        // 공개 저장소라 어느 계정으로 물어도 답이 같다.
        if let result = await gh(ghPath, ["api", path], account: nil) {
            let state = publishState(ghSucceeded: result.succeeded, stdout: result.stdout, stderr: result.stderr)
            if state != .unknown { return state }
        }
        guard let url = URL(string: "https://api.github.com/\(path)") else { return .unknown }
        var request = URLRequest(url: url, timeoutInterval: 15)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        guard let (data, response) = try? await session.data(for: request),
              let status = (response as? HTTPURLResponse)?.statusCode else { return .unknown }
        return publishState(httpStatus: status, body: data)
    }

    /// gh 결과 판정. 404 만 "없다" 로 본다 — 로그인이 끊긴 것 같은 다른 실패는 모르는 것이다.
    static func publishState(ghSucceeded: Bool, stdout: String, stderr: String) -> PublishState {
        if ghSucceeded { return publishState(httpStatus: 200, body: Data(stdout.utf8)) }
        return stderr.contains("HTTP 404") ? .unpublished : .unknown
    }

    /// 공개 저장소에 시험판으로 올린 것은 정식이 아니다(지금은 그렇게 올리지 않지만 판정은 맞게 둔다).
    static func publishState(httpStatus: Int, body: Data) -> PublishState {
        switch httpStatus {
        case 200:
            struct Flags: Decodable { let draft: Bool?; let prerelease: Bool? }
            guard let flags = try? JSONDecoder().decode(Flags.self, from: body) else { return .unknown }
            return flags.draft == true || flags.prerelease == true ? .unpublished : .published
        case 404:
            return .unpublished
        default:
            return .unknown
        }
    }

    /// gh 가 인증된 비공개 릴리스 파일을 지정 폴더로 직접 받는다.
    public static func download(_ release: Release, to directory: URL, ghPath: String) async -> Bool {
        let arguments = ["release", "download", release.tag, "--repo", repo,
                         "--pattern", assetName(version: release.version), "--dir", directory.path]
        return await gh(ghPath, arguments, account: release.authAccount)?.succeeded == true
    }

    private static func gh(_ path: String, _ arguments: [String], account: String?) async -> ProcessResult? {
        guard FileManager.default.isExecutableFile(atPath: path) else { return nil }
        var environment = ProcessEnvironment.base(extra: ["GH_HOST": "github.com"])
        if let account {
            let tokenSpec = ProcessSpec(executable: path,
                                        arguments: ["auth", "token", "--hostname", "github.com", "--user", account],
                                        environment: environment, timeout: 15)
            guard let tokenResult = try? await ProcessRunner().run(tokenSpec), tokenResult.succeeded else { return nil }
            let token = tokenResult.stdout.trimmingCharacters(in: .whitespacesAndNewlines)
            guard !token.isEmpty else { return nil }
            environment["GH_TOKEN"] = token
        }
        let spec = ProcessSpec(executable: path, arguments: arguments,
                               environment: environment, timeout: arguments.first == "release" ? 300 : 20)
        return try? await ProcessRunner().run(spec)
    }

    /// `latest` 가 `current` 보다 새로운가. 숫자 단위로 견준다 —
    /// 문자열로 견주면 "0.10.0" 이 "0.9.0" 보다 **작다**고 나온다.
    public static func isNewer(_ latest: String, than current: String) -> Bool {
        let a = numbers(latest), b = numbers(current)
        for index in 0..<max(a.count, b.count) {
            let left = index < a.count ? a[index] : 0
            let right = index < b.count ? b[index] : 0
            if left != right { return left > right }
        }
        return false
    }

    private static func numbers(_ version: String) -> [Int] {
        version.split(separator: ".").map { part in
            Int(part.prefix { $0.isNumber }) ?? 0
        }
    }
}
