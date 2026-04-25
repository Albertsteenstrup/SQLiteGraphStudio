import SwiftUI

public enum StudioPalette {
    public static let accent = Color.black.opacity(0.92)
    public static let accentSoft = Color.black.opacity(0.72)
    public static let tableAccent = Color.black.opacity(0.88)

    public static let primaryText = Color.black.opacity(0.92)
    public static let secondaryText = Color.black.opacity(0.58)
    public static let tertiaryText = Color.black.opacity(0.36)

    public static let windowBackdropTop = Color(red: 0.97, green: 0.975, blue: 0.982)
    public static let windowBackdropBottom = Color(red: 0.93, green: 0.942, blue: 0.955)

    public static let graphCanvasTop = Color(red: 0.965, green: 0.97, blue: 0.976)
    public static let graphCanvasBottom = Color(red: 0.935, green: 0.944, blue: 0.955)

    public static let tablePaneTop = Color(red: 0.972, green: 0.976, blue: 0.982)
    public static let tablePaneBottom = Color(red: 0.944, green: 0.952, blue: 0.962)

    public static let cardSurfaceTop = Color(red: 1.0, green: 1.0, blue: 1.0)
    public static let cardSurfaceBottom = Color(red: 0.964, green: 0.969, blue: 0.976)
    public static let selectionSurfaceTop = Color(red: 0.915, green: 0.925, blue: 0.94)
    public static let selectionSurfaceBottom = Color(red: 0.875, green: 0.89, blue: 0.91)
    public static let headerSurface = Color(red: 0.945, green: 0.952, blue: 0.962)
    public static let gridSurface = Color(red: 0.985, green: 0.988, blue: 0.992)
    public static let editorSurface = Color(red: 0.972, green: 0.976, blue: 0.982)

    public static let chromeFill = Color.white.opacity(0.72)
    public static let chromeFillStrong = Color.white.opacity(0.9)
    public static let borderStrong = Color.black.opacity(0.14)
    public static let border = Color.black.opacity(0.09)
    public static let borderSoft = Color.black.opacity(0.05)
    public static let divider = Color.black.opacity(0.08)
    public static let shadow = Color.black.opacity(0.12)
    public static let edgeNeutral = Color.black.opacity(0.22)
    public static let edgeHighlight = Color.black.opacity(0.56)

    public static let primaryKeyTint = Color(red: 0.95, green: 0.56, blue: 0.22)
    public static let foreignKeyTint = Color(red: 0.18, green: 0.56, blue: 0.96)
    public static let referenceTint = Color(red: 0.42, green: 0.46, blue: 0.54)

    public static let graphBackgroundTop = graphCanvasTop
    public static let graphBackgroundBottom = graphCanvasBottom
    public static let darkSurface = cardSurfaceBottom
    public static let darkSurfaceRaised = cardSurfaceTop
}

public struct StudioGlassCardModifier: ViewModifier {
    let cornerRadius: CGFloat
    let tint: Color?
    let strokeOpacity: Double

    public func body(content: Content) -> some View {
        content
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(.regularMaterial)
                    .overlay {
                        RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                            .fill((tint ?? Color.white).opacity(0.12))
                    }
            )
            .overlay {
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .stroke((tint ?? Color.black).opacity(strokeOpacity), lineWidth: 1)
            }
            .shadow(color: StudioPalette.shadow, radius: 22, y: 14)
    }
}

public extension View {
    func studioGlassCard(
        cornerRadius: CGFloat = 18,
        tint: Color? = nil,
        strokeOpacity: Double = 0.14
    ) -> some View {
        modifier(StudioGlassCardModifier(cornerRadius: cornerRadius, tint: tint, strokeOpacity: strokeOpacity))
    }
}
