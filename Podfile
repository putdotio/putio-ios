platform :ios, '26.0'

target 'Putio' do
  use_frameworks!

  pod 'Alamofire', '~> 5.11'
  pod 'google-cast-sdk-no-bluetooth-xcframework', '4.8.0'
  pod 'Intercom', '19.5.7'
  pod 'KeychainAccess'
  pod 'PutioSDK', :git => 'https://github.com/putdotio/putio-sdk-swift.git', :branch => 'codex/swift-sdk-modernization'
  pod 'RealmSwift', '20.0.4'
  pod 'Sentry', '9.10.0'
  pod 'StatefulViewController', '~> 3.0'
  pod 'SwiftLint', '~> 0.63'
  pod 'SwiftyBeaver', '~> 2.1'
  pod 'VTAcknowledgementsViewController'
  pod "KeyboardAvoidingView", '~> 5.2'
  
  target 'PutioTests' do
    inherit! :search_paths
  end
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

def remove_flag_from_xcconfig!(file_path, flag)
  return unless File.exist?(file_path)

  contents = File.read(file_path)
  updated_contents = contents.gsub(" #{flag}", "")

  return if updated_contents == contents

  File.chmod(0o644, file_path)
  File.write(file_path, updated_contents)
end

def patch_realm_linker_flags!
  %w[debug release].each do |configuration|
    file_path = File.join(__dir__, "Pods", "Target Support Files", "Realm", "Realm.#{configuration}.xcconfig")
    remove_flag_from_xcconfig!(file_path, '-l"c++"')
  end
end

post_install do |installer|
  patch_keyboard_avoiding_view_loader!
  patch_realm_linker_flags!
  installer.pods_project.targets.each do |target|
    if target.name == "Realm"
      target.shell_script_build_phases.each do |phase|
        next unless phase.name == "Create Symlinks to Header Folders"

        phase.always_out_of_date = "1"
      end
    end

    target.build_configurations.each do |config|
      config.build_settings.delete 'IPHONEOS_DEPLOYMENT_TARGET'
    end
  end
end
