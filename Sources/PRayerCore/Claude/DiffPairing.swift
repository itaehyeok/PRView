import Foundation

/// 나란히 보기(split)용 행. 왼쪽은 옛 파일, 오른쪽은 새 파일.
public struct DiffRow: Sendable, Identifiable, Hashable {
    public enum Kind: String, Sendable {
        case hunk
        case context
        case change
    }

    public var id: Int
    public var kind: Kind
    public var left: DiffLine?
    public var right: DiffLine?

    public init(id: Int, kind: Kind, left: DiffLine?, right: DiffLine?) {
        self.id = id
        self.kind = kind
        self.left = left
        self.right = right
    }
}

public enum DiffPairing {
    /// 연속된 삭제 블록과 추가 블록을 같은 행에 짝지어 놓는다.
    /// 짝이 맞지 않는 만큼은 한쪽만 채운다.
    public static func rows(for file: DiffFile) -> [DiffRow] {
        var rows: [DiffRow] = []
        var deletions: [DiffLine] = []
        var additions: [DiffLine] = []
        var nextID = 0

        func flush() {
            let count = max(deletions.count, additions.count)
            for index in 0..<count {
                rows.append(DiffRow(id: nextID,
                                    kind: .change,
                                    left: index < deletions.count ? deletions[index] : nil,
                                    right: index < additions.count ? additions[index] : nil))
                nextID += 1
            }
            deletions.removeAll()
            additions.removeAll()
        }

        for line in file.lines {
            switch line.kind {
            case .deletion:
                deletions.append(line)
            case .addition:
                additions.append(line)
            case .context:
                flush()
                rows.append(DiffRow(id: nextID, kind: .context, left: line, right: line))
                nextID += 1
            case .hunk:
                flush()
                rows.append(DiffRow(id: nextID, kind: .hunk, left: line, right: line))
                nextID += 1
            case .meta:
                continue
            }
        }
        flush()
        return rows
    }
}

public extension DiffFile {
    /// 특정 줄 주변 코드 조각. 초안 코멘트가 어디에 달리는지 보여줄 때 쓴다.
    func snippet(around line: Int, side: DiffSide, context: Int = 2) -> [DiffLine] {
        let candidates = lines.filter { $0.kind != .hunk && $0.kind != .meta }
        let targetIndex = candidates.firstIndex { candidate in
            switch side {
            case .right: return candidate.newLine == line && candidate.kind != .deletion
            case .left: return candidate.oldLine == line && candidate.kind != .addition
            }
        }
        guard let targetIndex else { return [] }
        let lower = max(0, targetIndex - context)
        let upper = min(candidates.count - 1, targetIndex + context)
        return Array(candidates[lower...upper])
    }

    func isTarget(_ line: DiffLine, targetLine: Int, side: DiffSide) -> Bool {
        switch side {
        case .right: return line.newLine == targetLine && line.kind != .deletion
        case .left: return line.oldLine == targetLine && line.kind != .addition
        }
    }
}
