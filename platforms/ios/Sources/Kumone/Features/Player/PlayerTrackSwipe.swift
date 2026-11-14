import SwiftUI

/// Horizontal intent belongs to track navigation, never to the lyrics toggle.
enum PlayerTrackSwipePolicy {
    static func direction(translation: CGSize, predicted: CGSize) -> Int? {
        guard translation.width.isFinite, translation.height.isFinite,
              predicted.width.isFinite, predicted.height.isFinite, abs(translation.width) >= 24,
              abs(translation.width) > abs(translation.height) * 1.5 else { return nil }
        let x = translation.width
        guard abs(x) >= 64 || (abs(predicted.width) >= 180 && x * predicted.width > 0) else { return nil }
        return x < 0 ? 1 : -1
    }
}

struct PlayerTrackSwipeSession {
    let revision: UInt
    var isInvalidated = false
    private(set) var isHorizontal: Bool?

    mutating func update(translation: CGSize) {
        if isHorizontal == nil {
            isHorizontal = abs(translation.width) > abs(translation.height) * 1.5
        }
    }

    func direction(translation: CGSize, predicted: CGSize, currentRevision: UInt) -> Int? {
        guard !isInvalidated, revision == currentRevision, isHorizontal == true else { return nil }
        return PlayerTrackSwipePolicy.direction(translation: translation, predicted: predicted)
    }
}

/// One upper-surface carousel. Vertical drags remain available to the native
/// collapse recognizer; a cancelled drag springs back without changing tracks.
struct PlayerTrackSwipe: ViewModifier {
    let revision: UInt
    let enabled: Bool
    let canGoBack: Bool
    let canGoForward: Bool
    let onCommit: (Int) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @GestureState private var isDragging = false
    @State private var session: PlayerTrackSwipeSession?
    @State private var drag: CGFloat = 0
    @State private var settling: CGFloat = 0
    @State private var commitTask: Task<Void, Never>?

    func body(content: Content) -> some View {
        GeometryReader { geometry in
            content
                .frame(width: geometry.size.width, height: geometry.size.height)
                .offset(x: reduceMotion ? 0 : settling + drag)
                .opacity(reduceMotion ? 1 : 1 - min(abs(settling + drag) / max(1, geometry.size.width), 1) * 0.3)
                .simultaneousGesture(
                    DragGesture(minimumDistance: 18, coordinateSpace: .global)
                        .updating($isDragging) { _, state, _ in state = true }
                        .onChanged { value in
                            guard enabled, commitTask == nil else { return }
                            if session == nil { session = PlayerTrackSwipeSession(revision: revision) }
                            session?.update(translation: value.translation)
                            guard session?.isHorizontal == true, session?.isInvalidated == false else { return }
                            let available = value.translation.width < 0 ? canGoForward : canGoBack
                            withTransaction(Transaction(animation: nil)) {
                                drag = value.translation.width * (available ? 0.75 : 0.12)
                            }
                        }
                        .onEnded { value in
                            let direction = session?.direction(translation: value.translation,
                                                               predicted: value.predictedEndTranslation,
                                                               currentRevision: revision)
                            session = nil
                            guard enabled, commitTask == nil, let direction,
                                  (direction > 0 ? canGoForward : canGoBack) else {
                                withAnimation(reduceMotion ? nil : NowPlayingMotion.page) { drag = 0 }
                                return
                            }
                            withTransaction(Transaction(animation: nil)) { settling = drag; drag = 0 }
                            withAnimation(reduceMotion ? nil : .easeIn(duration: 0.16)) {
                                settling = reduceMotion ? 0 : (direction > 0 ? -1 : 1) * geometry.size.width
                            }
                            commitTask = Task { @MainActor in
                                do { try await Task.sleep(for: .milliseconds(reduceMotion ? 0 : 160)) }
                                catch { return }
                                guard !Task.isCancelled else { return }
                                commitTask = nil
                                withTransaction(Transaction(animation: nil)) {
                                    settling = reduceMotion ? 0 : (direction > 0 ? 1 : -1) * geometry.size.width * 0.3
                                }
                                onCommit(direction)
                                withAnimation(reduceMotion ? nil : .spring(response: 0.38, dampingFraction: 0.9)) { settling = 0 }
                            }
                        }
                )
        }
        .clipped()
        .onChange(of: revision) { _, _ in
            session?.isInvalidated = true
            commitTask?.cancel()
            commitTask = nil
            withAnimation(reduceMotion ? nil : NowPlayingMotion.page) { drag = 0; settling = 0 }
        }
        .onChange(of: enabled) { _, enabled in
            guard !enabled else { return }
            session?.isInvalidated = true
            commitTask?.cancel()
            commitTask = nil
            withAnimation(reduceMotion ? nil : NowPlayingMotion.page) { drag = 0; settling = 0 }
        }
        .onChange(of: isDragging) { _, active in
            if !active {
                // onEnded gets first refusal. A cancelled recognizer has no
                // onEnded; clear its session on the following main-loop turn.
                DispatchQueue.main.async {
                    guard !isDragging else { return }
                    session = nil
                    withAnimation(reduceMotion ? nil : NowPlayingMotion.page) { drag = 0 }
                }
            }
        }
        .onDisappear { commitTask?.cancel(); commitTask = nil; session = nil; drag = 0; settling = 0 }
    }
}
