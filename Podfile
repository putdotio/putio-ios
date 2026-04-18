platform :ios, '16.0'

target 'Putio' do
  use_frameworks!

  pod 'Alamofire', '~> 5.5.0'
  pod 'google-cast-sdk-no-bluetooth-xcframework', '4.8.0'
  pod 'Intercom', '19.5.7'
  pod 'KeychainAccess'
  pod 'PutioSDK', '1.6.1'
  pod 'RealmSwift', '20.0.4'
  pod 'Sentry', '9.10.0'
  pod 'StatefulViewController', '~> 3.0'
  pod 'SwiftLint', '~> 0.63'
  pod 'SwiftyBeaver', '~> 2.1'
  pod 'SwiftyJSON', '5.0.2'
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
