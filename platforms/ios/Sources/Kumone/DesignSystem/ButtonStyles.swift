import SwiftUI

/// Cards that scale up on hover, scale down on press, with a soft shadow.
struct InteractiveCardStyle: ButtonStyle {
    var showShadow = true
    var hoverScale: CGFloat = 1.02
    var pressScale: CGFloat = 0.98

    #if os(macOS)
    @State private var isHovering = false
    #endif

    func makeBody(configuration: Configuration) -> some View {
        #if os(macOS)
        configuration.label
            .scaleEffect(configuration.isPressed ? pressScale : (isHovering ? hoverScale : 1.0))
            .shadow(
                color: showShadow && isHovering ? .black.opacity(0.15) : .clear,
                radius: isHovering ? 12 : 0,
                x: 0,
                y: isHovering ? 4 : 0
            )
            .animation(AppAnimation.spring, value: configuration.isPressed)
            .animation(AppAnimation.spring, value: isHovering)
            .onHover { isHovering = $0 }
        #else
        configuration.label
            .opacity(configuration.isPressed ? 0.8 : 1.0)
        #endif
    }
}

/// List rows with a hover background highlight.
struct InteractiveRowStyle: ButtonStyle {
    var cornerRadius: CGFloat = Theme.Radius.standard
    var hoverColor: Color = Theme.ColorToken.controlFill

    #if os(macOS)
    @State private var isHovering = false
    #endif

    func makeBody(configuration: Configuration) -> some View {
        #if os(macOS)
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(isHovering || configuration.isPressed ? hoverColor : .clear)
            )
            .opacity(configuration.isPressed ? 0.8 : 1.0)
            .animation(AppAnimation.quick, value: configuration.isPressed)
            .animation(AppAnimation.quick, value: isHovering)
            .onHover { isHovering = $0 }
        #else
        configuration.label
            .background(
                RoundedRectangle(cornerRadius: cornerRadius, style: .continuous)
                    .fill(configuration.isPressed ? hoverColor : .clear)
            )
            .opacity(configuration.isPressed ? 0.8 : 1.0)
            .animation(AppAnimation.quick, value: configuration.isPressed)
        #endif
    }
}

/// Subtle press feedback for icon buttons. The press settles quickly and the
/// release springs back softly, instead of one stiff 0.15s ease for both.
struct PressableButtonStyle: ButtonStyle {
    var pressScale: CGFloat = 0.92

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? pressScale : 1.0)
            .opacity(configuration.isPressed ? 0.78 : 1.0)
            .animation(
                configuration.isPressed ? PressMotion.down : PressMotion.release,
                value: configuration.isPressed
            )
    }
}

/// Shared press timing: a fast, damped press and a softer release with a
/// little overshoot, the feel of system controls.
enum PressMotion {
    static let down = Animation.spring(response: 0.18, dampingFraction: 0.86)
    static let release = Animation.spring(response: 0.42, dampingFraction: 0.62)
}

/// Transport buttons in the player: a translucent circle swells behind the
/// glyph while pressed and the glyph dips, like the system player.
struct PlayerTransportButtonStyle: ButtonStyle {
    var highlightDiameter: CGFloat = 76

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.86 : 1)
            .background {
                Circle()
                    .fill(.white.opacity(configuration.isPressed ? 0.16 : 0))
                    .frame(width: highlightDiameter, height: highlightDiameter)
                    .scaleEffect(configuration.isPressed ? 1 : 0.6)
            }
            .animation(
                configuration.isPressed ? PressMotion.down : PressMotion.release,
                value: configuration.isPressed
            )
    }
}

extension ButtonStyle where Self == PlayerTransportButtonStyle {
    static var playerTransport: PlayerTransportButtonStyle { PlayerTransportButtonStyle() }
}

/// Filter chips (category pickers).
struct ChipButtonStyle: ButtonStyle {
    var isSelected: Bool

    #if os(macOS)
    @State private var isHovering = false
    #endif

    func makeBody(configuration: Configuration) -> some View {
        #if os(macOS)
        configuration.label
            .font(Theme.Typography.chip.weight(isSelected ? .semibold : .medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(
                    isSelected
                        ? AnyShapeStyle(Theme.accent)
                        : AnyShapeStyle(isHovering
                            ? Theme.ColorToken.controlPressedFill
                            : Theme.ColorToken.controlFill)
                )
            )
            .foregroundStyle(isSelected ? .white : .primary)
            .scaleEffect(configuration.isPressed ? 0.95 : (isHovering ? 1.03 : 1.0))
            .animation(AppAnimation.spring, value: configuration.isPressed)
            .animation(AppAnimation.spring, value: isHovering)
            .onHover { isHovering = $0 }
        #else
        configuration.label
            .font(Theme.Typography.chip.weight(isSelected ? .semibold : .medium))
            .padding(.horizontal, 12)
            .padding(.vertical, 6)
            .background(
                Capsule().fill(
                    isSelected
                        ? AnyShapeStyle(Theme.accent)
                        : AnyShapeStyle(Theme.ColorToken.controlFill)
                )
            )
            .foregroundStyle(isSelected ? .white : .primary)
            .scaleEffect(configuration.isPressed ? 0.95 : 1.0)
            .animation(AppAnimation.spring, value: configuration.isPressed)
        #endif
    }
}

extension ButtonStyle where Self == InteractiveCardStyle {
    static var interactiveCard: InteractiveCardStyle { InteractiveCardStyle() }
}

extension ButtonStyle where Self == InteractiveRowStyle {
    static var interactiveRow: InteractiveRowStyle { InteractiveRowStyle() }
}

extension ButtonStyle where Self == PressableButtonStyle {
    static var pressable: PressableButtonStyle { PressableButtonStyle() }
}

extension ButtonStyle where Self == ChipButtonStyle {
    static func chip(isSelected: Bool) -> ChipButtonStyle { ChipButtonStyle(isSelected: isSelected) }
}
