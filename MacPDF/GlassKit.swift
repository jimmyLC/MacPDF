import SwiftUI

// Liquid Glass building blocks. macOS 26+ uses the system glass material;
// macOS 14–25 falls back to a blurred material with a hairline edge.

extension View {
    @ViewBuilder
    func glassSurface<S: InsettableShape>(in shape: S, tint: Color? = nil, interactive: Bool = false) -> some View {
        if #available(macOS 26, *) {
            self.glassEffect(makeGlass(tint: tint, interactive: interactive), in: shape)
        } else {
            self.background(.ultraThinMaterial, in: shape)
                .overlay(shape.strokeBorder(Color.white.opacity(0.22), lineWidth: 0.75))
                .shadow(color: .black.opacity(0.16), radius: 14, y: 6)
        }
    }

    @ViewBuilder
    func prominentGlassButton() -> some View {
        if #available(macOS 26, *) { self.buttonStyle(.glassProminent) }
        else { self.buttonStyle(.borderedProminent) }
    }
}

@available(macOS 26, *)
private func makeGlass(tint: Color?, interactive: Bool) -> Glass {
    var glass = Glass.regular
    if let tint { glass = glass.tint(tint) }
    if interactive { glass = glass.interactive() }
    return glass
}

/// Lets neighbouring glass shapes share one sampling region and blend as they approach.
struct GlassGroup<Content: View>: View {
    var spacing: CGFloat = 12
    @ViewBuilder var content: Content
    var body: some View {
        if #available(macOS 26, *) { GlassEffectContainer(spacing: spacing) { content } }
        else { content }
    }
}

/// A floating capsule that hosts a row of controls.
struct GlassCapsule<Content: View>: View {
    var spacing: CGFloat = 2
    @ViewBuilder var content: Content
    var body: some View {
        HStack(spacing: spacing) { content }
            .padding(4)
            .glassSurface(in: Capsule())
    }
}

struct GlassDivider: View {
    var body: some View {
        Capsule().fill(Color.primary.opacity(0.16)).frame(width: 1, height: 18).padding(.horizontal, 3)
    }
}

struct GlassIconButton: View {
    let symbol: String
    let label: LocalizedStringKey
    var active = false
    var shortcut: KeyboardShortcut?
    let action: () -> Void
    @State private var hovering = false
    @Environment(\.isEnabled) private var isEnabled

    var body: some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: 15, weight: .medium))
                .frame(width: 34, height: 34)
                .foregroundStyle(active ? Color.white : Color.primary)
                .background(Circle().fill(active ? Color.accentColor : (hovering && isEnabled ? Color.primary.opacity(0.11) : .clear)))
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .keyboardShortcut(shortcut)
        .opacity(isEnabled ? 1 : 0.35)
        .onHover { hovering = $0 }
        .help(label)
        .accessibilityLabel(label)
        .animation(.easeOut(duration: 0.14), value: hovering)
        .animation(.easeOut(duration: 0.14), value: active)
    }
}

/// Soft colour field that gives the glass something to refract.
struct AmbientBackground: View {
    @Environment(\.colorScheme) private var scheme
    var body: some View {
        ZStack {
            LinearGradient(
                colors: scheme == .dark
                    ? [Color(red: 0.08, green: 0.09, blue: 0.13), Color(red: 0.12, green: 0.11, blue: 0.19)]
                    : [Color(red: 0.90, green: 0.92, blue: 0.97), Color(red: 0.95, green: 0.92, blue: 0.97)],
                startPoint: .topLeading, endPoint: .bottomTrailing)
            Circle().fill(Color.blue.opacity(scheme == .dark ? 0.28 : 0.22))
                .frame(width: 460, height: 460).blur(radius: 130).offset(x: -280, y: -220)
            Circle().fill(Color.purple.opacity(scheme == .dark ? 0.22 : 0.16))
                .frame(width: 520, height: 520).blur(radius: 150).offset(x: 320, y: 240)
            Circle().fill(Color.teal.opacity(scheme == .dark ? 0.12 : 0.10))
                .frame(width: 360, height: 360).blur(radius: 120).offset(x: 260, y: -240)
        }
        .ignoresSafeArea()
    }
}
