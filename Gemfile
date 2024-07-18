source 'https://rubygems.org'

ruby ">= 2.6.10"

gem 'cocoapods', '~> 1.13'
gem 'fastlane', '2.221.1'

# fastlane plugins for ios
ios_plugins_path = File.join(File.dirname(__FILE__), 'fastlane', 'Pluginfile')
eval_gemfile(ios_plugins_path) if File.exist?(ios_plugins_path)
