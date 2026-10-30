import Foundation
#if canImport(Darwin)
import Darwin
#endif

/// 경로 제외 규칙용 glob 매칭. `*.pbxproj`, `Package.resolved`, `*.xcassets/*` 같은 패턴을
/// 전체 경로와 파일명 양쪽에 대해 확인한다.
public enum Glob {
    public static func matches(path: String, pattern: String) -> Bool {
        if fnmatch(pattern, path, 0) == 0 { return true }
        let base = (path as NSString).lastPathComponent
        if fnmatch(pattern, base, 0) == 0 { return true }
        if !pattern.hasPrefix("*") && fnmatch("*/" + pattern, path, 0) == 0 { return true }
        return false
    }

    public static func isExcluded(path: String, patterns: [String]) -> Bool {
        patterns.contains { matches(path: path, pattern: $0) }
    }
}

/// 변경 파일 탭에서 우클릭으로 더하는 제외 패턴. `Glob` 이 읽는 꼴 그대로 만든다.
///
/// 제외 경로는 모든 레포의 리뷰에 쓴다(설정 › 대상 제외 — 레포마다 따로 두지 않는다).
public enum ExclusionPattern {
    /// fnmatch 가 특수하게 읽는 글자(`*` `?` `[` `]` `\`)를 글자 그대로 읽게 한다.
    /// 안 막으면 `Item[1].swift` 같은 이름이 묶음 패턴으로 읽혀 그 파일을 못 잡는다.
    public static func escaped(_ text: String) -> String {
        var out = ""
        for ch in text {
            if "*?[]\\".contains(ch) { out.append("\\") }
            out.append(ch)
        }
        return out
    }

    /// 이 파일 하나. 다른 레포에 같은 경로가 있으면 그것도 빠진다 — 경로 뒷부분이 같은 파일도(`Glob` 규칙).
    public static func file(_ path: String) -> String { escaped(path) }

    /// 이 폴더 아래 전부. fnmatch 의 `*` 는 `/` 도 넘으므로 하위 폴더까지 들어간다.
    public static func folder(_ path: String) -> String { escaped(path) + "/*" }

    /// 같은 확장자 전부(`*.pbxproj`). 확장자가 없으면 nil.
    public static func fileExtension(of path: String) -> String? {
        let ext = (path as NSString).pathExtension
        guard !ext.isEmpty else { return nil }
        return "*." + escaped(ext)
    }

    /// 이 경로를 빼고 있는 규칙들, 설정 순서대로. 다시 리뷰에 넣으려면 이것을 다 지워야 한다.
    public static func rules(excluding path: String, in patterns: [String]) -> [String] {
        patterns.filter { Glob.matches(path: path, pattern: $0) }
    }
}
