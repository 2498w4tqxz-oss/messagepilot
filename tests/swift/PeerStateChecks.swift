import Foundation

@main struct PeerStateChecks {
  static func main() throws {
    let id = UUID()
    let turn = UUID()
    let original = PeerStateEnvelope(
      experienceID: id, revision: 1, parentRevision: 0, turnID: turn,
      state: ["task": "Review mockup", "status": "done"])
    let url = try PeerStateCodec.encode(original)
    let result = try PeerStateCodec.decode(
      url, as: [String: String].self, experienceID: id, expectedParentRevision: 0)
    precondition(result.state == original.state && result.turnID == turn)
    do {
      _ = try PeerStateCodec.decode(url, as: [String: String].self, experienceID: UUID())
      fatalError("Cross experience accepted")
    } catch PeerStateError.conflict {}
    do {
      _ = try PeerStateCodec.decode(url, as: [String: String].self, expectedParentRevision: 1)
      fatalError("Stale revision accepted")
    } catch PeerStateError.conflict {}
    do {
      _ = try PeerStateCodec.encode(
        PeerStateEnvelope(
          experienceID: id, revision: 0, parentRevision: -1, turnID: turn,
          state: String(repeating: "x", count: 70000)))
      fatalError("Oversize accepted")
    } catch PeerStateError.tooLarge {}
    do {
      _ = try PeerStateCodec.decode(
        URL(string: "messagepilot://peer?v=1&state=malformed")!, as: [String: String].self)
      fatalError("Invalid stream accepted")
    } catch {}
    print("Peer state roundtrip, scope, revision, size and malformed input checks passed")
  }
}
