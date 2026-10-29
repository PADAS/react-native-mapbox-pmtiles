require "json"

package = JSON.parse(File.read(File.join(__dir__, "package.json")))

Pod::Spec.new do |s|
  s.name         = "react-native-mapbox-pmtiles"
  s.version      = package["version"]
  s.summary      = package["description"]
  s.homepage     = package["homepage"]
  s.license      = package["license"]
  s.authors      = package["author"]
  s.platforms    = { :ios => "15.1" }
  s.source       = { :git => package["repository"]["url"], :tag => "v#{s.version}" }
  s.source_files = "ios/**/*.{h,m,swift}"
  s.swift_version = "5.0"

  s.dependency "React-Core"
  s.dependency "MapboxCommon"
end
