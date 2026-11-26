import CoreText
import PutioCore
import SnapshotTesting
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
    static let regularWidth: CGFloat = 820
    static let scale: CGFloat = 2
  #endif

  static func sizeClass(forWidth width: CGFloat) -> UserInterfaceSizeClass {
    #if os(tvOS)
      .regular
    #else
      width >= regularWidth ? .regular : .compact
    #endif
  }

  static var isRecording: Bool {
    ["all", "failed"].contains(ProcessInfo.processInfo.environment["SNAPSHOT_TESTING_RECORD"])
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
    if ProcessInfo.processInfo.environment["PUTIO_REQUIRE_BRAND_FONTS"] == "1" && !available {
      throw SnapshotFailure("brand fonts are required here but failed to register")
    }
    try XCTSkipUnless(
      available,
      "rendered with system fonts; brand baseline comparison requires mise run fonts-setup"
    )
  }

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
  static func render(
    page: PutioComponentGallery.Page,
    width: CGFloat = SnapshotEnvironment.width
  ) throws -> UIImage {
    _ = SnapshotEnvironment.registersBrandFonts
    let controller = UIHostingController(
      rootView: PutioComponentGallery.snapshotContent(page: page)
        .environment(\.colorScheme, .dark)
        .environment(\.horizontalSizeClass, SnapshotEnvironment.sizeClass(forWidth: width))
    )
    controller.overrideUserInterfaceStyle = .dark
    let view = try XCTUnwrap(controller.view)
    view.backgroundColor = .clear
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

  static let comparison: Snapshotting<UIImage, UIImage> = {
    var strategy = Snapshotting<UIImage, UIImage>.image(
      precision: PixelTolerance.matchingPixels,
      scale: SnapshotEnvironment.scale
    )
    let exact = strategy.diffing.diffV2
    strategy.diffing.diffV2 = { reference, rendered in
      PixelTolerance.matches(reference, rendered) ? nil : exact(reference, rendered)
    }
    return strategy
  }()

  private static func capture(_ controller: UIViewController, size: CGSize) throws -> UIImage {
    let view = try XCTUnwrap(controller.view)
    view.backgroundColor = .clear
    let traits = UITraitCollection { $0.displayScale = SnapshotEnvironment.scale }
    #if os(tvOS)
      try awaitKeyWindowOnRenderServer()
      let strategy = Snapshotting<UIViewController, UIImage>.image(
        on: .tv,
        drawHierarchyInKeyWindow: true,
        size: size,
        traits: traits
      )
    #else
      let strategy = Snapshotting<UIViewController, UIImage>.image(size: size, traits: traits)
    #endif
    var image: UIImage?
    strategy.snapshot(controller).run { image = $0 }
    return try XCTUnwrap(image, "the snapshot strategy did not render synchronously")
  }

  #if os(tvOS)
    private static var keyWindowDraws = false

    private static func awaitKeyWindowOnRenderServer() throws {
      guard !keyWindowDraws else { return }
      let deadline = Date.now.addingTimeInterval(30)
      repeat {
        if let window = UIApplication.shared.connectedScenes
          .compactMap({ $0 as? UIWindowScene })
          .filter({ $0.activationState == .foregroundActive })
          .flatMap(\.windows)
          .first(where: \.isKeyWindow),
          !window.bounds.isEmpty
        {
          var drawn = false
          _ = UIGraphicsImageRenderer(bounds: window.bounds).image { _ in
            drawn = window.drawHierarchy(in: window.bounds, afterScreenUpdates: true)
          }
          if drawn {
            keyWindowDraws = true
            return
          }
        }
        RunLoop.current.run(until: Date.now.addingTimeInterval(0.1))
      } while Date.now < deadline
      throw SnapshotFailure("the host app's key window did not become active and drawable in 30 s")
    }
  #endif
}

struct SnapshotFailure: Error, CustomStringConvertible {
  let description: String

  init(_ description: String) {
    self.description = description
  }
}

extension XCTestCase {
  @MainActor
  func assertRenderingSnapshot<Content: View>(
    name: String,
    view: Content,
    size: CGSize,
    dynamicTypeSize: DynamicTypeSize = .large,
    file: StaticString = #filePath,
    testName: String = #function,
    line: UInt = #line
  ) throws -> UIImage {
    let rendered = try SnapshotRenderer.render(
      view: view,
      size: size,
      dynamicTypeSize: dynamicTypeSize
    )
    try assertBaseline(rendered, named: name, file: file, testName: testName, line: line)
    return rendered
  }

  @MainActor
  func assertBaseline(
    _ image: UIImage,
    named name: String,
    file: StaticString = #filePath,
    testName: String = #function,
    line: UInt = #line
  ) throws {
    try SnapshotEnvironment.requireBrandFontsForBaseline()
    assertSnapshot(
      of: image,
      as: SnapshotRenderer.comparison,
      named: name,
      file: file,
      testName: testName,
      line: line
    )
  }
}

enum PixelTolerance {
  static let matchingPixels: Float = 0.9975
  static let channelDelta = 2

  static func matches(_ reference: UIImage, _ rendered: UIImage) -> Bool {
    guard let lhs = rgba(reference), let rhs = rgba(rendered),
      reference.cgImage?.width == rendered.cgImage?.width, lhs.count == rhs.count
    else { return false }
    let budget = Int(Float(lhs.count / 4) * (1 - matchingPixels))
    var differing = 0
    lhs.withUnsafeBufferPointer { lhs in
      rhs.withUnsafeBufferPointer { rhs in
        var index = 0
        while index < lhs.count, differing <= budget {
          for channel in index..<index + 4
          where abs(Int(lhs[channel]) - Int(rhs[channel])) > channelDelta {
            differing += 1
            break
          }
          index += 4
        }
      }
    }
    return differing <= budget
  }

  private static func rgba(_ image: UIImage) -> [UInt8]? {
    guard let cgImage = image.cgImage, let space = CGColorSpace(name: CGColorSpace.sRGB) else {
      return nil
    }
    let width = cgImage.width
    let height = cgImage.height
    var bytes = [UInt8](repeating: 0, count: width * height * 4)
    let drawn = bytes.withUnsafeMutableBytes { buffer -> Bool in
      guard
        let context = CGContext(
          data: buffer.baseAddress, width: width, height: height, bitsPerComponent: 8,
          bytesPerRow: width * 4, space: space,
          bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
      else { return false }
      context.draw(cgImage, in: CGRect(x: 0, y: 0, width: width, height: height))
      return true
    }
    return drawn ? bytes : nil
  }
}
