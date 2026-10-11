Pod::Spec.new do |s|
  s.name = "PutioSDK"
  s.version = "4.1.0"
  s.summary = "Swift SDK for the put.io API (vendored podspec; upstream is SPM-only since 4.0.0)."
  s.homepage = "https://github.com/putdotio/putio-sdk-swift"
  s.license = { :type => "MIT", :file => "LICENSE" }
  s.authors = { "put.io" => "devs@put.io" }
  s.source = { :git => "https://github.com/putdotio/putio-sdk-swift.git", :commit => "640510a31bcead483dad39db835b44d141a5b4bd" }
  s.swift_version = "5.0"
  s.ios.deployment_target = "26.0"
  s.source_files = "PutioSDK/Classes/**/*.swift"
  # Matches the upcoming feature Package.swift enables for the SDK target.
  s.pod_target_xcconfig = { "SWIFT_UPCOMING_FEATURE_NONISOLATED_NONSENDING_BY_DEFAULT" => "YES" }
end
