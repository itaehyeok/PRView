import Foundation

/// 돌고 있는 리뷰 1건의 기록. 앱이 꺼져도 이 파일과 stdout 이 디스크에 남아
/// 다음 실행에서 결과를 수확할 수 있다.
public struct SpooledJob: Codable, Sendable, Identifiable {
    public var id: String
    public var pr: PullRequestInfo
    public var trigger: ReviewRecord.Trigger
    public var deep: Bool
    public var model: String
    public var startedAt: Date
    public var phase: ReviewPhase
    public var phaseAt: Date
    /// 자식 프로세스 pid. 앱이 다시 켜졌을 때 아직 돌고 있는지 확인하는 데 쓴다.
    public var pid: Int32?

    public var directoryName: String { id }

    public init(id: String, pr: PullRequestInfo, trigger: ReviewRecord.Trigger, deep: Bool,
                model: String, startedAt: Date = Date(), phase: ReviewPhase = .queued,
                phaseAt: Date = Date(), pid: Int32? = nil) {
        self.id = id
        self.pr = pr
        self.trigger = trigger
        self.deep = deep
        self.model = model
        self.startedAt = startedAt
        self.phase = phase
        self.phaseAt = phaseAt
        self.pid = pid
    }
}

/// 수확 결과 한 건.
public enum SpoolHarvest: Sendable {
    /// 결과가 완전해서 초안으로 저장했다.
    case recovered(ReviewRecord)
    /// 프로세스가 아직 돌고 있다(앱 밖에서).
    case stillRunning(SpooledJob)
    /// 결과가 없거나 잘렸다. 토큰은 이미 쓰였을 수 있다.
    case lost(SpooledJob, reason: String)
}

public actor ReviewSpool {
    private let encoder: JSONEncoder = {
        let encoder = JSONEncoder()
        encoder.dateEncodingStrategy = .iso8601
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys, .withoutEscapingSlashes]
        return encoder
    }()
    private let decoder: JSONDecoder = {
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        return decoder
    }()

    public init() {}

    /// 리뷰 1건이 쓸 폴더를 만든다. 여기에 stdout·stderr·pid·job.json 이 모인다.
    public func begin(job: SpooledJob) -> URL {
        AppPaths.ensureDirectories()
        let directory = AppPaths.jobsDirectory.appendingPathComponent(job.directoryName, isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        write(job, to: directory)
        return directory
    }

    public func update(job: SpooledJob) {
        let directory = AppPaths.jobsDirectory.appendingPathComponent(job.directoryName, isDirectory: true)
        guard FileManager.default.fileExists(atPath: directory.path) else { return }
        write(job, to: directory)
    }

    /// 정상적으로 끝났으면 폴더째 지운다.
    public func finish(id: String) {
        let directory = AppPaths.jobsDirectory.appendingPathComponent(id, isDirectory: true)
        try? FileManager.default.removeItem(at: directory)
    }

    public func pending() -> [(job: SpooledJob, directory: URL)] {
        let entries = (try? FileManager.default.contentsOfDirectory(at: AppPaths.jobsDirectory,
                                                                    includingPropertiesForKeys: nil)) ?? []
        return entries.compactMap { directory in
            guard let data = try? Data(contentsOf: directory.appendingPathComponent("job.json")),
                  let job = try? decoder.decode(SpooledJob.self, from: data) else { return nil }
            return (job, directory)
        }
        .sorted { $0.job.startedAt < $1.job.startedAt }
    }

    /// 폴더에 남은 stdout 을 읽는다. 없거나 비어 있으면 nil.
    public func output(in directory: URL) -> String? {
        guard let text = try? String(contentsOf: directory.appendingPathComponent("stdout"), encoding: .utf8),
              !text.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return nil }
        return text
    }

    public func stderr(in directory: URL) -> String {
        (try? String(contentsOf: directory.appendingPathComponent("stderr"), encoding: .utf8)) ?? ""
    }

    /// pid 가 아직 살아 있는가. 자식이 아니어서 waitpid 를 쓸 수 없으므로 신호 0 으로 확인한다.
    public func isAlive(_ directory: URL) -> Bool {
        guard let text = try? String(contentsOf: directory.appendingPathComponent("pid"), encoding: .utf8),
              let pid = Int32(text.trimmingCharacters(in: .whitespacesAndNewlines)), pid > 0 else { return false }
        return kill(pid, 0) == 0
    }

    private func write(_ job: SpooledJob, to directory: URL) {
        guard let data = try? encoder.encode(job) else { return }
        try? data.write(to: directory.appendingPathComponent("job.json"), options: .atomic)
    }
}
