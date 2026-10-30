import Foundation

/// git 이 표준 오류로 내는 진행 줄 — `Receiving objects:  45% (219692/484739), 29.00 MiB | 8.10 MiB/s`.
///
/// git 은 진행 줄을 `\r` 로 덮어쓰며 같은 자리에 다시 찍는다. 파일로 받으면 수백 번의 갱신이 `\r` 로
/// 이어 붙어 있으므로, 마지막 갱신을 찾으려면 `\r`·`\n` 둘 다로 자른다. 표준 오류가 터미널이 아니면 git 은
/// 진행을 아예 찍지 않아서 부르는 쪽이 `--progress` 를 줘야 한다(2026-10-06 실측 — 클론·fetch·checkout 모두).
/// 문구는 영어 그대로 읽는다. 자식 프로세스 환경이 `LANG=en_US.UTF-8` 이라 번역되지 않는다(ProcessEnvironment).
public struct GitProgress: Equatable, Sendable {
    public enum Stage: String, Sendable {
        /// 서버에서 받는 중. 받은 양·속도가 같이 온다.
        case receiving
        /// 받은 것을 정리하는 중(델타 풀기).
        case resolving
        /// 작업 폴더에 파일을 쓰는 중(체크아웃).
        case updating
    }

    public var stage: Stage
    public var percent: Int
    public var done: Int
    public var total: Int
    /// `29.00 MiB` — 받는 중일 때만.
    public var transferred: String?
    /// `8.10 MiB/s` — 받는 중일 때만.
    public var speed: String?

    public init(stage: Stage, percent: Int, done: Int, total: Int, transferred: String? = nil, speed: String? = nil) {
        self.stage = stage
        self.percent = percent
        self.done = done
        self.total = total
        self.transferred = transferred
        self.speed = speed
    }

    /// 0…1. 개수로 셀 수 있으면 개수로 — 퍼센트는 정수라 큰 단계에서 한참 같은 값에 머문다.
    public var fraction: Double {
        guard total > 0 else { return Double(percent) / 100 }
        return min(1, max(0, Double(done) / Double(total)))
    }

    /// 표준 오류 전체(또는 그 끝부분)에서 마지막 진행 줄.
    public static func last(in text: String) -> GitProgress? {
        for line in text.split(whereSeparator: { $0 == "\r" || $0 == "\n" }).reversed() {
            if let progress = parse(line: String(line)) { return progress }
        }
        return nil
    }

    private static let pattern = try? NSRegularExpression(
        pattern: #"^(Receiving objects|Resolving deltas|Updating files):\s+(\d+)%\s+\((\d+)/(\d+)\)(?:,\s+([\d.]+\s+(?:bytes|[KMGT]iB))(?:\s+\|\s+([\d.]+\s+(?:bytes|[KMGT]iB)/s))?)?"#)

    static func parse(line: String) -> GitProgress? {
        let text = line.trimmingCharacters(in: .whitespaces)
        guard let pattern,
              let match = pattern.firstMatch(in: text, range: NSRange(text.startIndex..., in: text)) else { return nil }
        func group(_ index: Int) -> String? {
            guard let range = Range(match.range(at: index), in: text) else { return nil }
            return String(text[range])
        }
        let stage: Stage
        switch group(1) {
        case "Receiving objects": stage = .receiving
        case "Resolving deltas": stage = .resolving
        default: stage = .updating
        }
        guard let percent = group(2).flatMap(Int.init),
              let done = group(3).flatMap(Int.init),
              let total = group(4).flatMap(Int.init) else { return nil }
        return GitProgress(stage: stage, percent: percent, done: done, total: total,
                           transferred: group(5), speed: group(6))
    }
}

/// 진행을 읽으며 git 을 돌린다.
///
/// `ProcessRunner` 는 표준 입출력을 파일로 받는다(파이프 데드락을 피하려고). 그래서 표준 오류 파일의
/// 끝부분을 짧은 간격으로 다시 읽어 마지막 진행 줄을 넘긴다. 스트리밍 경로를 따로 만들지 않은 이유다.
public struct GitProgressRunner: Sendable {
    public let git: String
    private let runner = ProcessRunner()

    public init(git: String = "/usr/bin/git") {
        self.git = git
    }

    /// 파일 내용(LFS)은 받지 않는다 — 리뷰는 소스만 읽는다. 인증을 묻는 창도 띄우지 않는다 —
    /// 앱 뒤에서 도는 git 이 물으면 아무도 답하지 못해 그대로 멈춘다.
    public static func environment() -> [String: String] {
        ProcessEnvironment.base(extra: ["GIT_TERMINAL_PROMPT": "0", "GIT_LFS_SKIP_SMUDGE": "1"])
    }

    public func run(_ arguments: [String], in directory: String, stdin: String? = nil,
                    timeout: TimeInterval,
                    onProgress: (@Sendable (GitProgress) -> Void)? = nil) async throws -> ProcessResult {
        let stdio = FileManager.default.temporaryDirectory
            .appendingPathComponent("prayer-git-\(UUID().uuidString)", isDirectory: true)
        defer { try? FileManager.default.removeItem(at: stdio) }
        let spec = ProcessSpec(executable: git, arguments: arguments, stdin: stdin,
                               currentDirectory: directory, environment: Self.environment(),
                               timeout: timeout, gracePeriod: 5, stdioDirectory: stdio)
        let errorFile = stdio.appendingPathComponent("stderr")
        let poller = Task.detached {
            guard let onProgress else { return }
            var last: GitProgress?
            while !Task.isCancelled {
                try? await Task.sleep(nanoseconds: 300_000_000)
                guard let text = Self.tail(of: errorFile), let progress = GitProgress.last(in: text),
                      progress != last else { continue }
                last = progress
                onProgress(progress)
            }
        }
        defer { poller.cancel() }
        return try await runner.run(spec)
    }

    /// 파일 끝 4KB. 진행 줄은 계속 덧붙기만 해서 끝만 보면 된다.
    static func tail(of url: URL, bytes: UInt64 = 4096) -> String? {
        guard let handle = try? FileHandle(forReadingFrom: url) else { return nil }
        defer { try? handle.close() }
        guard let end = try? handle.seekToEnd() else { return nil }
        try? handle.seek(toOffset: end > bytes ? end - bytes : 0)
        guard let data = try? handle.readToEnd() else { return nil }
        return String(decoding: data, as: UTF8.self)
    }
}
