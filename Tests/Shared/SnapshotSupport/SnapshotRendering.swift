import CoreText
import PutioCore
import SwiftUI
import UIKit
import XCTest

// Shared by unhosted component snapshots and app-hosted iOS feature snapshots.
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

  @MainActor
  static func requireBrandFontsForBaseline() throws {
    let names =
      ["GTAmerica-Rg", "GTAmerica-Md", "GTAmerica-Bd", "GTAmerica-Bl"]
      + (platform == "ios" ? ["BerkeleyMonoVariable-Regular"] : [])
    let available = names.allSatisfy { UIFont(name: $0, size: 16) != nil }
    if isRecording && !available {
      throw SnapshotFailure("recording brand baselines requires mise run fonts-setup")
    }
    try XCTSkipUnless(
      available,
      "rendered with system fonts; brand baseline comparison requires mise run fonts-setup"
    )
  }

  // The test runner is not an app, so the brand faces bundled by the app
  // targets are registered from the checksummed local font directory instead.
  static let registersBrandFonts: Void = {
    let directory = repositoryRoot.appending(path: "Resources/BrandFonts")
    let urls =
      (try? FileManager.default.contentsOfDirectory(
        at: directory, includingPropertiesForKeys: nil))?.filter { $0.pathExtension == "otf" } ?? []
    if !urls.isEmpty {
      CTFontManagerRegisterFontURLs(urls as CFArray, .process, true, nil)
    }
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
    return try capture(controller, size: CGSize(width: width, height: height))
  }

  static func render<Content: View>(
    view content: Content,
    size: CGSize,
    dynamicTypeSize: DynamicTypeSize = .large
  ) throws -> UIImage {
    _ = SnapshotEnvironment.registersBrandFonts
    let controller = UIHostingController(
      rootView:
        content
        .environment(\.colorScheme, .dark)
        .dynamicTypeSize(dynamicTypeSize)
    )
    controller.overrideUserInterfaceStyle = .dark
    return try capture(controller, size: size)
  }

  private static func capture(_ controller: UIViewController, size: CGSize) throws -> UIImage {
    let view = try XCTUnwrap(controller.view)
    view.backgroundColor = .clear
    let window = try makeWindow(size: size)
    window.rootViewController = controller
    window.isHidden = false
    view.frame = window.bounds
    window.layoutIfNeeded()
    defer { window.isHidden = true }

    let format = UIGraphicsImageRendererFormat()
    format.scale = SnapshotEnvironment.scale
    format.opaque = false
    let renderer = UIGraphicsImageRenderer(size: size, format: format)
    #if os(tvOS)
      // tvOS 27 builds bordered controls from Liquid Glass (SDF and backdrop
      // layers) that `CALayer.render(in:)` leaves as undefined solid fills;
      // only the render server rasterizes them, through the host scene.
      var drawn = false
      let image = renderer.image { _ in
        drawn = view.drawHierarchy(in: CGRect(origin: .zero, size: size), afterScreenUpdates: true)
      }
      guard drawn else { throw SnapshotFailure("the render server did not draw the snapshot") }
      return image
    #else
      return renderer.image { context in view.layer.render(in: context.cgContext) }
    #endif
  }

  private static func makeWindow(size: CGSize) throws -> UIWindow {
    #if os(tvOS)
      guard
        let scene = UIApplication.shared.connectedScenes
          .compactMap({ $0 as? UIWindowScene }).first
      else {
        throw SnapshotFailure("tvOS snapshots need an app-hosted test bundle with a window scene")
      }
      let window = UIWindow(windowScene: scene)
      window.frame = CGRect(origin: .zero, size: size)
      return window
    #else
      return UIWindow(frame: CGRect(origin: .zero, size: size))
    #endif
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

// Shared by app-hosted feature snapshots on iOS and tvOS.
extension XCTestCase {
  @MainActor
  func assertRenderingSnapshot<Content: View>(
    name: String,
    view: Content,
    size: CGSize,
    dynamicTypeSize: DynamicTypeSize = .large,
    file: StaticString = #filePath,
    line: UInt = #line
  ) throws -> UIImage {
    let fileManager = FileManager.default
    let baselineURL = SnapshotEnvironment.baselineDirectory.appending(path: "\(name).png")
    let rendered = try SnapshotRenderer.render(
      view: view,
      size: size,
      dynamicTypeSize: dynamicTypeSize
    )
    let renderedData = try XCTUnwrap(rendered.pngData(), "could not encode rendered snapshot")

    try SnapshotEnvironment.requireBrandFontsForBaseline()

    if SnapshotEnvironment.isRecording {
      try fileManager.createDirectory(
        at: SnapshotEnvironment.baselineDirectory,
        withIntermediateDirectories: true
      )
      try renderedData.write(to: baselineURL, options: .atomic)
    }

    guard fileManager.fileExists(atPath: baselineURL.path) else {
      XCTFail(
        "missing baseline \(baselineURL.lastPathComponent); "
          + "run mise run harness -- test --platform \(SnapshotEnvironment.platform) "
          + "--snapshots record",
        file: file,
        line: line
      )
      return rendered
    }

    let baselineImage = try XCTUnwrap(
      UIImage(data: try Data(contentsOf: baselineURL))?.cgImage,
      "could not decode baseline \(baselineURL.lastPathComponent)"
    )
    let renderedImage = try XCTUnwrap(rendered.cgImage, "rendered snapshot has no CGImage")
    let comparison = try SnapshotPixels(cgImage: renderedImage)
      .matches(SnapshotPixels(cgImage: baselineImage))
    if !comparison.matches {
      let failureURL = SnapshotEnvironment.failureDirectory.appending(path: "\(name).png")
      try? fileManager.createDirectory(
        at: SnapshotEnvironment.failureDirectory,
        withIntermediateDirectories: true
      )
      try? renderedData.write(to: failureURL, options: .atomic)
      XCTFail(
        "\(name) diverged from its baseline (\(comparison.detail)); "
          + "rendered image written to \(failureURL.path)",
        file: file,
        line: line
      )
    }
    return rendered
  }
}
