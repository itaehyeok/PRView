import Foundation

public struct RepoID: Hashable, Sendable, Codable, Identifiable {
    public let owner: String
    public let name: String

    public init(owner: String, name: String) {
        self.owner = owner
        self.name = name
    }

    public init?(full: String) {
        let parts = full.split(separator: "/", omittingEmptySubsequences: true)
        guard parts.count == 2 else { return nil }
        self.owner = String(parts[0])
        self.name = String(parts[1])
    }

    public var full: String { "\(owner)/\(name)" }
    public var id: String { full }
    /// 파일명에 쓰는 안전한 형태.
    public var slug: String { "\(owner)_\(name)" }
    /// 웹에서 볼 주소. 엔터프라이즈는 도메인이 다르므로 호스트를 받는다.
    public func url(host: String) -> URL? { URL(string: "https://\(host)/\(full)") }
}
