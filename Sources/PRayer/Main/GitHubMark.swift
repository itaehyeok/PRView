import SwiftUI

/// GitHub 로 가는 버튼·메뉴·링크가 함께 쓰는 이름과 로고.
///
/// 예전에는 자리마다 `↗` 아이콘만 있거나("무슨 버튼인지 모르겠다" — 사용자 피드백) 문구가
/// "GitHub 에서 열기"·"GitHub 에서 보기" 로 갈렸다. 한 곳에서 정해 모두 같은 말·같은 로고를 쓴다.
enum GitHubLink {
    static let title = "GitHub에서 보기"
}

/// GitHub 로고(Octicons `mark-github`, MIT 라이선스 — github.com/primer/octicons).
///
/// GitHub 로고 사용 안내대로 **GitHub 으로 가는 링크에만** 쓰고 모양·비율을 바꾸지 않는다.
/// 에셋이 템플릿 이미지라 둘레 글자색을 따른다(링크면 파랑, 초록 칩이면 초록).
struct GitHubMark: View {
    /// 한 변의 길이(pt). 옆 글자 크기에 맞춘다.
    var size: CGFloat = 13

    var body: some View {
        Image("GitHubMark")
            .renderingMode(.template)
            .resizable()
            .scaledToFit()
            .frame(width: size, height: size)
            .accessibilityHidden(true)
    }
}

/// [로고] 문구 — 버튼·링크의 라벨. 메뉴 항목은 `Label` 에 에셋 이미지를 바로 넣는다(메뉴는 뷰가 아니라 이미지만 그린다).
struct GitHubLinkLabel: View {
    var title = GitHubLink.title
    var markSize: CGFloat = 13

    var body: some View {
        Label {
            Text(title)
        } icon: {
            GitHubMark(size: markSize)
        }
    }
}
