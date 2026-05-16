import SwiftUI
import AVKit

/// Diagnostics screen. A native `List` of test streams; tap to launch the
/// system AVPlayerViewController.
struct TestStream: Identifiable, Hashable {
    let id: String
    let title: String
    let kind: Kind
    let url: URL

    enum Kind: Hashable { case hls, mp4 }

    static let all: [TestStream] = [
        TestStream(
            id: "apple-presentation",
            title: "Apple presentation HLS",
            kind: .hls,
            url: URL(string: "https://devstreaming-cdn.apple.com/videos/streaming/examples/bipbop_16x9/bipbop_16x9_variant.m3u8")!
        ),
        TestStream(
            id: "bipbop",
            title: "Mux BipBop HLS",
            kind: .hls,
            url: URL(string: "https://test-streams.mux.dev/x36xhzz/x36xhzz.m3u8")!
        ),
        TestStream(
            id: "sintel",
            title: "Sintel (MP4)",
            kind: .mp4,
            url: URL(string: "https://storage.googleapis.com/exoplayer-test-media-0/sintel/sintel-1024-surround.mp4")!
        ),
        TestStream(
            id: "big-buck-bunny",
            title: "Big Buck Bunny (MP4)",
            kind: .mp4,
            url: URL(string: "https://commondatastorage.googleapis.com/gtv-videos-bucket/sample/BigBuckBunny.mp4")!
        ),
    ]
}

struct DiagnosticsView: View {
    @State private var selected: TestStream?

    var body: some View {
        List(TestStream.all) { stream in
            Button {
                selected = stream
            } label: {
                Label {
                    VStack(alignment: .leading, spacing: 2) {
                        Text(stream.title)
                        Text(stream.kind == .hls ? "HLS" : "MP4")
                            .font(.callout)
                            .foregroundStyle(.secondary)
                    }
                } icon: {
                    Image(systemName: "play.rectangle.fill")
                        .foregroundStyle(.tint)
                }
                .padding(.vertical, PutSpacing.xs)
            }
        }
        .navigationTitle("Diagnostics")
        .fullScreenCover(item: $selected) { stream in
            DiagnosticsPlayerView(url: stream.url)
        }
    }
}

struct DiagnosticsPlayerView: View {
    let url: URL

    var body: some View {
        SystemPlayerView(url: url, startAt: 0)
            .ignoresSafeArea()
    }
}
