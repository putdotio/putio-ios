import Foundation
import PutioCore
import XCTest

@testable import Putio

@MainActor
final class AccountSecurityViewTests: XCTestCase {
  func testExportedRecoveryCodeFileHoldsOnlyUnusedCodesAsUTF8() throws {
    let export = PutioRecoveryCodesExport()
    export.begin(
      codes: [
        PutioTwoFactorRecoveryCode(code: "a-1", isUsed: false),
        PutioTwoFactorRecoveryCode(code: "a-2", isUsed: true),
        PutioTwoFactorRecoveryCode(code: "ü-3", isUsed: false),
      ], at: Date(timeIntervalSince1970: 1_700_000_000.5))
    XCTAssertEqual(export.filename, "putio-two-factor-recovery-codes_1700000000500.txt")
    let file = try XCTUnwrap(export.pending?.fileWrapper())
    XCTAssertTrue(file.isRegularFile)
    let contents = try XCTUnwrap(file.regularFileContents)
    XCTAssertEqual(String(data: contents, encoding: .utf8), "a-1\nü-3")
  }

  func testFailedRecoveryCodeSaveStaysVisibleUntilASaveSucceeds() {
    let codes = [PutioTwoFactorRecoveryCode(code: "a-1", isUsed: false)]
    let export = PutioRecoveryCodesExport()
    export.begin(codes: codes)
    export.finish(.failure(CocoaError(.fileWriteNoPermission)))
    XCTAssertNil(export.pending)
    XCTAssertEqual(export.failure, PutioRecoveryCodesExport.failureMessage)
    XCTAssertFalse(
      PutioRecoveryCodesExport.failureMessage.contains("a-1"), "the failure exposed a code")

    export.begin(codes: codes)
    export.cancel()
    XCTAssertEqual(export.failure, PutioRecoveryCodesExport.failureMessage)
    export.begin(codes: codes)
    export.finish(.failure(CocoaError(.userCancelled)))
    XCTAssertEqual(export.failure, PutioRecoveryCodesExport.failureMessage)

    export.begin(codes: codes)
    export.finish(.success(URL(fileURLWithPath: "/tmp/saved.txt")))
    XCTAssertNil(export.failure)
    XCTAssertNil(export.pending)

    export.begin(codes: codes)
    export.finish(.failure(CocoaError(.userCancelled)))
    XCTAssertNil(export.failure, "dismissing the picker was reported as a failure")
  }
}
