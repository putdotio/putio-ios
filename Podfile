platform :ios, '13.0'

target 'Putio' do
  use_frameworks!

  pod 'Alamofire', '~> 5.5.0'
  pod 'google-cast-sdk-no-bluetooth'
  pod 'Intercom', '14.0.0'
  pod 'KeychainAccess'
  pod 'NFDownloadButton', '0.0.2'
  pod 'PutioAPI', :git => 'https://github.com/putdotio/putio-swift.git', :tag => '1.5.0'
  pod 'RealmSwift', '~> 3.19.0'
  pod 'Sentry', :git => 'https://github.com/getsentry/sentry-cocoa.git', :tag => '7.9.0'
  pod 'StatefulViewController', '~> 3.0'
  pod 'SwiftGifOrigin', '~> 1.6.1'
  pod 'SwiftLint'
  pod 'SwiftyBeaver'
  pod 'SwiftyJSON'
  pod 'VTAcknowledgementsViewController'
  pod "KeyboardAvoidingView", '~> 5.2'
end

post_install do |installer|
  installer.pods_project.targets.each do |target|
    target.build_configurations.each do |config|
      config.build_settings.delete 'IPHONEOS_DEPLOYMENT_TARGET'
    end
  end

  installer.pods_project.build_configurations.each do |config|
    config.build_settings["EXCLUDED_ARCHS[sdk=iphonesimulator*]"] = "arm64"
  end
end