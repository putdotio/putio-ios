import PutioCore
import XCTest

@testable import Putio

final class HarnessLaunchTests: XCTestCase {
  func testOnlyDebugBuildsHonorHarnessLaunchArguments() {
    XCTAssertTrue(HarnessLaunch.isEnabled, "feature tests run the Debug app")
    for scenario in HarnessScenario.allCases {
      let launch = ["Putio", HarnessScenario.launchArgument, scenario.rawValue]
      XCTAssertEqual(
        HarnessScenario.parse(arguments: HarnessLaunch.honoredArguments(launch, isEnabled: true)),
        scenario)
      XCTAssertEqual(
        HarnessScenario.parse(arguments: HarnessLaunch.honoredArguments(launch, isEnabled: false)),
        .signedOut)
    }
  }
}
