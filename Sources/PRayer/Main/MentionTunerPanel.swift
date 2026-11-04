#if DEBUG
import SwiftUI
import AppKit

/// 개발 빌드 전용 "@me 모양 조절" 창(메뉴 디버그 › @me 모양 조절… · `PRAYER_DEBUG_MENTION_TUNER=1`).
/// 본창 오른쪽 옆에 떠서, 값을 바꾸면 목록 활동 줄·개요의 @me 와 형광펜이 바로 바뀐다 — 크기·색을 말로 주고받으며
/// 빌드를 여러 번 도는 대신 화면 옆에서 바꿔 보고 정하려고 만들었다(2026-11-04 사용자 요청). 정한 값은 "값 복사" 로 옮긴다.
@MainActor
enum MentionTunerPanel {
    private static var panel: NSPanel?

    static func show() {
        if let panel {
            panel.orderFront(nil)
            return
        }
        let hosting = NSHostingController(rootView: MentionTunerView())
        // 아직 그리기 전이라 fittingSize 는 0 이다 — 0 으로 놓으면 옆 자리가 넉넉해 보여 화면 밖으로 나갔다(실측).
        let size = hosting.sizeThatFits(in: CGSize(width: 330, height: 2_000))
        let panel = NSPanel(contentRect: NSRect(origin: .zero, size: size),
                            styleMask: [.titled, .closable, .utilityWindow],
                            backing: .buffered, defer: false)
        panel.title = "@me 모양 조절"
        panel.contentViewController = hosting
        panel.setContentSize(size)
        panel.isFloatingPanel = true
        // 본창을 누르면 사라지면 옆에 두고 보며 바꿀 수 없다.
        panel.hidesOnDeactivate = false
        panel.isReleasedWhenClosed = false
        place(panel)
        panel.orderFront(nil)
        self.panel = panel
    }

    /// 본창 오른쪽 바깥에 위를 맞춰 둔다 — 옆에 두고 보며 바꾸는 창이라 본창을 가리면 안 된다. 오른쪽 자리가 모자라면
    /// 본창을 왼쪽으로 밀고, 그래도 모자라면 최소 폭까지 줄인다. 그래도 안 되면 본창 안 오른쪽 위에 겹쳐 둔다.
    private static func place(_ panel: NSPanel) {
        guard let main = NSApp.windows.filter({ $0.isVisible && !($0 is NSPanel) && $0.styleMask.contains(.titled) })
            .max(by: { $0.frame.width * $0.frame.height < $1.frame.width * $1.frame.height }),
              let screen = main.screen ?? NSScreen.main else {
            panel.center()
            return
        }
        let size = panel.frame.size
        let visible = screen.visibleFrame
        let gap: CGFloat = 8
        var frame = main.frame
        let short = frame.maxX + gap + size.width - visible.maxX
        if short > 0 {
            let shift = min(short, max(0, frame.minX - visible.minX))
            frame.origin.x -= shift
            let shrink = min(short - shift, max(0, frame.width - main.minSize.width))
            frame.size.width -= shrink
            if frame != main.frame { main.setFrame(frame, display: true, animate: true) }
        }
        var origin = NSPoint(x: frame.maxX + gap, y: frame.maxY - size.height)
        if origin.x + size.width > visible.maxX {
            origin.x = frame.maxX - size.width - 16
            origin.y = frame.maxY - size.height - 60
        }
        origin.y = max(visible.minY, origin.y)
        panel.setFrameOrigin(origin)
    }
}

private struct MentionTunerView: View {
    @Bindable private var tuner = MentionTuner.shared
    @State private var appearance = Appearance.system
    @State private var copied = false

    private enum Appearance: String, CaseIterable {
        case system = "시스템", light = "라이트", dark = "다크"
    }

    /// 색 빠르게 고르기. 앞 다섯은 시안에서 본 색이다.
    private static let presets: [(name: String, hex: Int)] = [
        ("보라", 0x7F77DD), ("분홍", 0xD4537E), ("파랑", 0x378ADD), ("청록", 0x1D9E75), ("노랑", 0xEF9F27),
        ("주황", 0xD85A30), ("초록", 0x639922), ("남색", 0x534AB7), ("회색", 0x888780),
    ]

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            preview
            Divider()
            group("크기") {
                slider("글자 크기", value: $tuner.look.chipFontSize, range: 8...14, step: 0.5, unit: "pt")
                Picker("굵기", selection: $tuner.look.chipWeight) {
                    ForEach(MentionLook.ChipWeight.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                slider("좌우 여백", value: $tuner.look.chipHorizontalPadding, range: 0...10, step: 0.5, unit: "pt")
                slider("위아래 바탕", value: $tuner.look.chipVerticalPadding, range: 0...4, step: 0.5, unit: "pt")
                slider("모서리", value: $tuner.look.chipCornerRadius, range: 0...9, step: 0.5, unit: "pt")
            }
            group("색") {
                swatches
                HStack {
                    ColorPicker("직접 고르기", selection: baseColor, supportsOpacity: false)
                    Spacer()
                    Toggle("글자도 그 색으로", isOn: $tuner.look.tintedText)
                }
                slider("바탕 진하기", value: opacityPercent, range: 5...60, step: 1, unit: "%")
            }
            group("보기") {
                Picker("모드", selection: $appearance) {
                    ForEach(Appearance.allCases, id: \.self) { Text($0.rawValue).tag($0) }
                }
                .pickerStyle(.segmented)
                .onChange(of: appearance) { _, mode in
                    switch mode {
                    case .system: NSApp.appearance = nil
                    case .light: NSApp.appearance = NSAppearance(named: .aqua)
                    case .dark: NSApp.appearance = NSAppearance(named: .darkAqua)
                    }
                }
            }
            Divider()
            Text(tuner.look.summary)
                .font(.caption.monospaced())
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Button("처음 값으로") { tuner.look = .standard }
                    .disabled(tuner.look == .standard)
                Spacer()
                Button(copied ? "복사했어요" : "값 복사") {
                    NSPasteboard.general.clearContents()
                    NSPasteboard.general.setString(tuner.look.summary, forType: .string)
                    copied = true
                    Task {
                        try? await Task.sleep(for: .seconds(1.5))
                        copied = false
                    }
                }
                .keyboardShortcut("c", modifiers: [.command, .shift])
            }
        }
        .padding(16)
        .frame(width: 330)
    }

    /// 창 안에서도 바로 견줘 보게 — 목록 활동 줄 모양 그대로 한 줄, 개요 머리 표시, 본문 형광펜.
    private var preview: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack(spacing: 5) {
                Image(systemName: "text.bubble")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                    .frame(width: 11)
                Text("Alex")
                    .font(.caption2.weight(.medium))
                    .frame(width: 62, alignment: .leading)
                Text("Commented")
                    .font(.caption2)
                    .foregroundStyle(.secondary)
                MentionButton(help: "미리보기") {}
                Spacer(minLength: 4)
                Text("45m")
                    .font(.caption2.monospacedDigit())
                    .foregroundStyle(.tertiary)
            }
            HStack(spacing: 6) {
                Text("대화 6건").font(.callout.weight(.medium))
                MentionButton(title: "\(MentionStyle.label) 2", systemImage: "arrow.down", help: "미리보기") {}
                Spacer()
                MentionTag()
            }
            Text(MentionStyle.highlighted("키보드 쪽은 @you-acme 님도 한 번 봐 주세요.", viewer: "you-acme"))
                .font(.callout)
        }
        .padding(10)
        .frame(maxWidth: .infinity, alignment: .leading)
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 8))
    }

    private var swatches: some View {
        HStack(spacing: 6) {
            ForEach(Self.presets, id: \.hex) { preset in
                let color = Color(red: Double((preset.hex >> 16) & 0xFF) / 255,
                                  green: Double((preset.hex >> 8) & 0xFF) / 255,
                                  blue: Double(preset.hex & 0xFF) / 255)
                Button {
                    setBase(hex: preset.hex)
                } label: {
                    Circle()
                        .fill(color)
                        .frame(width: 22, height: 22)
                        .overlay(Circle().stroke(Color.primary.opacity(isBase(preset.hex) ? 0.8 : 0), lineWidth: 2).padding(-3))
                }
                .buttonStyle(.plain)
                .help(preset.name)
            }
        }
        .padding(.vertical, 3)
    }

    private func group<Content: View>(_ title: String, @ViewBuilder content: () -> Content) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(title).font(.caption.weight(.semibold)).foregroundStyle(.secondary)
            content()
        }
    }

    private func slider(_ title: String, value: Binding<CGFloat>, range: ClosedRange<CGFloat>, step: CGFloat,
                        unit: String) -> some View {
        HStack {
            Text(title).frame(width: 78, alignment: .leading)
            Slider(value: value, in: range, step: step)
            Text(value.wrappedValue == value.wrappedValue.rounded()
                 ? "\(Int(value.wrappedValue))\(unit)"
                 : String(format: "%.1f%@", value.wrappedValue, unit))
                .font(.caption.monospacedDigit())
                .frame(width: 44, alignment: .trailing)
        }
    }

    private var opacityPercent: Binding<CGFloat> {
        Binding(get: { CGFloat(tuner.look.fillOpacity * 100) },
                set: { tuner.look.fillOpacity = Double($0) / 100 })
    }

    private var baseColor: Binding<Color> {
        Binding(get: { Color(red: tuner.look.red, green: tuner.look.green, blue: tuner.look.blue) },
                set: { color in
                    guard let srgb = NSColor(color).usingColorSpace(.sRGB) else { return }
                    tuner.look.red = Double(srgb.redComponent)
                    tuner.look.green = Double(srgb.greenComponent)
                    tuner.look.blue = Double(srgb.blueComponent)
                })
    }

    private func setBase(hex: Int) {
        tuner.look.red = Double((hex >> 16) & 0xFF) / 255
        tuner.look.green = Double((hex >> 8) & 0xFF) / 255
        tuner.look.blue = Double(hex & 0xFF) / 255
    }

    private func isBase(_ hex: Int) -> Bool {
        Int((tuner.look.red * 255).rounded()) == (hex >> 16) & 0xFF
            && Int((tuner.look.green * 255).rounded()) == (hex >> 8) & 0xFF
            && Int((tuner.look.blue * 255).rounded()) == hex & 0xFF
    }
}
#endif
