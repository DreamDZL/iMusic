import CoreGraphics
import SwiftUI

/// Dominant-color extraction for artwork-driven backgrounds
/// (kaset's ColorExtractor approach: tiny bitmap, saturation-weighted averages).
struct ArtworkColors: Equatable {
    var primary: Color
    var secondary: Color

    static let fallback = ArtworkColors(
        primary: Color(red: 0.16, green: 0.16, blue: 0.20),
        secondary: Color(red: 0.09, green: 0.09, blue: 0.12)
    )
}

/// Time-based palette interpolation that can be sampled at any moment. A new
/// track snapshots the currently visible colors, so rapid skips never jump
/// back to the previous target palette or stack another background layer.
@MainActor
struct ArtworkPaletteTransition {
    static let duration: TimeInterval = 0.8

    private(set) var colors: ArtworkColors = .fallback
    private var startingColors: ArtworkColors?
    private(set) var startedAt: TimeInterval?
    private(set) var revision = 0

    var isTransitioning: Bool { startedAt != nil }

    mutating func transition(to next: ArtworkColors, at now: TimeInterval, allowsAnimation: Bool) {
        guard next != colors else { return }
        revision &+= 1

        guard allowsAnimation else {
            colors = next
            startingColors = nil
            startedAt = nil
            return
        }

        startingColors = displayedColors(at: now)
        colors = next
        startedAt = now
    }

    func displayedColors(at now: TimeInterval) -> ArtworkColors {
        guard let startedAt, let startingColors else { return colors }
        let linearProgress = min(max((now - startedAt) / Self.duration, 0), 1)
        let progress = linearProgress * linearProgress * (3 - 2 * linearProgress)
        return startingColors.interpolated(to: colors, fraction: progress)
    }

    mutating func finishTransition(revision expectedRevision: Int) {
        guard isTransitioning, revision == expectedRevision else { return }
        startingColors = nil
        startedAt = nil
    }

    mutating func stopForReducedMotionOrPowerBudget() {
        guard isTransitioning else { return }
        revision &+= 1
        startingColors = nil
        startedAt = nil
    }
}

@MainActor
private extension ArtworkColors {
    func interpolated(
        to other: ArtworkColors,
        fraction: Double
    ) -> ArtworkColors {
        let fraction = min(max(fraction, 0), 1)
        return ArtworkColors(
            primary: Self.interpolate(primary, with: other.primary, fraction: fraction),
            secondary: Self.interpolate(secondary, with: other.secondary, fraction: fraction)
        )
    }

    private static func interpolate(
        _ color: Color,
        with other: Color,
        fraction: Double
    ) -> Color {
        let environment = EnvironmentValues()
        let lhs = color.resolve(in: environment)
        let rhs = other.resolve(in: environment)
        return Color(
            .sRGBLinear,
            red: Double(lhs.linearRed) + (Double(rhs.linearRed) - Double(lhs.linearRed)) * fraction,
            green: Double(lhs.linearGreen) + (Double(rhs.linearGreen) - Double(lhs.linearGreen)) * fraction,
            blue: Double(lhs.linearBlue) + (Double(rhs.linearBlue) - Double(lhs.linearBlue)) * fraction,
            opacity: Double(lhs.opacity) + (Double(rhs.opacity) - Double(lhs.opacity)) * fraction
        )
    }
}

enum ArtworkPalette {
    private static var cache: [String: ArtworkColors] = [:]

    @MainActor
    static func extract(from image: PlatformImage, cacheKey: String) -> ArtworkColors {
        if let cached = cache[cacheKey] {
            return cached
        }
        let colors = compute(from: image)
        if cache.count > 200 { cache.removeAll() }
        cache[cacheKey] = colors
        return colors
    }

    private static func compute(from image: PlatformImage) -> ArtworkColors {
        guard let cgImage = image.cgImageRef else { return .fallback }
        let size = 10
        let bytesPerPixel = 4
        let bytesPerRow = bytesPerPixel * size
        let bitsPerComponent = 8
        var rawData = [UInt8](repeating: 0, count: size * size * bytesPerPixel)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGImageAlphaInfo.premultipliedLast.rawValue | CGBitmapInfo.byteOrder32Big.rawValue

        guard let context = CGContext(
            data: &rawData,
            width: size,
            height: size,
            bitsPerComponent: bitsPerComponent,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else { return .fallback }

        context.draw(cgImage, in: CGRect(x: 0, y: 0, width: size, height: size))

        var samples: [(h: CGFloat, s: CGFloat, b: CGFloat, weight: CGFloat)] = []
        for y in 0..<size {
            for x in 0..<size {
                let offset = (y * size + x) * bytesPerPixel
                let r = CGFloat(rawData[offset]) / 255.0
                let g = CGFloat(rawData[offset + 1]) / 255.0
                let b_val = CGFloat(rawData[offset + 2]) / 255.0
                let a = CGFloat(rawData[offset + 3]) / 255.0
                guard a > 0.1 else { continue }

                // Convert RGB to HSB
                let maxC = max(r, max(g, b_val))
                let minC = min(r, min(g, b_val))
                let delta = maxC - minC

                var h: CGFloat = 0
                let s: CGFloat = maxC == 0 ? 0 : delta / maxC
                let b: CGFloat = maxC

                if delta > 0.00001 {
                    if r == maxC {
                        h = (g - b_val) / delta
                    } else if g == maxC {
                        h = 2 + (b_val - r) / delta
                    } else {
                        h = 4 + (r - g) / delta
                    }
                    h /= 6.0
                    if h < 0 { h += 1.0 }
                }

                // Weight vivid mid-brightness pixels highest.
                let weight = s * (1 - abs(b - 0.55))
                samples.append((h, s, b, max(weight, 0.01)))
            }
        }
        guard !samples.isEmpty else { return .fallback }

        // Dominant hue = weighted circular mean.
        var sinSum: CGFloat = 0, cosSum: CGFloat = 0, weightSum: CGFloat = 0
        var satSum: CGFloat = 0, brightSum: CGFloat = 0
        for sample in samples {
            let angle = sample.h * 2 * .pi
            sinSum += sin(angle) * sample.weight
            cosSum += cos(angle) * sample.weight
            satSum += sample.s * sample.weight
            brightSum += sample.b * sample.weight
            weightSum += sample.weight
        }
        var hue = atan2(sinSum, cosSum) / (2 * .pi)
        if hue < 0 { hue += 1 }
        let saturation = min(satSum / weightSum * 1.15, 0.72)
        let brightness = brightSum / weightSum

        let primary = Color(hue: hue, saturation: saturation,
                            brightness: min(max(brightness, 0.32), 0.5))
        let secondary = Color(hue: (hue + 0.06).truncatingRemainder(dividingBy: 1),
                              saturation: min(saturation * 1.1, 0.8),
                              brightness: min(max(brightness * 0.5, 0.12), 0.26))
        return ArtworkColors(primary: primary, secondary: secondary)
    }
}
