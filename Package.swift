// swift-tools-version:5.9
// Builds the PMTiles reader on its own so it can be unit tested with `swift test`.
// The app consumes the library through CocoaPods (react-native-mapbox-pmtiles.podspec), not this package.
import PackageDescription

let package = Package(
  name: "PMTilesReader",
  platforms: [.macOS(.v13)],
  targets: [
    .target(
      name: "PMTilesReader",
      path: "ios",
      exclude: ["PMTilesInterceptor.swift", "RNMapboxPMTiles.swift", "RNMapboxPMTiles.m"],
      sources: ["PMTilesArchive.swift"]
    ),
    .testTarget(
      name: "PMTilesReaderTests",
      dependencies: ["PMTilesReader"],
      path: "test/ios"
    ),
  ]
)
