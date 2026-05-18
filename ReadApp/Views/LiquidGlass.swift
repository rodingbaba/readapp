import SwiftUI

enum LiquidGlassTint {
    case neutral
    case accent
    case warning
    case danger
    case strongAccent
    case success

    fileprivate var color: Color {
        switch self {
        case .neutral: return .clear
        case .accent: return .blue
        case .warning: return .orange
        case .danger: return .red
        case .strongAccent: return .blue
        case .success: return .green
        }
    }

    fileprivate var fillOpacity: Double {
        switch self {
        case .neutral: return 0
        case .accent: return 0.10
        case .warning: return 0.10
        case .danger: return 0.10
        case .success: return 0.10
        case .strongAccent: return 0.32
        }
    }

    @available(iOS 26.0, *)
    fileprivate var glassTintOpacity: Double {
        switch self {
        case .neutral: return 0
        case .accent: return 0.22
        case .warning: return 0.22
        case .danger: return 0.22
        case .success: return 0.22
        case .strongAccent: return 0.65
        }
    }
}

extension View {
    /// Apply a Liquid Glass surface (iOS 26+) with a material fallback on older systems.
    @ViewBuilder
    func liquidGlass<S: InsettableShape>(
        tint: LiquidGlassTint = .neutral,
        interactive: Bool = false,
        in shape: S = RoundedRectangle(cornerRadius: 22, style: .continuous)
    ) -> some View {
        if #available(iOS 26.0, *) {
            self.glassEffect(glassFor(tint: tint, interactive: interactive), in: shape)
        } else {
            self.background(
                shape
                    .fill(.regularMaterial)
                    .overlay(
                        shape
                            .fill(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(0.32),
                                        Color.white.opacity(0.04)
                                    ],
                                    startPoint: .top,
                                    endPoint: .bottom
                                )
                            )
                            .blendMode(.overlay)
                    )
                    .overlay(
                        shape.fill(tint.color.opacity(tint.fillOpacity))
                    )
                    .overlay(
                        shape
                            .strokeBorder(
                                LinearGradient(
                                    colors: [
                                        Color.white.opacity(0.55),
                                        Color.white.opacity(0.10)
                                    ],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 0.8
                            )
                    )
                    .shadow(color: Color.black.opacity(0.14), radius: 16, y: 6)
            )
        }
    }

    /// Wrap in a GlassEffectContainer so adjacent glass surfaces blend nicely.
    @ViewBuilder
    func liquidGlassContainer(spacing: CGFloat = 12) -> some View {
        if #available(iOS 26.0, *) {
            GlassEffectContainer(spacing: spacing) { self }
        } else {
            self
        }
    }

    /// Hides the default scroll/list background so a custom surface shows through. Inert below iOS 16.
    @ViewBuilder
    func hideScrollBackground() -> some View {
        if #available(iOS 16.0, *) {
            self.scrollContentBackground(.hidden)
        } else {
            self
        }
    }
}

@available(iOS 26.0, *)
private func glassFor(tint: LiquidGlassTint, interactive: Bool) -> Glass {
    var glass: Glass = .regular
    if tint.color != .clear {
        glass = glass.tint(tint.color.opacity(tint.glassTintOpacity))
    }
    if interactive {
        glass = glass.interactive()
    }
    return glass
}

/// A capsule-shaped icon+label button with liquid glass background.
struct GlassIconButton: View {
    let systemImage: String
    let title: String?
    let tint: LiquidGlassTint
    let isProminent: Bool
    let isDisabled: Bool
    let action: () -> Void

    init(
        systemImage: String,
        title: String? = nil,
        tint: LiquidGlassTint = .neutral,
        isProminent: Bool = false,
        isDisabled: Bool = false,
        action: @escaping () -> Void
    ) {
        self.systemImage = systemImage
        self.title = title
        self.tint = tint
        self.isProminent = isProminent
        self.isDisabled = isDisabled
        self.action = action
    }

    var body: some View {
        Button(action: action) {
            VStack(spacing: 3) {
                Image(systemName: systemImage)
                    .font(.system(size: isProminent ? 26 : 18, weight: .semibold))
                if let title {
                    Text(title)
                        .font(.caption2)
                        .fontWeight(.medium)
                }
            }
            .foregroundColor(foregroundColor)
            .frame(minWidth: isProminent ? 60 : 48, minHeight: isProminent ? 60 : 48)
            .padding(.horizontal, isProminent ? 8 : 6)
            .padding(.vertical, isProminent ? 4 : 2)
            .contentShape(Capsule())
        }
        .buttonStyle(.plain)
        .opacity(isDisabled ? 0.35 : 1)
        .disabled(isDisabled)
        .liquidGlass(
            tint: tint,
            interactive: true,
            in: Capsule()
        )
    }

    private var foregroundColor: Color {
        if isProminent {
            switch tint {
            case .accent, .warning, .danger, .strongAccent, .success: return .white
            case .neutral: return .primary
            }
        }
        switch tint {
        case .accent: return .blue
        case .strongAccent: return .white
        case .warning: return .orange
        case .danger: return .red
        case .success: return .green
        case .neutral: return .primary
        }
    }
}
