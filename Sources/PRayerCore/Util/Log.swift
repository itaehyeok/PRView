import Foundation

/// 파일 로거. GUI 앱에서 spawn 한 프로세스의 인증·실행 결과를 추적하는 데 쓴다
/// (앱을 눈으로 보지 않고도 동작을 확인할 수 있어야 한다).
public final class Log: @unchecked Sendable {
    public static let shared = Log()

    private let lock = NSLock()
    private var handle: FileHandle?
    private let formatter: DateFormatter

    private init() {
        formatter = DateFormatter()
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss.SSS"
        // 테스트 중에는 실제 앱 로그에 쓰지 않는다(표준 오류로만 낸다). 재시도 테스트가 돌 때마다
        // "테스트 일시 오류" 가 쌓여, 로그를 모아 볼 때 진짜 실패를 가렸다(실측 223줄).
        guard !RuntimeEnvironment.isRunningTests else { return }
        AppPaths.ensureDirectories()
        let path = AppPaths.logFile.path
        let fm = FileManager.default
        if let attrs = try? fm.attributesOfItem(atPath: path),
           let size = attrs[.size] as? Int, size > 2_000_000 {
            try? fm.removeItem(atPath: path)
        }
        if !fm.fileExists(atPath: path) {
            fm.createFile(atPath: path, contents: nil)
        }
        handle = FileHandle(forWritingAtPath: path)
        handle?.seekToEndOfFile()
    }

    public func write(_ message: String, category: String) {
        let line = "[\(formatter.string(from: Date()))] [\(category)] \(message)\n"
        lock.lock()
        defer { lock.unlock() }
        if let data = line.data(using: .utf8) {
            try? handle?.write(contentsOf: data)
        }
        FileHandle.standardError.write(Data(line.utf8))
    }

    public static func info(_ message: String, _ category: String = "app") {
        shared.write(message, category: category)
    }

    /// `problem` 을 주면 문제 기록에도 남긴다(툴바 "상태" → 문제 기록). 부르는 쪽이 종류를 고르게 둔 이유:
    /// 같은 실패를 엔진과 큐가 각각 로그에 쓰는 곳이 있어, 모든 오류를 세면 한 번이 두 번이 된다.
    public static func error(_ message: String, _ category: String = "app", problem: ProblemKind? = nil) {
        shared.write("ERROR \(message)", category: category)
        if let problem {
            ProblemLog.shared.record(ProblemKind.refine(problem, message: message), detail: message)
        }
    }
}
