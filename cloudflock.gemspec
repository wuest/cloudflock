$LOAD_PATH.unshift File.expand_path('../lib', __FILE__)
require 'cloudflock/version'

Gem::Specification.new do |s|
  s.name = "cloudflock"
  s.version = CloudFlock::VERSION

  s.description = "CloudFlock is a library and toolchain focused on migration"
  s.summary = "Server migration automation"
  s.authors = ["Chris Wuest"]
  s.email = "chris@chriswuest.com"
  s.homepage = "http://github.com/cwuest/cloudflock"

  s.add_dependency('fog', '>=1.11.1')
  s.add_dependency('multi_json')
  s.add_dependency('expectr')
  s.add_dependency('cpe')

  s.files = `git ls-files lib`.split("\n")
  s.files += `git ls-files bin`.split("\n")
  s.files.reject! { |f| f.include?(".dev") }

  s.executables = ['cloudflock', 'cloudflock-profile', 'cloudflock-servers']

  s.license = 'Apache 2.0'
end
