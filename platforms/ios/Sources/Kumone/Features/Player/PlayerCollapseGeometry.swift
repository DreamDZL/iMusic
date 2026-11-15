#if os(iOS)
import CoreGraphics

/// A frozen, window-local path, independent of the distance/velocity commit policy.
/// The player keeps its aspect ratio; the real mini player supplies the landing
/// point, not a stretched rendering of the full player's controls.
struct PlayerCollapseGeometry {
    struct Pose {
        let progress: CGFloat
        let scale: CGFloat
        let offset: CGPoint

        var transform: CGAffineTransform {
            CGAffineTransform(translationX: offset.x, y: offset.y)
                .scaledBy(x: scale, y: scale)
        }
    }

    let baseFrame: CGRect
    let viewport: CGRect
    let targetFrame: CGRect
    let usesFallback: Bool
    let travel: CGFloat
    private let startScale: CGFloat
    private let startOffset: CGPoint
    private let endScale: CGFloat
    private let endOffset: CGPoint

    init?(baseFrame: CGRect, viewport: CGRect, sourceFrame: CGRect?,
          grabY: CGFloat? = nil, initialTransform: CGAffineTransform = .identity) {
        guard Self.isUsableFrame(baseFrame), Self.isUsableFrame(viewport),
              baseFrame.width >= 44, baseFrame.height >= 44,
              viewport.width >= 44, viewport.height >= 44,
              baseFrame.width <= viewport.width * 2,
              baseFrame.height <= viewport.height * 2 else { return nil }
        self.baseFrame = baseFrame
        self.viewport = viewport
        let validSource = sourceFrame.flatMap { Self.validSource($0, base: baseFrame, viewport: viewport) }
        usesFallback = validSource == nil
        let target = validSource ?? Self.fallbackFrame(base: baseFrame, viewport: viewport)
        targetFrame = target
        let finalScale = min(1, min(target.width / baseFrame.width, target.height / baseFrame.height))
        endScale = finalScale
        endOffset = CGPoint(x: target.midX - baseFrame.midX, y: target.midY - baseFrame.midY)

        // Re-grabbing a rebound starts at its live presentation transform, not
        // identity. Rotation, shear and non-finite transforms are never reused.
        let initial = Self.usableUniformTransform(initialTransform)
            && abs(initialTransform.tx) <= viewport.width * 2
            && abs(initialTransform.ty) <= viewport.height * 2 ? initialTransform : .identity
        let firstScale = max(finalScale, min(1.05, initial.a))
        startScale = firstScale
        let firstOffset = CGPoint(x: initial.tx, y: initial.ty)
        startOffset = firstOffset
        let press = grabY.flatMap {
            $0.isFinite && $0 >= viewport.minY && $0 <= viewport.maxY ? $0 : nil
        } ?? (baseFrame.minY + firstOffset.y)
        let grip = min(0, max(-baseFrame.height / 2,
            (press - baseFrame.midY - firstOffset.y) / firstScale))
        // Upper-half touch points stay directly under the finger as the card
        // shrinks. Lower regions use the center to avoid a near-zero runway.
        let startGrip = baseFrame.midY + firstOffset.y + grip * firstScale
        let endGrip = target.midY + grip * finalScale
        travel = max(44, endGrip - startGrip)
    }

    func pose(translation: CGFloat, reduceMotion: Bool = false) -> Pose {
        let distance = translation.isFinite ? max(0, translation) : 0
        if reduceMotion {
            // No zoom or long spatial sweep with Reduce Motion. The terminal
            // animator uses this same restrained offset and a short crossfade.
            return Pose(progress: min(1, distance / travel), scale: 1,
                        offset: CGPoint(x: 0, y: min(24, distance * 0.15)))
        }
        let progress = min(1, distance / travel)
        return Pose(progress: progress,
                    scale: startScale + (endScale - startScale) * progress,
                    offset: CGPoint(x: startOffset.x + (endOffset.x - startOffset.x) * progress,
                                    y: startOffset.y + (endOffset.y - startOffset.y) * progress))
    }

    func collapsedTransform(reduceMotion: Bool) -> CGAffineTransform {
        reduceMotion ? CGAffineTransform(translationX: 0, y: 24) : pose(translation: travel).transform
    }

    func canContinue(baseFrame current: CGRect, viewport: CGRect) -> Bool {
        Self.isUsableFrame(current) && viewport == self.viewport
            && abs(current.minX - baseFrame.minX) <= 0.5
            && abs(current.minY - baseFrame.minY) <= 0.5
            && abs(current.width - baseFrame.width) <= 0.5
            && abs(current.height - baseFrame.height) <= 0.5
    }

    /// UIView.frame is undefined while transformed. Its bounds and center still
    /// describe this stable layout rect in its superview's coordinate system.
    static func untransformedFrame(bounds: CGRect, center: CGPoint) -> CGRect? {
        guard isUsableFrame(bounds), center.x.isFinite, center.y.isFinite else { return nil }
        let rect = CGRect(x: center.x - bounds.width / 2, y: center.y - bounds.height / 2,
                          width: bounds.width, height: bounds.height)
        return isUsableFrame(rect) ? rect : nil
    }

    static func isUsableFrame(_ frame: CGRect) -> Bool {
        frame.origin.x.isFinite && frame.origin.y.isFinite
            && frame.width.isFinite && frame.height.isFinite
            && frame.size.width > 1 && frame.size.height > 1
            && frame.width < CGFloat.greatestFiniteMagnitude / 4
            && frame.height < CGFloat.greatestFiniteMagnitude / 4
            && abs(frame.origin.x) < CGFloat.greatestFiniteMagnitude / 4
            && abs(frame.origin.y) < CGFloat.greatestFiniteMagnitude / 4
            && frame.maxX.isFinite && frame.maxY.isFinite
            && frame.midX.isFinite && frame.midY.isFinite
    }

    private static func usableUniformTransform(_ transform: CGAffineTransform) -> Bool {
        transform.a.isFinite && transform.d.isFinite && transform.tx.isFinite && transform.ty.isFinite
            && transform.b == 0 && transform.c == 0 && transform.a == transform.d && transform.a > 0
    }

    private static func validSource(_ frame: CGRect, base: CGRect, viewport: CGRect) -> CGRect? {
        // Accessory reparenting can briefly report an empty, full-screen or
        // off-window frame. Do not chase it or reuse another orientation's rect.
        guard isUsableFrame(frame), frame.width >= 24, frame.height >= 24,
              frame.width <= min(base.width, viewport.width) * 1.05,
              frame.height <= min(160, base.height * 0.3),
              frame.midY >= viewport.midY,
              viewport.insetBy(dx: -1, dy: -1).contains(frame) else { return nil }
        return frame
    }

    private static func fallbackFrame(base: CGRect, viewport: CGRect) -> CGRect {
        let width = max(2, min(base.width, viewport.width) - min(32, viewport.width * 0.1))
        let height = max(2, min(64, viewport.height * 0.15))
        return CGRect(x: viewport.midX - width / 2,
                      y: viewport.maxY - height - min(84, viewport.height * 0.12),
                      width: width, height: height)
    }
}
#endif
