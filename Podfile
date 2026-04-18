platform :ios, '16.0'

target 'Putio' do
  use_frameworks!

  pod 'Alamofire', '~> 5.5.0'
  pod 'google-cast-sdk-no-bluetooth-xcframework', '4.8.0'
  pod 'Intercom', '14.0.0'
  pod 'KeychainAccess'
  pod 'NFDownloadButton', '0.0.2'
  pod 'PutioAPI', :git => 'https://github.com/putdotio/putio-swift.git', :tag => '1.5.0'
  pod 'RealmSwift', '10.54.6'
  pod 'Sentry', :git => 'https://github.com/getsentry/sentry-cocoa.git', :tag => '8.58.0'
  pod 'StatefulViewController', '~> 3.0'
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
end
