import SwiftUI

// The optics of Liquid Glass for glass that lies on the panel's own glass. There the system material
// samples a backdrop of one flat colour, so it renders as a frosted blur that all but vanishes in Light
// Mode (and drops its tint while the panel is not key). Controls on the panel therefore draw the parts
// of the material that make it read as glass: a clear body that magnifies what is under it, a rim that
// catches the light, and the shadow of something lifted off the surface.

/// The rim of a piece of glass lit from the top leading corner: brightest on the edge facing the light,
/// a weaker reflection on the opposite edge, almost nothing along the sides.
struct GlassRim<S: InsettableShape>: View {
    let shape: S
    var intensity: Double = 1
    var lineWidth: CGFloat = 1
    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        let peak = intensity * (colorScheme == .dark ? 0.55 : 1)
        // Angles run clockwise from the trailing edge.
        shape.strokeBorder(
            AngularGradient(stops: [
                .init(color: .white.opacity(peak * 0.2), location: 0),
                .init(color: .white.opacity(peak * 0.55), location: 0.13),
                .init(color: .white.opacity(peak * 0.12), location: 0.3),
                .init(color: .white.opacity(peak * 0.08), location: 0.42),
                .init(color: .white.opacity(peak * 0.35), location: 0.52),
                .init(color: .white.opacity(peak), location: 0.63),
                .init(color: .white.opacity(peak * 0.6), location: 0.75),
                .init(color: .white.opacity(peak * 0.15), location: 0.9),
                .init(color: .white.opacity(peak * 0.2), location: 1),
            ], center: .center),
            lineWidth: lineWidth
        )
    }
}

/// A raised piece of clear Liquid Glass on the panel: the body of buttons, of the selected segment and
/// of the stepper. With `tint` it is tinted glass (a prominent button). `glow` is where the pointer
/// is, in unit coordinates of the chip: light gathers there while hovering and spreads when pressed.
struct GlassChip<S: InsettableShape>: View {
    let shape: S
    var tint: Color?
    var isHovered = false
    var isPressed = false
    var glow: UnitPoint?

    @Environment(\.colorScheme) private var colorScheme
    @Environment(\.colorSchemeContrast) private var contrast

    var body: some View {
        let dark = colorScheme == .dark
        ZStack {
            if let tint {
                shape.fill(tint)
                // Tinted glass is lighter where the light enters and deeper where it leaves.
                shape.fill(LinearGradient(colors: [.white.opacity(0.2), .white.opacity(0), .black.opacity(0.1)],
                                          startPoint: .top, endPoint: .bottom))
            } else {
                shape.fill(Color.white.opacity(dark ? 0.1 : 0.6))
            }
            if isHovered || isPressed {
                shape.fill(RadialGradient(colors: [.white.opacity(glowStrength), .white.opacity(0)],
                                          center: glow ?? .center, startRadius: 0, endRadius: 56))
            }
            GlassRim(shape: shape, intensity: tint == nil ? 1 : 0.7)
            if contrast == .increased {
                shape.strokeBorder(Color.primary.opacity(0.5), lineWidth: 1)
            }
        }
        .compositingGroup()
        .shadow(color: .black.opacity(dark ? 0.32 : 0.1), radius: isPressed ? 9 : 6, y: isPressed ? 3 : 2)
        .shadow(color: .black.opacity(dark ? 0.25 : 0.08), radius: 0.5, y: 0.5)
    }

    private var glowStrength: Double {
        let base = colorScheme == .dark ? 0.16 : 0.5
        return isPressed ? base * 1.6 : base * 0.6
    }
}

/// A scene with a lens of clear glass over it, the way iOS 26 shows a thumb or a selection while it
/// is held: inside the lens the scene is magnified, the lens casts a soft shadow and its rim catches
/// the light. With `knob` the lens rests as an opaque white capsule (a switch or slider thumb) that
/// dissolves into the lens as it lifts.
///
/// `lens` is the lens' frame in the scene's coordinates (the caller grows it while lifted); `lift`
/// blends from resting (0) to the full lens (1). Both animate together.
struct LensedScene<Scene: View>: View, Animatable {
    var lens: CGRect
    var lift: Double
    var magnification: CGFloat
    var knob = false
    var isBusy = false
    let scene: Scene

    init(lens: CGRect, lift: Double, magnification: CGFloat, knob: Bool = false, isBusy: Bool = false,
         @ViewBuilder scene: () -> Scene) {
        self.lens = lens
        self.lift = lift
        self.magnification = magnification
        self.knob = knob
        self.isBusy = isBusy
        self.scene = scene()
    }

    var animatableData: AnimatablePair<CGRect.AnimatableData, Double> {
        get { AnimatablePair(lens.animatableData, lift) }
        set {
            lens.animatableData = newValue.first
            lift = newValue.second
        }
    }

    @Environment(\.colorScheme) private var colorScheme

    var body: some View {
        ZStack(alignment: .topLeading) {
            if lift > 0.001 {
                lensed
            } else {
                scene
            }
            if knob {
                Capsule()
                    .fill(.white)
                    .shadow(color: .black.opacity(0.18), radius: 2, y: 1)
                    .overlay { Capsule().strokeBorder(.black.opacity(0.04), lineWidth: 0.5) }
                    .frame(width: lens.width, height: lens.height)
                    .position(x: lens.midX, y: lens.midY)
                    .opacity(1 - lift)
            }
            if isBusy {
                ProgressView()
                    .controlSize(.mini)
                    .tint(.gray)
                    .colorScheme(.light)
                    .position(x: lens.midX, y: lens.midY)
            }
        }
    }

    @ViewBuilder
    private var lensed: some View {
        let dark = colorScheme == .dark
        let shape = Capsule().frame(width: lens.width, height: lens.height).position(x: lens.midX, y: lens.midY)
        let outside = Rectangle().overlay { shape.blendMode(.destinationOut) }.compositingGroup()
        let scale = 1 + (magnification - 1) * lift
        // The scene with a hole where the lens is; inside it the lens shows its own picture.
        scene.mask { outside }
        // The shadow falls on the surface around the lens, not into the clear glass.
        Capsule()
            .fill(.black.opacity((dark ? 0.45 : 0.16) * lift))
            .frame(width: lens.width, height: lens.height)
            .blur(radius: 4)
            .offset(y: 2.5)
            .position(x: lens.midX, y: lens.midY)
            .mask { outside }
        // The scene magnified about the lens' centre, a little brighter because the glass gathers light.
        scene
            .scaleEffect(scale, anchor: .topLeading)
            .offset(x: lens.midX * (1 - scale), y: lens.midY * (1 - scale))
            .brightness(0.04 * lift)
            .saturation(1 + 0.12 * lift)
            .mask { shape }
        // The glass: a clear body with a faint sheen, light gathered along the inside of the edge, a
        // dark line where the edge bends the panel behind it, and the lit rim.
        ZStack {
            Capsule().fill(.white.opacity(dark ? 0.07 : 0.16))
            Capsule()
                .strokeBorder(.white.opacity(dark ? 0.12 : 0.35), lineWidth: 2.5)
                .blur(radius: 1.5)
                .clipShape(Capsule())
            Capsule().strokeBorder(.black.opacity(dark ? 0.35 : 0.1), lineWidth: 0.5)
            GlassRim(shape: Capsule().inset(by: 0.5), intensity: dark ? 1.7 : 1.1)
        }
        .frame(width: lens.width, height: lens.height)
        .position(x: lens.midX, y: lens.midY)
        .opacity(lift)
    }
}

extension Color {
    /// Whether a label on this colour reads better in black than in white. Only light tints need it
    /// (yellow; mint, cyan and teal in Dark Mode): like Apple, white stays on blue, green, orange and red.
    func prefersDarkLabel(in colorScheme: ColorScheme) -> Bool {
        var environment = EnvironmentValues()
        environment.colorScheme = colorScheme
        let resolved = resolve(in: environment)
        let luminance = 0.2126 * Double(resolved.linearRed) + 0.7152 * Double(resolved.linearGreen)
            + 0.0722 * Double(resolved.linearBlue)
        return luminance > 0.5
    }
}
