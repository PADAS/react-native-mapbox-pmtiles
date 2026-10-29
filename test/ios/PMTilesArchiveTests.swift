import CryptoKit
import Foundation
import XCTest
@testable import PMTilesReader

final class PMTilesArchiveTests: XCTestCase {
  private struct Expected: Decodable {
    let fixtures: [Fixture]
  }

  private struct Fixture: Decodable {
    let file: String
    let valid: Bool
    let header: Header?
    let addressedTiles: Int?
    let tiles: [Tile]?
  }

  private struct Header: Decodable {
    let tileType: String
    let contentType: String
    let minZoom: UInt8
    let maxZoom: UInt8
  }

  private struct Tile: Decodable {
    let z: Int
    let x: Int
    let y: Int
    let missing: Bool?
    let size: Int?
    let sha256: String?
  }

  private static let fixtures = URL(fileURLWithPath: #filePath)
    .deletingLastPathComponent()
    .deletingLastPathComponent()
    .appendingPathComponent("fixtures")

  private static let tileTypes: [String: PMTilesArchive.TileType] = [
    "mvt": .mvt, "png": .png, "jpeg": .jpeg, "webp": .webp, "avif": .avif,
  ]

  private func loadExpected() throws -> [Fixture] {
    let data = try Data(contentsOf: Self.fixtures.appendingPathComponent("expected.json"))
    return try JSONDecoder().decode(Expected.self, from: data).fixtures
  }

  private func path(_ file: String) -> String {
    Self.fixtures.appendingPathComponent(file).path
  }

  func testInvalidFilesDoNotOpen() throws {
    for fixture in try loadExpected() where !fixture.valid {
      XCTAssertNil(PMTilesArchive(path: path(fixture.file)), fixture.file)
    }
  }

  func testMissingFileDoesNotOpen() {
    XCTAssertNil(PMTilesArchive(path: path("does-not-exist.pmtiles")))
  }

  func testHeaders() throws {
    for fixture in try loadExpected() where fixture.valid {
      let archive = try XCTUnwrap(PMTilesArchive(path: path(fixture.file)), fixture.file)
      let header = try XCTUnwrap(fixture.header)
      XCTAssertEqual(archive.tileType, Self.tileTypes[header.tileType], fixture.file)
      XCTAssertEqual(archive.contentType, header.contentType, fixture.file)
      XCTAssertEqual(archive.minZoom, header.minZoom, fixture.file)
      XCTAssertEqual(archive.maxZoom, header.maxZoom, fixture.file)
    }
  }

  func testTiles() throws {
    for fixture in try loadExpected() where fixture.valid {
      let archive = try XCTUnwrap(PMTilesArchive(path: path(fixture.file)), fixture.file)
      for tile in fixture.tiles ?? [] {
        let label = "\(fixture.file) \(tile.z)/\(tile.x)/\(tile.y)"
        let data = archive.tile(z: UInt8(tile.z), x: UInt32(tile.x), y: UInt32(tile.y))
        if tile.missing == true {
          XCTAssertNil(data, label)
        } else {
          let data = try XCTUnwrap(data, label)
          XCTAssertEqual(data.count, tile.size, label)
          XCTAssertEqual(Self.sha256(data), tile.sha256, label)
        }
      }
    }
  }

  func testEveryAddressedTileIsReachable() throws {
    for fixture in try loadExpected() where fixture.valid {
      let archive = try XCTUnwrap(PMTilesArchive(path: path(fixture.file)), fixture.file)
      var count = 0
      for z in archive.minZoom...archive.maxZoom {
        for x in 0..<(UInt32(1) << z) {
          for y in 0..<(UInt32(1) << z) where archive.tile(z: z, x: x, y: y) != nil {
            count += 1
          }
        }
      }
      XCTAssertEqual(count, fixture.addressedTiles, fixture.file)
    }
  }

  private static func sha256(_ data: Data) -> String {
    SHA256.hash(data: data).map { String(format: "%02x", $0) }.joined()
  }
}
