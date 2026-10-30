// 그 번들 ID 로 떠 있는 앱의 본창을 "pid 창번호 너비 높이" 한 줄로 찍는다(shoot.sh 가 swiftc 로 빌드해 쓴다).
// 본창 = 그 앱의 일반 층(layer 0) 창 중 가장 큰 것. 뒤에 띄운 확인용 사본은 창을 한 층 아래(-1)에 깔므로(BackgroundCopy) 그것도 본다. 창이 아직 없으면 "pid 0 0 0", 앱이 없으면 아무것도 안 찍고 1 로 끝난다.
// 창 이름은 보지 않는다 — 화면 기록 권한이 없으면 비어 있고, 창 제목도 바뀐다.
// pid 도 번들 ID 로 찾는다. 경로로 pgrep 하면 한글 폴더(NFD)에서 안 잡힌다.
import AppKit

guard CommandLine.arguments.count == 2 else {
    FileHandle.standardError.write(Data("사용법: winlist <번들 ID>\n".utf8))
    exit(2)
}
guard let app = NSRunningApplication.runningApplications(withBundleIdentifier: CommandLine.arguments[1])
    .first(where: { !$0.isTerminated }) else { exit(1) }
let pid = app.processIdentifier
let windows = CGWindowListCopyWindowInfo([.optionOnScreenOnly], kCGNullWindowID) as? [[String: Any]] ?? []
let main = windows
    .filter { ($0[kCGWindowOwnerPID as String] as? Int32) == pid && [0, -1].contains($0[kCGWindowLayer as String] as? Int ?? 1) }
    .compactMap { info -> (id: Int, width: Int, height: Int)? in
        guard let id = info[kCGWindowNumber as String] as? Int,
              let bounds = info[kCGWindowBounds as String] as? [String: Any],
              let width = bounds["Width"] as? Double, let height = bounds["Height"] as? Double else { return nil }
        return (id, Int(width), Int(height))
    }
    .max { $0.width * $0.height < $1.width * $1.height }
print(pid, main?.id ?? 0, main?.width ?? 0, main?.height ?? 0)
