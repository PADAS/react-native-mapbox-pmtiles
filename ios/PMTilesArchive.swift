import Foundation

final class PMTilesArchive {
  private struct Entry {
    let tileId: UInt64
    let offset: UInt64
    let length: UInt64
    let runLength: UInt64
  }

  enum TileType: UInt8 {
    case unknown = 0, mvt, png, jpeg, webp, avif
  }

  private static let headerLength = 127
  private static let maxCachedDirectories = 100
  private static let gzip: UInt8 = 2

  let tileType: TileType
  let minZoom: UInt8
  let maxZoom: UInt8
  private let rootOffset: UInt64
  private let rootLength: UInt64
  private let leafOffset: UInt64
  private let dataOffset: UInt64
  private let internalCompression: UInt8
  private let tileCompression: UInt8
  private let handle: FileHandle
  private let lock = NSLock()
  private var directoryCache: [UInt64: [Entry]] = [:]

  init?(path: String) {
    guard let handle = FileHandle(forReadingAtPath: path),
          let header = try? handle.read(upToCount: Self.headerLength),
          header.count == Self.headerLength,
          header.prefix(7) == Data("PMTiles".utf8),
          header[7] == 3 else {
      return nil
    }

    self.handle = handle
    rootOffset = Self.uint64(header, at: 8)
    rootLength = Self.uint64(header, at: 16)
    leafOffset = Self.uint64(header, at: 40)
    dataOffset = Self.uint64(header, at: 56)
    internalCompression = header[97]
    tileCompression = header[98]
    tileType = TileType(rawValue: header[99]) ?? .unknown
    minZoom = header[100]
    maxZoom = header[101]
  }

  deinit {
    try? handle.close()
  }

  var contentType: String {
    switch tileType {
    case .mvt: return "application/x-protobuf"
    case .png: return "image/png"
    case .jpeg: return "image/jpeg"
    case .webp: return "image/webp"
    case .avif: return "image/avif"
    case .unknown: return "application/octet-stream"
    }
  }

  func tile(z: UInt8, x: UInt32, y: UInt32) -> Data? {
    guard z >= minZoom, z <= maxZoom, x < (1 << z), y < (1 << z) else { return nil }

    lock.lock()
    defer { lock.unlock() }

    let tileId = Self.tileId(z: z, x: x, y: y)
    var offset = rootOffset
    var length = rootLength

    for _ in 0..<4 {
      guard let entries = directory(offset: offset, length: length),
            let entry = Self.find(tileId, in: entries) else {
        return nil
      }
      if entry.runLength > 0 {
        guard let data = read(offset: dataOffset + entry.offset, length: entry.length) else { return nil }
        return tileCompression == Self.gzip ? Self.gunzip(data) : data
      }
      offset = leafOffset + entry.offset
      length = entry.length
    }
    return nil
  }

  private func directory(offset: UInt64, length: UInt64) -> [Entry]? {
    if let cached = directoryCache[offset] {
      return cached
    }
    guard let raw = read(offset: offset, length: length),
          let data = internalCompression == Self.gzip ? Self.gunzip(raw) : raw,
          let entries = Self.deserializeDirectory(data) else {
      return nil
    }
    if directoryCache.count >= Self.maxCachedDirectories {
      directoryCache.removeAll()
    }
    directoryCache[offset] = entries
    return entries
  }

  private func read(offset: UInt64, length: UInt64) -> Data? {
    do {
      try handle.seek(toOffset: offset)
      let data = try handle.read(upToCount: Int(length))
      return data?.count == Int(length) ? data : nil
    } catch {
      return nil
    }
  }

  private static func tileId(z: UInt8, x: UInt32, y: UInt32) -> UInt64 {
    let base = ((UInt64(1) << (2 * UInt64(z))) - 1) / 3
    let n = Int64(1) << Int64(z)
    var x = Int64(x)
    var y = Int64(y)
    var d: Int64 = 0
    var s = n >> 1
    while s > 0 {
      let rx: Int64 = (x & s) > 0 ? 1 : 0
      let ry: Int64 = (y & s) > 0 ? 1 : 0
      d += s * s * ((3 * rx) ^ ry)
      if ry == 0 {
        if rx == 1 {
          x = n - 1 - x
          y = n - 1 - y
        }
        swap(&x, &y)
      }
      s >>= 1
    }
    return base + UInt64(d)
  }

  private static func find(_ tileId: UInt64, in entries: [Entry]) -> Entry? {
    var lo = 0
    var hi = entries.count - 1
    while lo <= hi {
      let mid = (lo + hi) / 2
      if tileId > entries[mid].tileId {
        lo = mid + 1
      } else if tileId < entries[mid].tileId {
        hi = mid - 1
      } else {
        return entries[mid]
      }
    }
    if hi >= 0 {
      let entry = entries[hi]
      if entry.runLength == 0 || tileId - entry.tileId < entry.runLength {
        return entry
      }
    }
    return nil
  }

  private static func deserializeDirectory(_ data: Data) -> [Entry]? {
    let bytes = [UInt8](data)
    var position = 0

    func varint() -> UInt64? {
      var result: UInt64 = 0
      var shift: UInt64 = 0
      while position < bytes.count, shift < 64 {
        let byte = bytes[position]
        position += 1
        result |= UInt64(byte & 0x7F) << shift
        if byte < 0x80 {
          return result
        }
        shift += 7
      }
      return nil
    }

    guard let rawCount = varint(), rawCount <= UInt64(bytes.count) else { return nil }
    let count = Int(rawCount)
    var tileIds = [UInt64](repeating: 0, count: count)
    var runLengths = [UInt64](repeating: 0, count: count)
    var lengths = [UInt64](repeating: 0, count: count)
    var offsets = [UInt64](repeating: 0, count: count)

    var lastId: UInt64 = 0
    for i in 0..<count {
      guard let delta = varint() else { return nil }
      lastId += delta
      tileIds[i] = lastId
    }
    for i in 0..<count {
      guard let value = varint() else { return nil }
      runLengths[i] = value
    }
    for i in 0..<count {
      guard let value = varint() else { return nil }
      lengths[i] = value
    }
    for i in 0..<count {
      guard let value = varint(), value > 0 || i > 0 else { return nil }
      offsets[i] = value == 0 ? offsets[i - 1] + lengths[i - 1] : value - 1
    }

    return (0..<count).map {
      Entry(tileId: tileIds[$0], offset: offsets[$0], length: lengths[$0], runLength: runLengths[$0])
    }
  }

  private static func gunzip(_ data: Data) -> Data? {
    let bytes = [UInt8](data)
    guard bytes.count > 18, bytes[0] == 0x1F, bytes[1] == 0x8B, bytes[2] == 8 else { return nil }

    let flags = bytes[3]
    var position = 10
    if flags & 0x04 != 0 {
      position += 2 + Int(bytes[position]) + Int(bytes[position + 1]) << 8
    }
    if flags & 0x08 != 0 {
      while position < bytes.count, bytes[position] != 0 { position += 1 }
      position += 1
    }
    if flags & 0x10 != 0 {
      while position < bytes.count, bytes[position] != 0 { position += 1 }
      position += 1
    }
    if flags & 0x02 != 0 {
      position += 2
    }
    guard position < bytes.count - 8 else { return nil }

    let deflate = Data(bytes[position..<(bytes.count - 8)])
    return try? (deflate as NSData).decompressed(using: .zlib) as Data
  }

  private static func uint64(_ data: Data, at offset: Int) -> UInt64 {
    data.withUnsafeBytes { UInt64(littleEndian: $0.loadUnaligned(fromByteOffset: offset, as: UInt64.self)) }
  }
}
