import Foundation

/// 레포 검색창 한 칸에 들어온 말을 오너·이름으로 나눈다.
///
/// 칸을 둘로 나누면(조직 Picker + 이름 검색) 사용자가 치기 **전에** "이게 조직인가 이름인가"
/// 를 정해야 한다. 실제로 치는 말은 `sample-ios`, `acme`, `acme/sample-ios` 셋 중
/// 하나뿐이고, 슬래시가 있는지만 보면 나뉜다. 그래서 칸을 하나로 합쳤다.
public struct RepoQuery: Sendable, Equatable {
    /// 슬래시 앞. 슬래시가 없으면 nil — 그때는 오너인지 이름인지 정하지 않는다.
    public let owner: String?
    /// 슬래시 뒤. 슬래시가 없으면 친 말 전체.
    public let name: String
    public let raw: String

    public init(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespaces)
        raw = trimmed
        if let slash = trimmed.firstIndex(of: "/") {
            let head = trimmed[trimmed.startIndex..<slash].trimmingCharacters(in: .whitespaces)
            let tail = trimmed[trimmed.index(after: slash)...].trimmingCharacters(in: .whitespaces)
            owner = head.isEmpty ? nil : head
            name = tail
        } else {
            owner = nil
            name = trimmed
        }
    }

    public var isEmpty: Bool { raw.isEmpty }

    /// 정확히 한 레포를 가리키는가. 그러면 검색 대신 그 레포를 바로 확인할 수 있다.
    public var exactRepo: RepoID? {
        guard let owner, !name.isEmpty else { return nil }
        return RepoID(owner: owner, name: name)
    }

    /// 받아 둔 목록(`RepoCatalog`)을 거를 때 쓴다. 서버에 묻지 않고 타자마다 돈다.
    public func matches(_ repo: RepoID) -> Bool {
        guard !isEmpty else { return true }
        if let owner {
            guard repo.owner.localizedCaseInsensitiveContains(owner) else { return false }
            // `acme/` 처럼 이름 자리가 비면 그 오너의 레포를 전부 남긴다.
            return name.isEmpty || repo.name.localizedCaseInsensitiveContains(name)
        }
        // 슬래시가 없으면 오너에 걸려도 이름에 걸려도 남긴다.
        return repo.full.localizedCaseInsensitiveContains(name)
    }
}
