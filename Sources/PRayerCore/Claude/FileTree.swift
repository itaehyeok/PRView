import Foundation

/// 변경 파일 목록을 폴더 계층으로 만든 노드. Finder·Fork 처럼 폴더를 접었다 펼 수 있게 한다.
public struct FileTreeNode: Identifiable, Hashable, Sendable {
    /// 루트부터의 전체 경로(폴더도 포함). 선택·펼침 상태의 키로 쓴다.
    public var id: String
    public var name: String
    public var isDirectory: Bool
    /// 파일 노드일 때의 원본.
    public var file: DiffFile?
    public var children: [FileTreeNode]
    public var additions: Int
    public var deletions: Int

    public var childrenOrNil: [FileTreeNode]? { isDirectory ? children : nil }
    /// 이 노드 아래의 파일 수.
    public var fileCount: Int {
        isDirectory ? children.reduce(0) { $0 + $1.fileCount } : 1
    }

    public init(id: String, name: String, isDirectory: Bool, file: DiffFile?,
                children: [FileTreeNode], additions: Int, deletions: Int) {
        self.id = id
        self.name = name
        self.isDirectory = isDirectory
        self.file = file
        self.children = children
        self.additions = additions
        self.deletions = deletions
    }
}

/// 화면에 실제로 그려질 한 줄. List 한 행에 하나씩 대응한다.
public struct FlatFileTreeRow: Identifiable, Hashable, Sendable {
    public var node: FileTreeNode
    public var depth: Int
    public var id: String { node.id }

    public init(node: FileTreeNode, depth: Int) {
        self.node = node
        self.depth = depth
    }
}

public enum FileTreeBuilder {
    private final class Builder {
        var children: [String: Builder] = [:]
        var order: [String] = []
        var file: DiffFile?

        func child(_ name: String) -> Builder {
            if let existing = children[name] { return existing }
            let created = Builder()
            children[name] = created
            order.append(name)
            return created
        }
    }

    public static func build(files: [DiffFile]) -> [FileTreeNode] {
        let root = Builder()
        for file in files.sorted(by: { $0.path < $1.path }) {
            var node = root
            let segments = file.path.split(separator: "/").map(String.init)
            for segment in segments.dropLast() {
                node = node.child(segment)
            }
            if let last = segments.last {
                let leaf = node.child(last)
                leaf.file = file
            }
        }
        return convert(root, prefix: "")
    }

    private static func convert(_ builder: Builder, prefix: String) -> [FileTreeNode] {
        var nodes: [FileTreeNode] = []
        // 폴더를 먼저, 그다음 파일. 각각 이름순.
        let directories = builder.order.filter { builder.children[$0]?.file == nil }.sorted()
        let files = builder.order.filter { builder.children[$0]?.file != nil }.sorted()

        for name in directories + files {
            guard let child = builder.children[name] else { continue }
            let path = prefix.isEmpty ? name : prefix + "/" + name
            if let file = child.file {
                nodes.append(FileTreeNode(id: path, name: name, isDirectory: false, file: file,
                                          children: [], additions: file.additions, deletions: file.deletions))
            } else {
                let grandChildren = convert(child, prefix: path)
                // 폴더 하나만 든 폴더는 한 줄로 합친다(App/Sources/Login) — GitHub 파일 트리와 같다. 좁은 목록에서
                // 외길 폴더마다 한 단씩 들여 써서 파일 이름 자리가 없어졌다(최소 창에서 이름이 전부 "…"). id 는 가장
                // 깊은 폴더의 경로라 펼침 상태도 그 폴더 하나로 다룬다.
                if grandChildren.count == 1, let only = grandChildren.first, only.isDirectory {
                    nodes.append(FileTreeNode(id: only.id, name: name + "/" + only.name, isDirectory: true, file: nil,
                                              children: only.children, additions: only.additions, deletions: only.deletions))
                    continue
                }
                nodes.append(FileTreeNode(id: path,
                                          name: name,
                                          isDirectory: true,
                                          file: nil,
                                          children: grandChildren,
                                          additions: grandChildren.reduce(0) { $0 + $1.additions },
                                          deletions: grandChildren.reduce(0) { $0 + $1.deletions }))
            }
        }
        return nodes
    }

    /// 펼쳐진 폴더만 따라 내려가며 화면에 보일 줄을 평평하게 만든다.
    /// List(selection:) 은 최상위 ForEach 요소 하나를 한 줄로 센다. 트리를 중첩 VStack 으로
    /// 그리면 트리 전체가 한 줄이 되어 개별 파일을 고를 수 없다(그 버그를 이 함수로 없앤다).
    public static func flatten(_ nodes: [FileTreeNode],
                               expanded: Set<String>,
                               depth: Int = 0) -> [FlatFileTreeRow] {
        var rows: [FlatFileTreeRow] = []
        for node in nodes {
            rows.append(FlatFileTreeRow(node: node, depth: depth))
            if node.isDirectory, expanded.contains(node.id) {
                rows.append(contentsOf: flatten(node.children, expanded: expanded, depth: depth + 1))
            }
        }
        return rows
    }

    /// 모든 폴더를 펼친 상태로 시작하기 위한 id 집합.
    public static func allDirectoryIDs(_ nodes: [FileTreeNode]) -> Set<String> {
        var result: Set<String> = []
        for node in nodes where node.isDirectory {
            result.insert(node.id)
            result.formUnion(allDirectoryIDs(node.children))
        }
        return result
    }
}
