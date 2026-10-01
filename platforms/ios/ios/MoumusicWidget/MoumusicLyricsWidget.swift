import Foundation
import SwiftUI
import WidgetKit
import ActivityKit
import KumoneIOSFeature

@available(iOS 16.1, *)
private struct PlaybackArtwork: View {
    let urlString: String?
    let size: CGFloat

    var body: some View {
        Group {
            if let urlString, let url = URL(string: urlString) {
                AsyncImage(url: url) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    } else {
                        placeholder
                    }
                }
            } else {
                placeholder
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.22, style: .continuous))
    }

    private var placeholder: some View {
        ZStack {
            Color.white.opacity(0.14)
            Image(systemName: "music.note")
                .font(.system(size: size * 0.42, weight: .semibold))
                .foregroundStyle(.secondary)
        }
    }
}

@available(iOS 16.1, *)
private struct PlaybackProgressView: View {
    let state: MoumusicPlaybackActivityAttributes.ContentState

    var body: some View {
        if state.isPlaying {
            ProgressView(timerInterval: playbackInterval, countsDown: false)
                .tint(.red)
        } else {
            ProgressView(
                value: state.duration > 0 ? state.elapsed : 0,
                total: max(state.duration, 1)
            )
            .tint(.red)
        }
    }

    private var playbackInterval: ClosedRange<Date> {
        state.playbackInterval
    }
}

@available(iOS 16.1, *)
private struct PlaybackActivityLockScreenView: View {
    let state: MoumusicPlaybackActivityAttributes.ContentState

    var body: some View {
        HStack(spacing: 12) {
            PlaybackArtwork(urlString: state.artworkURL, size: 52)
            VStack(alignment: .leading, spacing: 3) {
                Text(state.title)
                    .font(.headline.weight(.semibold))
                    .lineLimit(1)
                Text(state.artist.isEmpty ? "iMusic" : state.artist)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                PlaybackProgressView(state: state)
            }
            Spacer(minLength: 0)
            Image(systemName: state.isPlaying ? "waveform" : "pause.fill")
                .font(.headline)
                .foregroundStyle(.secondary)
        }
        .padding(.horizontal, 16)
        .padding(.vertical, 12)
        .activityBackgroundTint(.black.opacity(0.86))
        .activitySystemActionForegroundColor(.white)
    }
}

@available(iOS 16.1, *)
struct MoumusicPlaybackLiveActivity: Widget {
    var body: some WidgetConfiguration {
        ActivityConfiguration(for: MoumusicPlaybackActivityAttributes.self) { context in
            PlaybackActivityLockScreenView(state: context.state)
                .widgetURL(URL(string: "imusic://now-playing"))
        } dynamicIsland: { context in
            DynamicIsland {
                DynamicIslandExpandedRegion(.leading) {
                    PlaybackArtwork(urlString: context.state.artworkURL, size: 42)
                }
                DynamicIslandExpandedRegion(.trailing) {
                    Image(systemName: context.state.isPlaying ? "waveform" : "pause.fill")
                        .font(.headline)
                        .foregroundStyle(.secondary)
                }
                DynamicIslandExpandedRegion(.center) {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(context.state.title)
                            .font(.headline.weight(.semibold))
                            .lineLimit(1)
                        Text(context.state.artist)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                    }
                }
                DynamicIslandExpandedRegion(.bottom) {
                    PlaybackProgressView(state: context.state)
                }
            } compactLeading: {
                PlaybackArtwork(urlString: context.state.artworkURL, size: 22)
            } compactTrailing: {
                Image(systemName: context.state.isPlaying ? "waveform" : "pause.fill")
                    .font(.caption.weight(.semibold))
            } minimal: {
                Image(systemName: context.state.isPlaying ? "waveform" : "music.note")
                    .font(.caption.weight(.semibold))
            }
            .widgetURL(URL(string: "imusic://now-playing"))
            .keylineTint(.red)
        }
    }
}

@main
struct MoumusicWidgetBundle: WidgetBundle {
    var body: some Widget {
        if #available(iOS 16.1, *) {
            MoumusicPlaybackLiveActivity()
        }
    }
}
