import CoreText
import PutioCore
import SwiftUI
import UIKit
import XCTest

enum SnapshotEnvironment {
  static let repositoryRoot = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .deletingLastPathComponent()

  #if os(tvOS)
    static let platform = "tvos"
    static let width: CGFloat = 1920
    static let scale: CGFloat = 1
  #else
    static let platform = "ios"
    static let width: CGFloat = 390
    static let scale: CGFloat = 2
  #endif

  static var isRecording: Bool {
    ProcessInfo.processInfo.environment["PUTIO_SNAPSHOT_RECORD"] == "1"
  }

  static var baselineDirectory: URL {
    repositoryRoot
      .appending(path: "Tests/ComponentSnapshots/__Snapshots__")
      .appending(path: platform)
  }

  static var failureDirectory: URL {
    repositoryRoot.appending(path: "build/snapshot-failures").appending(path: platform)
  }

  // The test runner is not an app, so the brand faces bundled by the app
  // targets are registered from the checksummed local font directory instead.
  static let registersBrandFonts: Void = {
    let directory = repositoryRoot.appending(path: "Resources/BrandFonts")
    let urls =
      (try? FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil))?.filter { $0.pathExtension == "otf" } ?? []
    precondition(!urls.isEmpty, "brand fonts are missing; run mise run fonts-setup")
    CTFontManagerRegisterFontURLs(urls as CFArray, .process, true, nil)
  }()
}

@MainActor
enum SnapshotRenderer {
  static func render(page: PutioComponentGallery.Page) throws -> UIImage {
    _ = SnapshotEnvironment.registersBrandFonts
    let controller = UIHostingController(
      rootView: PutioComponentGallery.snapshotContent(page: page)
        .environment(\.colorScheme, .dark)
    )
    controller.overrideUserInterfaceStyle = .dark
    let view = try XCTUnwrap(controller.view)
    view.backgroundColor = .clear
    let width = SnapshotEnvironment.width
    let height: CGFloat
    if let viewport = PutioComponentGallery.snapshotViewportHeight(page: page) {
      height = viewport
    } else {
      let target = controller.sizeThatFits(
        in: CGSize(width: width, height: .greatestFiniteMagnitude))
      height = max(target.height, 1).rounded(.up)
    }
    let size = CGSize(width: width, height: height)
    let window = UIWindow(frame: CGRect(origin: .zero, size: size))
    window.rootViewController = controller
    window.isHidden = false
    view.frame = window.bounds
    window.layoutIfNeeded()

    let format = UIGraphicsImageRendererFormat()
    format.scale = SnapshotEnvironment.scale
    format.opaque = false
    let image = UIGraphicsImageRenderer(size: size, format: format).image { context in
      view.layer.render(in: context.cgContext)
    }
    window.isHidden = true
    return image
  }
}

struct SnapshotPixels {
  let width: Int
  let height: Int
  let rgba: [UInt8]

  init(cgImage: CGImage) throws {
    let width = cgImage.width
    let height = cgImage.height
    self.width = width
    self.height = height
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    let rendered = bytes.withUnsafeMutableBytes { buffer -> Bool in
      guard
        let context = CGContext(
          data: buffer.baseAddress,
          width: width,
          height: height,
          bitsPerComponent: 8,
          bytesPerRow: width * 4,
          space: CGColorSpaceCreateDeviceRGB(),
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            | CGBitmapInfo.byteOrder32Big.rawValue
        )
      else { return false }
      context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
      return true
    }
    guard rendered else {
      throw SnapshotFailure("could not rasterize snapshot pixels")
    }
    rgba = bytes
  }

  // Tolerates antialiasing drift between Simulator runtime versions: a small
  // per-channel delta everywhere, and larger deltas on a bounded share of
  // glyph-edge pixels.
  func matches(_ other: SnapshotPixels) -> SnapshotComparison {
    guard width == other.width, height == other.height else {
      return SnapshotComparison(
        matches: false,
        detail:
          "size mismatch: baseline \(other.width)x\(other.height), rendered \(width)x\(height)"
      )
    }
    let channelTolerance = 8
    let maximumDifferingRatio = 0.01
    var differing = 0
    for index in stride(from: 0, to: rgba.count, by: 4) {
      for channel in 0..<4 {
        let delta = abs(Int(rgba[index + channel]) - Int(other.rgba[index + channel]))
        if delta > channelTolerance {
          differing += 1
          break
        }
      }
    }
    let ratio = Double(differing) / Double(width * height)
    return SnapshotComparison(
      matches: ratio <= maximumDifferingRatio,
      detail: String(
        format: "%d of %d pixels differ beyond tolerance (%.3f%%)",
        differing, width * height, ratio * 100
      )
    )
  }
}

struct SnapshotComparison {
  let matches: Bool
  let detail: String
}

struct SnapshotFailure: Error, CustomStringConvertible {
  let description: String

  init(_ description: String) {
    self.description = description
  }
}
