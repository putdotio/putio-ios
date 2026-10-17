ios_deployment_target = '26.0'
platform :ios, ios_deployment_target

target 'Putio' do
  use_frameworks!

  # Held below 4.8.4, which adds a terms-of-service sheet; 4.8.6 also calls
  # api.ipify.org and an experiments service on every launch.
  pod 'google-cast-sdk', '4.8.3'
  pod 'Intercom', '19.9.0'
  pod 'KeychainAccess'
  pod 'PostHog', '3.92.0'
  # Upstream dropped CocoaPods in 4.0.1; ThirdParty/ carries a pinned podspec.
  pod 'PutioSDK', :podspec => 'ThirdParty/PutioSDK/PutioSDK.podspec'
  pod 'RealmSwift', '20.0.6'
  # The last release on trunk; later ones ship through SPM only.
  pod 'Sentry', '9.19.1'
  pod 'StatefulViewController', '~> 3.0'
  pod 'SwiftLint', '~> 0.63'
  pod 'VTAcknowledgementsViewController'
  pod "KeyboardAvoidingView", '~> 5.2'
  
  target 'PutioTests' do
    inherit! :search_paths

    pod 'SnapshotTesting', :podspec => 'ThirdParty/SnapshotTesting/SnapshotTesting.podspec'
  end
end

target 'PutioUITests' do
  use_frameworks!

  # Upstream dropped CocoaPods after 1.9; ThirdParty/ carries a pinned podspec.
  pod 'SnapshotTesting', :podspec => 'ThirdParty/SnapshotTesting/SnapshotTesting.podspec'
end

def patch_keyboard_avoiding_view_loader!
  file_path = File.join(__dir__, "Pods", "KeyboardAvoidingView", "KeyboardAvoidingView", "Classes", "KeyboardAvoidingViewLoader.m")
  contents = <<~'OBJC'
    #import "KeyboardAvoidingViewLoader.h"

    @import Foundation;

    static BOOL KeyboardAvoidingViewIsRunningUnderXCTest(void) {
        NSDictionary<NSString *, NSString *> *environment = NSProcessInfo.processInfo.environment;
        NSArray<NSString *> *keys = @[
            @"XCTestBundlePath",
            @"XCTestConfigurationFilePath",
            @"XCTestSessionIdentifier",
        ];

        for (NSString *key in keys) {
            if (environment[key].length > 0) {
                return YES;
            }
        }

        return NO;
    }

    @implementation KeyboardAvoidingViewLoader

    + (void)load {
        if (KeyboardAvoidingViewIsRunningUnderXCTest()) {
            return;
        }

        Class keyboardManagerClass = NSClassFromString(@"KeyboardManager");
        SEL sharedSelector = NSSelectorFromString(@"shared");
        if (keyboardManagerClass == Nil || ![keyboardManagerClass respondsToSelector:sharedSelector]) {
            return;
        }

    #pragma clang diagnostic push
    #pragma clang diagnostic ignored "-Warc-performSelector-leaks"
        [keyboardManagerClass performSelector:sharedSelector];
    #pragma clang diagnostic pop
    }

    @end
  OBJC

  return unless File.exist?(file_path)
  return if File.read(file_path) == contents

  # CocoaPods may restore pod sources as read-only in CI caches.
  File.chmod(0o644, file_path)
  File.write(file_path, contents)
end

def patch_snapshot_testing_record_issue!
  file_path = File.join(__dir__, "Pods", "SnapshotTesting", "Sources", "SnapshotTesting", "Internal", "RecordIssue.swift")
  contents = <<~'SWIFT'
    import XCTest

    // Patched by Podfile post_install: the upstream Swift Testing branch does
    // not compile in a CocoaPods framework target, and XCTest is the only
    // runner used in this repository.
    @_spi(Internals)
    public func recordIssue(
      _ message: @autoclosure () -> String,
      fileID: StaticString,
      filePath: StaticString,
      line: UInt,
      column: UInt
    ) {
      XCTFail(message(), file: filePath, line: line)
    }
  SWIFT

  return unless File.exist?(file_path)
  return if File.read(file_path) == contents

  File.chmod(0o644, file_path)
  File.write(file_path, contents)
end

post_install do |installer|
  patch_keyboard_avoiding_view_loader!
  patch_snapshot_testing_record_issue!
  installer.pods_project.targets.each do |target|
    if target.name == "Realm"
      target.shell_script_build_phases.each do |phase|
        next unless phase.name == "Create Symlinks to Header Folders"

        phase.always_out_of_date = "1"
      end
    end

    target.build_configurations.each do |config|
      config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = ios_deployment_target
    end
  end
end
