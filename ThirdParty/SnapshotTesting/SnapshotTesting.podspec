Pod::Spec.new do |s|
  s.name = "SnapshotTesting"
  s.version = "1.17.2"
  s.summary = "Point-Free snapshot testing (vendored podspec; upstream is SPM-only past 1.9)."
  s.homepage = "https://github.com/pointfreeco/swift-snapshot-testing"
  s.license = { :type => "MIT", :file => "LICENSE" }
  s.authors = "Point-Free"
  s.source = { :git => "https://github.com/pointfreeco/swift-snapshot-testing.git", :tag => "1.17.2" }
  s.swift_version = "5.9"
  s.ios.deployment_target = "13.0"
  s.source_files = "Sources/SnapshotTesting/**/*.swift"
  # Swift Testing trait uses an experimental API removed from modern
  # toolchains; XCTest is the only runner used here.
  s.exclude_files = "Sources/SnapshotTesting/SnapshotsTestTrait.swift"
  s.weak_frameworks = "XCTest"
  s.pod_target_xcconfig = { "ENABLE_TESTING_SEARCH_PATHS" => "YES" }
end
