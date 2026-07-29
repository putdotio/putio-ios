source 'https://rubygems.org'

# Read from mise.toml so the toolchain has one pin. Bundler still refuses a
# mismatched Ruby, it just no longer carries its own copy of the version.
ruby file: 'mise.toml'

gem 'cocoapods', '~> 1.17.0'
gem 'fastlane', '~> 2.237'

# fastlane plugins for ios
eval_gemfile 'fastlane/Pluginfile' if File.exist?(File.join(__dir__, 'fastlane', 'Pluginfile'))
