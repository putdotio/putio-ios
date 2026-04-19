platform :ios, '26.0'

target 'Putio' do
  use_frameworks!

  pod 'Alamofire', '~> 5.11'
  pod 'google-cast-sdk-no-bluetooth-xcframework', '4.8.0'
  pod 'Intercom', '19.5.7'
  pod 'RoutableLogger', '13.0.0'
  pod 'KeychainAccess'
  pod 'PutioSDK', :git => 'https://github.com/putdotio/putio-sdk-swift.git', :tag => '2.0.0'
  pod 'RealmSwift', '20.0.4'
  pod 'Sentry', '9.10.0'
  pod 'StatefulViewController', '~> 3.0'
  pod 'SwiftLint', '~> 0.63'
  pod 'SwiftyBeaver', '~> 2.1'
  pod 'SwiftyJSON', '5.0.2'
  pod 'ViewState', '3.0.0'
  pod 'VTAcknowledgementsViewController'
  pod "KeyboardAvoidingView", '~> 5.2'
  
  target 'PutioTests' do
    inherit! :search_paths
  end
end

def patch_keyboard_avoiding_view_loader!
  file_path = File.join(__dir__, "Pods", "KeyboardAvoidingView", "KeyboardAvoidingView", "Classes", "KeyboardAvoidingViewLoader.m")

  File.write(
    file_path,
    <<~'OBJC'
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
  )
end

post_install do |installer|
  patch_keyboard_avoiding_view_loader!
  installer.pods_project.targets.each do |target|
    target.build_configurations.each do |config|
      config.build_settings.delete 'IPHONEOS_DEPLOYMENT_TARGET'
    end
  end
end
