import Foundation

/// 앱 번들을 통째로 복사하고 격리 딱지를 뗀다 — "응용 프로그램 폴더로 옮기기" 가 쓴다.
public enum AppBundleCopy {
    public static let quarantineAttribute = "com.apple.quarantine"

    public struct Failure: LocalizedError {
        public let message: String
        public var errorDescription: String? { message }
    }

    /// `ditto` 로 복사한다. 프레임워크 안 심볼릭 링크·권한을 그대로 옮겨야 코드 서명이 깨지지 않는다.
    /// 확장 속성도 따라오므로 격리 딱지는 `removeQuarantine` 으로 따로 뗀다.
    public static func copy(_ source: URL, to destination: URL) throws {
        let process = Process()
        let pipe = Pipe()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ditto")
        process.arguments = [source.path, destination.path]
        process.standardOutput = pipe
        process.standardError = pipe
        try process.run()
        let output = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else {
            throw Failure(message: "앱을 복사하지 못했습니다: \(String(decoding: output, as: UTF8.self))")
        }
    }

    /// 번들 안 모든 항목에서 격리 딱지를 뗀다. 남겨 두면 새 자리에서도 다시 격리 실행된다.
    /// (이미 한 번 열어 Gatekeeper 를 통과한 앱의 사본이다.)
    public static func removeQuarantine(at url: URL) throws {
        for path in allPaths(in: url) where removexattr(path, quarantineAttribute, XATTR_NOFOLLOW) != 0 {
            let code = errno
            guard code != ENOATTR else { continue }
            throw Failure(message: "격리 딱지를 떼지 못했습니다(\(path)): \(String(cString: strerror(code)))")
        }
    }

    /// 번들 안 어딘가에 격리 딱지가 남아 있는가.
    public static func hasQuarantine(_ url: URL) -> Bool {
        allPaths(in: url).contains { getxattr($0, quarantineAttribute, nil, 0, 0, XATTR_NOFOLLOW) >= 0 }
    }

    /// 번들 자신과 그 안의 모든 항목. 심볼릭 링크는 따라 들어가지 않는다.
    private static func allPaths(in url: URL) -> [String] {
        var paths = [url.path]
        if let enumerator = FileManager.default.enumerator(atPath: url.path) {
            for case let relative as String in enumerator {
                paths.append(url.appendingPathComponent(relative).path)
            }
        }
        return paths
    }
}
