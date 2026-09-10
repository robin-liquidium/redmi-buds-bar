import SwiftUI
import MediaCore

struct NowPlayingView: View {
    @ObservedObject var media: NowPlayingController

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            if let track = media.track {
                HStack(spacing: 12) {
                    Group {
                        if let artwork = media.artwork {
                            Image(nsImage: artwork).resizable().scaledToFill()
                        } else {
                            Image(systemName: "music.note").font(.title2)
                                .frame(maxWidth: .infinity, maxHeight: .infinity)
                                .background(.quaternary)
                        }
                    }
                    .frame(width: 64, height: 64)
                    .clipShape(RoundedRectangle(cornerRadius: 8))
                    .accessibilityHidden(true)
                    VStack(alignment: .leading, spacing: 4) {
                        Text(track.title).font(.subheadline.weight(.semibold)).lineLimit(1).help(track.title)
                        if let artist = track.artist, !artist.isEmpty {
                            Text(artist).font(.caption).foregroundStyle(.secondary).lineLimit(1).help(artist)
                        }
                        Button(action: media.openSource) {
                            HStack(spacing: 4) {
                                if let icon = media.sourceIcon { Image(nsImage: icon).resizable().frame(width: 12, height: 12) }
                                Text(media.sourceName).lineLimit(1)
                            }.font(.caption2).foregroundStyle(.secondary)
                        }
                        .buttonStyle(.plain)
                        .help("Open \(media.sourceName)")
                        .accessibilityLabel("Open \(media.sourceName)")
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                HStack(spacing: 28) {
                    Spacer(minLength: 0)
                    playbackButton("Previous track", symbol: "backward.end.fill", action: media.previousTrack)
                        .disabled(track.prohibitsSkip == true)
                    playbackButton(track.playing ? "Pause" : "Play", symbol: track.playing ? "pause.fill" : "play.fill", large: true, action: media.togglePlayback)
                        .keyboardShortcut(.space, modifiers: [])
                    playbackButton("Next track", symbol: "forward.end.fill", action: media.nextTrack)
                        .disabled(track.prohibitsSkip == true)
                    Spacer(minLength: 0)
                }
                if track.duration > 0 {
                    PlaybackTimeline(track: track, media: media)
                        .id([track.bundleIdentifier, track.title, track.album ?? ""])
                }
            } else {
                HStack(spacing: 10) {
                    Image(systemName: "music.note").font(.title3).foregroundStyle(.secondary)
                    VStack(alignment: .leading, spacing: 3) {
                        Text("Nothing playing").font(.subheadline.weight(.medium))
                        Text("Start music or a video in any app.").font(.caption).foregroundStyle(.secondary)
                    }
                }.padding(.vertical, 4)
            }
            if let error = media.error {
                Text(error).font(.caption).foregroundStyle(.orange).fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .background(.quaternary.opacity(0.45), in: RoundedRectangle(cornerRadius: 12))
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Now playing")
    }

    private func playbackButton(_ title: String, symbol: String, large: Bool = false, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            Image(systemName: symbol)
                .font(.system(size: large ? 24 : 17, weight: .semibold))
                .frame(width: 36, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(title)
        .accessibilityLabel(title)
        .accessibilityIdentifier("media.\(title.lowercased().replacingOccurrences(of: " ", with: "-"))")
    }
}

private struct PlaybackTimeline: View {
    let track: NowPlayingTrack
    @ObservedObject var media: NowPlayingController
    @State private var scrubPosition: Double?

    var body: some View {
        TimelineView(.animation(minimumInterval: 1, paused: !track.playing)) { context in
            let elapsed = scrubPosition ?? track.elapsed(at: context.date)
            VStack(spacing: 2) {
                Slider(value: Binding(get: { elapsed }, set: { scrubPosition = $0 }), in: 0...track.duration) { editing in
                    if !editing, let position = scrubPosition {
                        media.seek(to: position)
                        scrubPosition = nil
                    }
                }
                .controlSize(.mini)
                .disabled(track.prohibitsSkip == true)
                .accessibilityLabel("Playback position")
                .accessibilityValue(time(elapsed))
                .accessibilityIdentifier("media.position")
                HStack {
                    Text(time(elapsed))
                    Spacer()
                    Text("−\(time(track.duration - elapsed))")
                }.font(.caption2).monospacedDigit().foregroundStyle(.secondary)
            }
        }
    }

    private func time(_ seconds: Double) -> String {
        let value = Int(max(0, seconds))
        return String(format: "%d:%02d", value / 60, value % 60)
    }
}
