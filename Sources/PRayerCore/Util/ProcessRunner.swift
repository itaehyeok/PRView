import Foundation

public struct ProcessResult: Sendable {
    public let exitCode: Int32
    public let stdout: String
    public let stderr: String
    public let timedOut: Bool
    /// 상위 Task 가 취소돼 우리가 신호를 보내 죽인 경우. 실패로 취급하면 안 된다.
    public let cancelled: Bool

    public var succeeded: Bool { exitCode == 0 && !timedOut && !cancelled }

    public init(exitCode: Int32, stdout: String, stderr: String, timedOut: Bool, cancelled: Bool = false) {
        self.exitCode = exitCode
        self.stdout = stdout
        self.stderr = stderr
        self.timedOut = timedOut
        self.cancelled = cancelled
    }
}

public enum ProcessRunError: Error, LocalizedError, Sendable {
    case executableMissing(String)
    case launchFailed(String)
    case timedOut(TimeInterval)

    public var errorDescription: String? {
        switch self {
        case .executableMissing(let path): return "실행 파일을 찾을 수 없습니다: \(path)"
        case .launchFailed(let reason): return "프로세스를 실행할 수 없습니다: \(reason)"
        case .timedOut(let seconds): return "제한 시간(\(Int(seconds))초)을 넘겨 중단했습니다."
        }
    }
}

public struct ProcessSpec: Sendable {
    public var executable: String
    public var arguments: [String]
    /// stdin 은 임시 파일로 전달한다(파이프 버퍼 데드락과 SIGPIPE 회피).
    public var stdin: String?
    public var currentDirectory: String?
    public var environment: [String: String]
    public var timeout: TimeInterval
    /// SIGINT 후 이 시간이 지나도 살아 있으면 SIGTERM.
    public var gracePeriod: TimeInterval
    /// stdout/stderr 를 남길 디렉터리. 주면 임시 폴더 대신 여기에 쓰고 **지우지 않는다**.
    /// 앱이 죽어도 결과를 나중에 수확할 수 있게 하는 용도다(`pid` 파일도 함께 남긴다).
    public var stdioDirectory: URL?

    public init(executable: String,
                arguments: [String] = [],
                stdin: String? = nil,
                currentDirectory: String? = nil,
                environment: [String: String] = ProcessEnvironment.base(),
                timeout: TimeInterval = 60,
                gracePeriod: TimeInterval = 5,
                stdioDirectory: URL? = nil) {
        self.stdioDirectory = stdioDirectory
        self.executable = executable
        self.arguments = arguments
        self.stdin = stdin
        self.currentDirectory = currentDirectory
        self.environment = environment
        self.timeout = timeout
        self.gracePeriod = gracePeriod
    }
}

public enum ProcessEnvironment {
    /// GUI 앱이 spawn 하는 자식 프로세스용 환경.
    ///
    /// - GUI 앱은 로그인 셸 PATH 를 상속하지 않는다(`launchctl getenv PATH` 가 비어 있음) → PATH 를 직접 넣는다.
    /// - **`USER`/`LOGNAME` 이 없으면 `claude` 가 키체인에서 자격증명을 읽지 못한다**
    ///   (2026-09-03 실측: `env -i HOME PATH` 만 주면 `loggedIn: false`).
    /// - `GH_TOKEN`/`GITHUB_TOKEN` 은 항상 제거한다. 리뷰 프로세스가 GitHub 에 쓸 수 있는 경로를 없앤다.
    public static func base(extra: [String: String] = [:]) -> [String: String] {
        let home = NSHomeDirectory()
        let user = NSUserName()
        var env: [String: String] = [
            "HOME": home,
            "USER": user,
            "LOGNAME": user,
            "PATH": "/opt/homebrew/bin:\(home)/.local/bin:/usr/local/bin:/usr/bin:/bin:/usr/sbin:/sbin",
            "LANG": "en_US.UTF-8",
            "SHELL": "/bin/zsh",
            "DISABLE_AUTOUPDATER": "1"
        ]
        if let tmp = ProcessInfo.processInfo.environment["TMPDIR"] {
            env["TMPDIR"] = tmp
        }
        for (key, value) in extra { env[key] = value }
        for key in ["GH_TOKEN", "GITHUB_TOKEN", "GH_ENTERPRISE_TOKEN", "ANTHROPIC_API_KEY"] {
            env.removeValue(forKey: key)
        }
        return env
    }
}

public struct ProcessRunner: Sendable {
    public init() {}

    public func run(_ spec: ProcessSpec) async throws -> ProcessResult {
        guard FileManager.default.isExecutableFile(atPath: spec.executable) else {
            throw ProcessRunError.executableMissing(spec.executable)
        }
        let box = ProcessBox()
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<ProcessResult, Error>) in
                DispatchQueue.global(qos: .userInitiated).async {
                    do {
                        continuation.resume(returning: try box.runSync(spec))
                    } catch {
                        continuation.resume(throwing: error)
                    }
                }
            }
        } onCancel: {
            box.cancel()
        }
    }
}

/// `Process`/`Pipe`/`FileHandle` 은 Sendable 이 아니므로 이 클래스 안에만 가둔다.
/// 표준 입출력은 전부 임시 파일로 주고받아 파이프 동시 drain·데드락 문제를 없앤다.
private final class ProcessBox: @unchecked Sendable {
    private let lock = NSLock()
    private var process: Process?
    private var cancelled = false
    private var timedOut = false

    func cancel() {
        lock.lock()
        cancelled = true
        lock.unlock()
        escalate(grace: 5)
    }

    private func handleTimeout(grace: TimeInterval) {
        lock.lock()
        timedOut = true
        lock.unlock()
        escalate(grace: grace)
    }

    /// SIGINT → (유예) SIGTERM → (유예) SIGKILL.
    /// SIGKILL 까지 올려야 두 신호를 무시하는 자식 때문에 `waitUntilExit` 이 영구 블록되고
    /// 워커 전체가 멈추는 일을 막을 수 있다.
    private func escalate(grace: TimeInterval) {
        signalIfRunning { $0.interrupt() }
        DispatchQueue.global().asyncAfter(deadline: .now() + grace) { [self] in
            signalIfRunning { $0.terminate() }
            DispatchQueue.global().asyncAfter(deadline: .now() + grace) { [self] in
                signalIfRunning { kill($0.processIdentifier, SIGKILL) }
            }
        }
    }

    private func signalIfRunning(_ action: (Process) -> Void) {
        lock.lock()
        defer { lock.unlock() }
        guard let process, process.isRunning else { return }
        action(process)
    }

    func runSync(_ spec: ProcessSpec) throws -> ProcessResult {
        let fm = FileManager.default
        // 영속 디렉터리를 주면 그곳에 쓰고 지우지 않는다(앱이 죽어도 결과를 나중에 수확한다).
        let durable = spec.stdioDirectory
        let scratch = durable
            ?? fm.temporaryDirectory.appendingPathComponent("prayer-\(UUID().uuidString)", isDirectory: true)
        try fm.createDirectory(at: scratch, withIntermediateDirectories: true)
        defer { if durable == nil { try? fm.removeItem(at: scratch) } }

        let outURL = scratch.appendingPathComponent("stdout")
        let errURL = scratch.appendingPathComponent("stderr")
        fm.createFile(atPath: outURL.path, contents: nil)
        fm.createFile(atPath: errURL.path, contents: nil)
        guard let outHandle = FileHandle(forWritingAtPath: outURL.path),
              let errHandle = FileHandle(forWritingAtPath: errURL.path) else {
            throw ProcessRunError.launchFailed("표준 출력 파일을 열 수 없습니다.")
        }
        // Process 는 넘겨준 FileHandle 의 소유권을 갖지 않는다. 직접 닫지 않으면
        // 실행 1건당 fd 가 누출돼 결국 모든 서브프로세스 실행이 실패한다.
        var openHandles: [FileHandle] = [outHandle, errHandle]
        defer { for handle in openHandles { try? handle.close() } }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: spec.executable)
        process.arguments = spec.arguments
        process.environment = spec.environment
        process.standardOutput = outHandle
        process.standardError = errHandle
        if let cwd = spec.currentDirectory {
            process.currentDirectoryURL = URL(fileURLWithPath: cwd)
        }

        if let stdin = spec.stdin {
            let inURL = scratch.appendingPathComponent("stdin")
            try Data(stdin.utf8).write(to: inURL)
            guard let inHandle = FileHandle(forReadingAtPath: inURL.path) else {
                throw ProcessRunError.launchFailed("stdin 파일을 열 수 없습니다.")
            }
            process.standardInput = inHandle
            openHandles.append(inHandle)
        } else {
            process.standardInput = FileHandle.nullDevice
        }

        lock.lock()
        if cancelled {
            lock.unlock()
            throw CancellationError()
        }
        self.process = process
        lock.unlock()

        do {
            try process.run()
        } catch {
            throw ProcessRunError.launchFailed(String(describing: error))
        }
        // pid 를 남겨 두면 앱이 다시 켜졌을 때 아직 돌고 있는지 확인할 수 있다.
        if let durable {
            try? "\(process.processIdentifier)".write(to: durable.appendingPathComponent("pid"),
                                                      atomically: true, encoding: .utf8)
        }

        let watchdog = DispatchWorkItem { [self] in handleTimeout(grace: spec.gracePeriod) }
        DispatchQueue.global().asyncAfter(deadline: .now() + spec.timeout, execute: watchdog)
        process.waitUntilExit()
        watchdog.cancel()

        for handle in openHandles { try? handle.close() }
        openHandles.removeAll()

        let stdout = (try? Data(contentsOf: outURL)).flatMap { String(data: $0, encoding: .utf8) } ?? ""
        let stderr = (try? Data(contentsOf: errURL)).flatMap { String(data: $0, encoding: .utf8) } ?? ""

        lock.lock()
        let didTimeout = timedOut
        let wasCancelled = cancelled
        lock.unlock()

        return ProcessResult(exitCode: process.terminationStatus,
                             stdout: stdout,
                             stderr: stderr,
                             timedOut: didTimeout,
                             cancelled: wasCancelled)
    }
}
