ios_deployment_target = '26.0'
platform :ios, ios_deployment_target

# Every other dependency is a Swift package in Putio.xcodeproj.
target 'Putio' do
  use_frameworks!

  # Held below 4.8.4, which adds a terms-of-service sheet; 4.8.6 also calls
  # api.ipify.org and an experiments service on every launch. Swift Package
  # Manager releases start at 4.8.4.
  pod 'google-cast-sdk', '4.8.3'

  # Three test files import GoogleCast.
  target 'PutioTests' do
    inherit! :search_paths
  end
end

post_install do |installer|
  installer.pods_project.targets.each do |target|
    target.build_configurations.each do |config|
      config.build_settings['IPHONEOS_DEPLOYMENT_TARGET'] = ios_deployment_target
    end
  end
end
