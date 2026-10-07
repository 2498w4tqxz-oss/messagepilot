import Compression
import Foundation

/// Application-defined limits, not claims about Apple's maximum payload size.
struct PeerStateEnvelope<State: Codable>: Codable {
  var version = 1
  var experienceID: UUID
  var revision: Int
  var parentRevision: Int
  var turnID: UUID
  var state: State
}
enum PeerStateError: Error { case invalid, tooLarge, conflict }
enum PeerStateCodec {
  static let maximumDecodedBytes = 65536
  static let maximumURLBytes = 8192
  static func encode<State>(_ envelope: PeerStateEnvelope<State>) throws -> URL {
    guard envelope.version == 1, envelope.revision >= 0, envelope.parentRevision >= -1,
      envelope.parentRevision < Int.max, envelope.revision == envelope.parentRevision + 1
    else { throw PeerStateError.invalid }
    let raw = try JSONEncoder().encode(envelope)
    guard raw.count <= maximumDecodedBytes else { throw PeerStateError.tooLarge }
    var compressed = [UInt8](repeating: 0, count: maximumDecodedBytes + 1024)
    let size = raw.withUnsafeBytes { source in
      compression_encode_buffer(
        &compressed, compressed.count, source.bindMemory(to: UInt8.self).baseAddress!, raw.count,
        nil, COMPRESSION_ZLIB)
    }
    guard size > 0 else { throw PeerStateError.invalid }
    let encoded = Data(compressed.prefix(size)).base64EncodedString().replacingOccurrences(
      of: "+", with: "-"
    ).replacingOccurrences(of: "/", with: "_").replacingOccurrences(of: "=", with: "")
    var url = URLComponents()
    url.scheme = "messagepilot"
    url.host = "peer"
    url.queryItems = [.init(name: "v", value: "1"), .init(name: "state", value: encoded)]
    guard let result = url.url, result.absoluteString.utf8.count <= maximumURLBytes else {
      throw PeerStateError.tooLarge
    }
    return result
  }
  static func decode<State: Codable>(
    _ url: URL, as: State.Type, experienceID: UUID? = nil, expectedParentRevision: Int? = nil
  ) throws -> PeerStateEnvelope<State> {
    guard url.absoluteString.utf8.count <= maximumURLBytes,
      let parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
      parts.scheme == "messagepilot", parts.host == "peer", parts.user == nil,
      parts.password == nil,
      parts.fragment == nil, parts.queryItems?.count == 2,
      parts.queryItems?.filter({ $0.name == "v" }).first?.value == "1",
      let value = parts.queryItems?.filter({ $0.name == "state" }).first?.value,
      value.range(of: "^[A-Za-z0-9_-]+$", options: .regularExpression) != nil
    else { throw PeerStateError.invalid }
    let padded =
      value.replacingOccurrences(of: "-", with: "+").replacingOccurrences(of: "_", with: "/")
      + String(repeating: "=", count: (4 - value.count % 4) % 4)
    guard let source = Data(base64Encoded: padded), !source.isEmpty else {
      throw PeerStateError.invalid
    }
    var decoded = [UInt8](repeating: 0, count: maximumDecodedBytes + 1)
    let count = source.withUnsafeBytes { input in
      compression_decode_buffer(
        &decoded, decoded.count, input.bindMemory(to: UInt8.self).baseAddress!, source.count, nil,
        COMPRESSION_ZLIB)
    }
    guard count > 0, count <= maximumDecodedBytes else { throw PeerStateError.tooLarge }
    let envelope = try JSONDecoder().decode(
      PeerStateEnvelope<State>.self, from: Data(decoded.prefix(count)))
    guard envelope.version == 1, envelope.revision >= 0, envelope.parentRevision >= -1,
      envelope.parentRevision < Int.max, envelope.revision == envelope.parentRevision + 1
    else { throw PeerStateError.invalid }
    if let experienceID, experienceID != envelope.experienceID { throw PeerStateError.conflict }
    if let expectedParentRevision, expectedParentRevision != envelope.parentRevision {
      throw PeerStateError.conflict
    }
    return envelope
  }
}
