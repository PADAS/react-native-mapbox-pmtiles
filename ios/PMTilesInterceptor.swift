import Foundation
import MapboxCommon

final class PMTilesInterceptor: HttpServiceInterceptorInterface {
  static let shared = PMTilesInterceptor()
  static let host = "https://pmtiles.local/"

  private let lock = NSLock()
  private var directory: URL?
  private var archives: [String: PMTilesArchive] = [:]

  func install(directory: URL) {
    lock.lock()
    self.directory = directory
    archives.removeAll()
    lock.unlock()
    HttpServiceFactory.setHttpServiceInterceptorForInterceptor(self)
  }

  func onRequest(for request: HttpRequest, continuation: @escaping HttpServiceInterceptorRequestContinuation) {
    guard request.url.hasPrefix(Self.host) else {
      continuation(HttpRequestOrResponse.fromHttpRequest(request))
      return
    }
    continuation(HttpRequestOrResponse.fromHttpResponse(response(for: request)))
  }

  func onResponse(for response: HttpResponse, continuation: @escaping HttpServiceInterceptorResponseContinuation) {
    continuation(response)
  }

  private func response(for request: HttpRequest) -> HttpResponse {
    let path = request.url.dropFirst(Self.host.count).split(separator: "?").first ?? ""
    let parts = path.split(separator: "/").map(String.init)

    guard parts.count == 4,
          let archive = archive(named: parts[0]),
          let z = UInt8(parts[1]),
          let x = UInt32(parts[2]),
          let y = UInt32(parts[3].split(separator: ".").first ?? "") else {
      NSLog("PMTiles not found \(request.url)")
      return makeResponse(request, code: 404, data: Data(), headers: [:])
    }

    guard let tile = archive.tile(z: z, x: x, y: y) else {
      return makeResponse(request, code: 204, data: Data(), headers: [:])
    }

    NSLog("PMTiles served \(request.url) \(tile.count) bytes")
    return makeResponse(request, code: 200, data: tile, headers: [
      "content-type": archive.contentType,
      "cache-control": "no-store",
    ])
  }

  private func archive(named name: String) -> PMTilesArchive? {
    guard !name.isEmpty,
          name.allSatisfy({ $0.isLetter || $0.isNumber || $0 == "-" || $0 == "_" }) else {
      return nil
    }

    lock.lock()
    defer { lock.unlock() }

    if let archive = archives[name] {
      return archive
    }
    guard let directory,
          let archive = PMTilesArchive(path: directory.appendingPathComponent("\(name).pmtiles").path) else {
      return nil
    }
    archives[name] = archive
    return archive
  }

  private func makeResponse(_ request: HttpRequest, code: Int32, data: Data, headers: [String: String]) -> HttpResponse {
    let responseData = HttpResponseData(headers: headers, code: code, data: data)
    return HttpResponse(identifier: 0, request: request, result: .success(responseData))
  }
}
