import SwiftUI
import AVKit

/// Diagnostics screen. Matches `15-diagnostics-list` and `16-diagnostics-player`.
/// No Android-style debug JSON overlay — tvOS uses the AVPlayer chrome only.
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
        VStack(alignment: .leading, spacing: 0) {
            PutScreenHeader {
                Text("Diagnostics")
            }

            ScrollView {
                LazyVStack(spacing: PutSpacing.xs) {
                    ForEach(TestStream.all) { stream in
                        Button { selected = stream } label: {
                            PutListRow(
                                icon: stream.kind == .hls ? "play" : "video",
                                title: stream.title,
                                subtitle: stream.kind == .hls ? "HLS" : "MP4"
                            )
                        }
                        .buttonStyle(PutFocusableRowStyle())
                    }
                }
                .padding(.horizontal, PutSpacing.xl)
                .padding(.bottom, PutSpacing.xl)
            }
        }
        .background(Color.put.bg)
        .fullScreenCover(item: $selected) { stream in
            DiagnosticsPlayerView(url: stream.url)
        }
    }
}

struct DiagnosticsPlayerView: View {
    let url: URL
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        SystemPlayerView(url: url, startAt: 0)
            .ignoresSafeArea()
    }
}
