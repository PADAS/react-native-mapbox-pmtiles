import Foundation

@objc(RNMapboxPMTiles)
final class RNMapboxPMTiles: NSObject {
  @objc static func requiresMainQueueSetup() -> Bool {
    false
  }

  @objc(install:)
  func install(_ directory: String) {
    PMTilesInterceptor.shared.install(directory: URL(fileURLWithPath: directory))
  }
}
