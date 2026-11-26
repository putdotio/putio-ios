import AVFoundation
import Foundation
import XCTest

@testable import PutioCore

final class PlaybackFailureAVFoundationTests: XCTestCase {
  func testAVFoundationErrorsMapOntoTheContractsFailureModes() {
    let modes: [(AVError.Code, PutioPlaybackFailureMode)] = [
      (.decodeFailed, .decode), (.decoderNotFound, .decode),
      (.decoderTemporarilyUnavailable, .decode), (.undecodableMediaData, .decode),
      (.fileFormatNotRecognized, .unsupportedSource), (.fileFailedToParse, .unsupportedSource),
      (.invalidSourceMedia, .unsupportedSource), (.failedToParse, .unsupportedSource),
      (.incompatibleAsset, .unsupportedSource),
      (.operationNotSupportedForAsset, .unsupportedSource),
      (.contentIsProtected, .drm), (.contentIsNotAuthorized, .drm),
      (.applicationIsNotAuthorized, .drm), (.failedToLoadMediaData, .load),
      (.serverIncorrectlyConfigured, .load), (.unknown, .unknown),
    ]
    for (code, mode) in modes {
      let error = PutioPlayerError(
        avPlayerError: NSError(domain: AVFoundationErrorDomain, code: code.rawValue))
      XCTAssertEqual(error.mode, mode, "AVError \(code.rawValue)")
    }
    XCTAssertEqual(
      PutioPlayerError(
        avPlayerError: NSError(domain: NSURLErrorDomain, code: NSURLErrorCancelled)
      ).mode, .aborted)
    XCTAssertEqual(PutioPlayerError(avPlayerError: nil).mode, .unknown)
  }
}
