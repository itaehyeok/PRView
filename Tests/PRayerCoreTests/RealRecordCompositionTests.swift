import XCTest
@testable import PRayerCore

/// 실제로 저장된 초안으로 본문 조립을 검증한다.
///
/// 지어낸 픽스처는 내가 만든 모양이라 내가 놓친 경우를 못 잡는다. 이 맥에 쌓인 진짜
/// 리뷰 기록(우려사항·질문·안내 문장이 든 것)을 그대로 읽어 돌린다.
/// 기록이 없는 맥에서는 건너뛴다 — 저장소를 받은 사람의 테스트를 깨면 안 된다.
final class RealRecordCompositionTests: XCTestCase {
    private func storedRecords() throws -> [ReviewRecord] {
        // 데이터 폴더 설정(PRAYER_DATA_DIR)을 따른다 — 평가용 폴더(PRayer-eval)도 같은 잣대로 잰다.
        let base = AppPaths.draftsDirectory
        guard FileManager.default.fileExists(atPath: base.path) else { return [] }
        let decoder = JSONDecoder()
        decoder.dateDecodingStrategy = .iso8601
        var out: [ReviewRecord] = []
        let walker = FileManager.default.enumerator(at: base, includingPropertiesForKeys: nil)
        while let url = walker?.nextObject() as? URL {
            guard url.pathExtension == "json" else { continue }
            guard let data = try? Data(contentsOf: url),
                  let record = try? decoder.decode(ReviewRecord.self, from: data) else { continue }
            out.append(record)
        }
        return out
    }

    /// 이 맥의 기록으로 돌린다. 우려·질문이 **실제로 든** 기록만 본다.
    func testStoredRecordsComposeCorrectly() throws {
        let records = try storedRecords().filter {
            !$0.output.concerns.isEmpty || !($0.output.questionsForAuthor ?? []).isEmpty
        }
        try XCTSkipIf(records.isEmpty, "이 맥에 우려·질문이 든 초안이 없습니다.")

        var checkedNotes = 0
        for record in records {
            let summary = record.output.summaryKo.trimmingCharacters(in: .whitespacesAndNewlines)
            let concernNote = record.output.concernsNoteKo?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let questionNote = record.output.questionsNoteKo?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            let key = "#\(record.number) \(record.shortHead)"

            // ① 요약만 켜면 안내 문장이 한 줄도 없어야 한다.
            var only = record
            only.includeSummary = true
            only.includeConcerns = false
            only.includeQuestions = false
            only.includeStrengths = false
            let onlyBody = PostBuilder.composedBody(record: only)
            if !concernNote.isEmpty {
                XCTAssertFalse(onlyBody.contains(concernNote), "\(key): 끈 우려 안내가 새어 나왔다")
                checkedNotes += 1
            }
            if !questionNote.isEmpty {
                XCTAssertFalse(onlyBody.contains(questionNote), "\(key): 끈 질문 안내가 새어 나왔다")
                checkedNotes += 1
            }
            XCTAssertTrue(onlyBody.hasPrefix(summary), "\(key): 요약이 본문 맨 앞이 아니다")

            // ② 켜면 그 안내만 붙는다.
            if !concernNote.isEmpty, !record.output.concerns.isEmpty {
                var on = only
                on.includeConcerns = true
                let body = PostBuilder.composedBody(record: on)
                XCTAssertTrue(body.contains(concernNote), "\(key): 켠 우려 안내가 안 붙었다")
                if !questionNote.isEmpty {
                    XCTAssertFalse(body.contains(questionNote), "\(key): 안 켠 질문 안내가 따라왔다")
                }
            }
            if !questionNote.isEmpty, !(record.output.questionsForAuthor ?? []).isEmpty {
                var on = only
                on.includeQuestions = true
                let body = PostBuilder.composedBody(record: on)
                XCTAssertTrue(body.contains(questionNote), "\(key): 켠 질문 안내가 안 붙었다")
                if !concernNote.isEmpty {
                    XCTAssertFalse(body.contains(concernNote), "\(key): 안 켠 우려 안내가 따라왔다")
                }
            }
        }
        print("실측 검증: 초안 \(records.count)건 · 안내 문장 \(checkedNotes)개")
    }

    /// 쌓여 있는 기록을 문체 규칙으로 채점한다(관찰용 — 실패시키지 않는다).
    /// 프롬프트를 고치기 전후를 같은 잣대로 견주는 기준선이다.
    func testReportStyleOfStoredRecords() throws {
        let records = try storedRecords()
        try XCTSkipIf(records.isEmpty, "이 맥에 초안이 없습니다.")
        var byRule: [String: Int] = [:]
        var clean = 0
        var samples: [String] = []
        // soft(△)는 판정에 넣지 않고 따로 보인다 — 사람이 읽고 정할 것들이다.
        var softSamples: [String] = []
        for record in records {
            let all = ReviewStyleCheck.check(record.output)
            let soft = all.filter { $0.level == .soft }
            if !soft.isEmpty, softSamples.count < 40 {
                softSamples.append("  #\(record.number) \(soft.map(\.description).joined(separator: " / "))")
            }
            let issues = all.filter { $0.level == .hard }
            if issues.isEmpty { clean += 1; continue }
            for rule in Set(issues.map(\.rule)) { byRule[rule, default: 0] += 1 }
            if samples.count < 40 { samples.append("  #\(record.number) \(issues.map(\.description).joined(separator: " / "))") }
        }
        print("### 채점 대상 \(records.count)건 · 위반 없음 \(clean)건")
        for (rule, count) in byRule.sorted(by: { $0.value > $1.value }) {
            print("###   \(rule): \(count)건")
        }
        for line in samples { print("###\(line)") }
        for line in softSamples { print("###\(line)") }
    }
}
