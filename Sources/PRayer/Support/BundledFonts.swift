import AppKit
import CoreText
import PRayerCore

/// 앱에 함께 넣은 폰트를 **이 앱 안에서만** 쓸 수 있게 등록한다.
/// 사용자의 맥에 설치하지 않으므로 남의 시스템을 건드리지 않고, 받는 사람이 따로 설치할 필요도 없다.
/// 모두 SIL Open Font License 1.1 (라이선스 원문은 Resources/Fonts 에 함께 넣었다).
enum BundledFonts {
    /// 번들에 들어 있는 폰트의 패밀리 이름.
    static let familyNames: Set<String> = ["Pretendard Variable", "D2Coding", "IBM Plex Mono", "IBM Plex Sans KR"]

    /// 코드 글꼴에 없는 한글을 채우는 글꼴. IBM Plex Mono 와 한 계열이다.
    static let codeKoreanFamily = "IBM Plex Sans KR"

    static func registerAll() {
        guard let directory = Bundle.main.resourceURL?.appendingPathComponent("Fonts", isDirectory: true) else { return }
        let urls = (try? FileManager.default.contentsOfDirectory(at: directory, includingPropertiesForKeys: nil))?
            .filter { ["ttf", "otf", "ttc"].contains($0.pathExtension.lowercased()) } ?? []
        guard !urls.isEmpty else {
            Log.info("번들 폰트가 없습니다: \(directory.path)", "font")
            return
        }
        // .process = 이 프로세스에서만 보인다. 시스템 폰트 목록에는 들어가지 않는다.
        var errors: Unmanaged<CFArray>?
        if CTFontManagerRegisterFontsForURLs(urls as CFArray, .process, &errors) {
            Log.info("번들 폰트 등록 \(urls.count)개: \(urls.map(\.lastPathComponent).joined(separator: ", "))", "font")
        } else {
            let list = (errors?.takeRetainedValue() as? [Error]) ?? []
            let detail = list.map(\.localizedDescription).joined(separator: " / ")
            Log.error("번들 폰트 등록 실패: \(detail.isEmpty ? "원인 불명" : detail)", "font")
        }
    }
}
