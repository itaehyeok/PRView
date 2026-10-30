import SwiftUI
import AppKit

/// 드래그로 옆 칸의 폭을 바꾸는 세로 구분선. 1pt 선은 잡기 어려워 투명한 손잡이(9pt)를 겹쳐 둔다.
///
/// `HSplitView` 를 쓰지 않으려고 만들었다. 분할뷰는 안쪽 자식이 바뀌면(PR·파일을 바꾸면) 끌어 둔
/// 자리를 잃고 처음 폭으로 돌아간다(실측: 목록 클릭마다 폭 초기화, diff 파일 목록도 PR 마다 340pt 로).
/// 폭은 부르는 쪽이 들고 저장한다 — 이 선은 얼마나 끌었는지만 알린다.
///
/// `horizontal` 이면 가로 선이 되어 위 칸의 높이를 바꾼다(변경 파일 탭 "커밋별로 보기" 의 커밋 표 | 파일·diff).
struct ResizeDivider: View {
    let help: String
    var horizontal = false
    /// 드래그를 시작한 자리에서 옆(가로 선이면 아래)으로 움직인 거리. 시작할 때의 폭은 부르는 쪽이 기억한다.
    let onDrag: (CGFloat) -> Void
    let onDragEnd: () -> Void
    /// 더블클릭 — 기본 폭으로 되돌린다(분할뷰의 관례).
    let onReset: () -> Void

    @State private var pushedResizeCursor = false

    var body: some View {
        Rectangle()
            .fill(Color(nsColor: .separatorColor))
            .frame(width: horizontal ? nil : 1, height: horizontal ? 1 : nil)
            .overlay {
                Rectangle()
                    .fill(Color.clear)
                    .frame(width: horizontal ? nil : 9, height: horizontal ? 9 : nil)
                    .contentShape(Rectangle())
                    .onHover { inside in
                        // push/pop 이 어긋나면 커서가 영구히 남는다. 상태로 한 번만 밀고 뺀다.
                        if inside, !pushedResizeCursor {
                            (horizontal ? NSCursor.resizeUpDown : NSCursor.resizeLeftRight).push()
                            pushedResizeCursor = true
                        } else if !inside, pushedResizeCursor {
                            NSCursor.pop()
                            pushedResizeCursor = false
                        }
                    }
                    .gesture(
                        // 이동 거리는 창 좌표로 잰다. 이 선은 끄는 대로 같이 움직이는데, 기본값(.local)으로 재면
                        // 선이 움직인 만큼 이동 거리가 깎여 커서의 절반 속도로만 따라왔다 — 폭이 이벤트 두 번에
                        // 한 번씩 계단처럼 바뀌어 들쭉날쭉해 보였다(실측: 커서 +150 에 폭 +75).
                        DragGesture(minimumDistance: 1, coordinateSpace: .global)
                            .onChanged { value in onDrag(horizontal ? value.translation.height : value.translation.width) }
                            .onEnded { _ in onDragEnd() }
                    )
                    .onTapGesture(count: 2) { onReset() }
                    .help(help)
            }
    }
}
