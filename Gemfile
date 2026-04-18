source 'https://rubygems.org'

ruby '~> 3.2.4'

gem 'cocoapods', '~> 1.16.2'
gem 'fastlane', '~> 2.232'

# fastlane plugins for ios
ios_plugins_path = File.join(File.dirname(__FILE__), 'fastlane', 'Pluginfile')
eval_gemfile(ios_plugins_path) if File.exist?(ios_plugins_path)
