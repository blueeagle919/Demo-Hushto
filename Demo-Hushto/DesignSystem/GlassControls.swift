import SwiftUI

struct PrimaryButton: View {
    let title: String
    var action: () -> Void
    var body: some View {
        Button(action: action) { Text(title).font(.system(size: 17, weight: .semibold)).frame(maxWidth: .infinity).frame(minHeight: 50) }
            .hushtoProminentAction().buttonBorderShape(.capsule).tint(Theme.label).foregroundStyle(Theme.onAccent)
    }
}
struct AssetIcon: View {
    @Environment(\.colorScheme) private var colorScheme
    let name: String
    var size: CGSize = CGSize(width: 24, height: 24)
    var body: some View {
        Group {
            if colorScheme == .dark { Image(name).resizable().scaledToFit().colorInvert() }
            else { Image(name).resizable().scaledToFit() }
        }.frame(width: size.width, height: size.height).accessibilityHidden(true)
    }
}
struct DocumentPreview: View {
    let image: UIImage?
    var fillsFrame = false
    var contentInset: CGFloat = 16
    var surface: Color? = nil
    var body: some View {
        GeometryReader { geo in
            if let image {
                Image(uiImage: image).resizable()
                    .aspectRatio(contentMode: fillsFrame ? .fill : .fit)
                    .frame(width: geo.size.width, height: geo.size.height)
                    .clipped()
            }
            else { ContentUnavailableView("이미지를 불러올 수 없어요", systemImage: "photo").frame(width: geo.size.width, height: geo.size.height) }
        }
        .padding(fillsFrame ? 0 : contentInset)
        .background(fillsFrame ? Color.clear : (surface ?? Theme.surface))
        .clipShape(RoundedRectangle(cornerRadius: fillsFrame ? 24 : (contentInset == 0 ? 10 : 20)))
    }
}

// Native segmented controls provide the same selection interaction across capture,
// enhancement and PDF export. Newer systems add real Liquid Glass.
extension View {
    @ViewBuilder func hushtoGlassControl() -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(.regular, in: Capsule())
        } else {
            self.background(.regularMaterial, in: Capsule())
        }
    }
}

// Shared native glass treatment for the four camera accessory controls.
extension View {
    func hushtoCameraButton(active: Bool = false, diameter: CGFloat = 50) -> some View {
        modifier(CameraAccessoryButtonStyle(active: active, diameter: diameter))
    }
}
private struct CameraAccessoryButtonStyle: ViewModifier {
    let active: Bool
    let diameter: CGFloat
    func body(content: Content) -> some View {
        styled(content)
            .tint(Theme.label)
            .buttonBorderShape(.circle)
            .controlSize(diameter <= 44 ? .regular : .large)
            .frame(width: diameter, height: diameter)
    }
    @ViewBuilder private func styled(_ content: Content) -> some View {
        if #available(iOS 26.0, *) {
            if active { content.buttonStyle(.glassProminent) }
            else { content.buttonStyle(.glass) }
        } else {
            if active { content.buttonStyle(.borderedProminent) }
            else { content.buttonStyle(.bordered) }
        }
    }
}

// The glass backplate stays behind the independently rendered, crisp labels.
struct HushtoSelectorBackplate: View {
    @ViewBuilder var body: some View {
        if #available(iOS 26.0, *) {
            Capsule().fill(.clear)
                .glassEffect(.regular, in: Capsule())
        } else {
            Capsule().fill(.regularMaterial)
        }
    }
}

// Keep the Figma colors opaque; apply clear glass only to the moving selection.
struct HushtoSlidingSelector: View {
    let titles: [String]
    var symbols: [String] = []
    @Binding var selection: Int
    let cellHeight: CGFloat
    let spacing: CGFloat
    var crispSelection = false
    @Environment(\.isEnabled) private var isEnabled
    @GestureState private var touching = false
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        GeometryReader { geometry in
            let width = max(1, (geometry.size.width - spacing * CGFloat(max(0, titles.count - 1))) / CGFloat(max(1, titles.count)))
            ZStack(alignment: .leading) {
                selectionPlate
                    .frame(width: width, height: cellHeight)
                    .offset(x: CGFloat(selection) * (width + spacing))
                    .animation(reduceMotion ? nil : .interactiveSpring(response: 0.28, dampingFraction: 0.84), value: selection)
                    .allowsHitTesting(false)
                HStack(spacing: spacing) {
                    ForEach(titles.indices, id: \.self) { index in
                        VStack(spacing: 4) {
                            if symbols.indices.contains(index) {
                                Image(systemName: symbols[index]).font(.system(size: 21, weight: .medium)).frame(height: 24)
                            }
                            Text(titles[index]).font(.system(size: symbols.isEmpty ? 13 : 12, weight: .semibold))
                        }
                        .foregroundStyle(selection == index ? Theme.onAccent : Theme.label)
                        .frame(width: width, height: cellHeight)
                        .accessibilityElement(children: .ignore)
                        .accessibilityLabel(titles[index])
                        .accessibilityAddTraits(selection == index ? [.isButton, .isSelected] : .isButton)
                        .accessibilityAction { if isEnabled { selection = index } }
                    }
                }
            }
            .contentShape(Capsule())
            .gesture(DragGesture(minimumDistance: 0)
                .updating($touching) { _, state, _ in state = true }
                .onChanged { value in
                    guard isEnabled, !titles.isEmpty else { return }
                    selection = min(titles.count - 1, max(0, Int((value.location.x + spacing / 2) / (width + spacing))))
                })
        }
        .frame(height: cellHeight)
    }

    @ViewBuilder private var selectionPlate: some View {
        if #available(iOS 26.0, *) {
            Capsule().fill(Theme.label)
                .glassEffect(.clear.interactive(), in: Capsule())
                .overlay {
                    if crispSelection { Capsule().fill(Theme.label).padding(1) }
                }
                .overlay {
                    Capsule().strokeBorder(
                        LinearGradient(colors: [.white.opacity(0.48), .white.opacity(0.08), .white.opacity(0.24)], startPoint: .topLeading, endPoint: .bottomTrailing),
                        lineWidth: 0.75
                    )
                }
                .scaleEffect(touching && !reduceMotion ? 1.035 : 1)
                .animation(.easeOut(duration: 0.18), value: touching)
        } else {
            Capsule().fill(Theme.label)
        }
    }
}

// Figma Camera / Recording status: neutral glass with a live elapsed time.
struct CameraRecordingBadge: View {
    let startedAt: Date?
    var body: some View {
        TimelineView(.periodic(from: .now, by: 1)) { timeline in
            let seconds = max(0, Int(timeline.date.timeIntervalSince(startedAt ?? timeline.date)))
            Text("●  녹화 중  \(String(format: "%02d:%02d", seconds / 60, seconds % 60))")
                .font(.system(size: 13, weight: .semibold)).monospacedDigit()
                .foregroundStyle(Theme.label)
                .padding(.horizontal, 12).padding(.vertical, 7)
                .hushtoGlassControl()
        }
        .accessibilityLabel("녹화 중")
    }
}

// Use one native glass layer for prominent actions on modern systems.
extension View {
    @ViewBuilder func hushtoProminentAction() -> some View {
        if #available(iOS 26.0, *) { self.buttonStyle(.glassProminent) }
        else { self.buttonStyle(.borderedProminent) }
    }
}


/// The 44pt hit rectangle belongs to the Button label, rather than an outer
/// layout frame. A fixed neutral glass surface never inverts on activation.
struct CameraNavigationButtonLabel<Content: View>: View {
    @ViewBuilder var content: () -> Content
    var body: some View {
        content()
            .foregroundStyle(Theme.label)
            .frame(width: 44, height: 44)
            .contentShape(Rectangle())
            .background { surface.allowsHitTesting(false) }
    }
    @ViewBuilder private var surface: some View {
        if #available(iOS 26.0, *) {
            Circle().fill(.clear).glassEffect(.regular, in: Circle())
        } else {
            Circle().fill(.regularMaterial)
        }
    }
}

/// Figma uses a 24pt glyph within the separate 44pt navigation hit region.
/// The enabled artwork is the exact Auto Capture asset exported from Figma.
struct AutoCaptureStatusIcon: View {
    let isOn: Bool
    var body: some View {
        Group {
            if isOn {
                Image("AutoCaptureIcon")
                    .renderingMode(.template)
                    .resizable().scaledToFit()
            } else {
                Image(systemName: "camera.viewfinder")
                    .resizable().scaledToFit()
            }
        }
        .foregroundStyle(Theme.label)
        .frame(width: 24, height: 24)
        .accessibilityHidden(true)
    }
}

/// Both review actions own identical 50pt bounds; native button padding cannot
/// enlarge only the prominent action.
struct CaptureReviewActionButton: View {
    let title: String
    var prominent = false
    var action: () -> Void
    var body: some View {
        Button(action: action) {
            Text(title).font(.system(size: 17, weight: prominent ? .semibold : .regular))
                .foregroundStyle(prominent ? Theme.onAccent : Theme.label)
                .frame(maxWidth: .infinity).frame(height: 50)
                .contentShape(Capsule())
                .background { surface.allowsHitTesting(false) }
        }.buttonStyle(.plain)
    }
    @ViewBuilder private var surface: some View {
        if prominent {
            if #available(iOS 26.0, *) {
                Capsule().fill(Theme.label).glassEffect(.clear, in: Capsule())
            } else { Capsule().fill(Theme.label) }
        } else { HushtoSelectorBackplate() }
    }
}
