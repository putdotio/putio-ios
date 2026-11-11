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

  static let comparison = Snapshotting<UIImage, UIImage>.image(
    precision: 0.9975,
    scale: SnapshotEnvironment.scale
  )

  private static func capture(_ controller: UIViewController, size: CGSize) throws -> UIImage {
    let view = try XCTUnwrap(controller.view)
    view.backgroundColor = .clear
    let traits = UITraitCollection { $0.displayScale = SnapshotEnvironment.scale }
    #if os(tvOS)
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
