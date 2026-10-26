import XCTest

final class VaultLinkTests: XCTestCase {
  let allowed: Set<String> = ["vault.example.com", "localhost"]
  let token = String(repeating: "A", count: 43)

  func testPendingLinkRoundTrips() throws {
    let url = URL(string: "https://vault.example.com/v1/vault/r/abcdEFGH1234_-xy?label=Lofty%20API%20key&state=pending#t=\(token)")!
    let link = try XCTUnwrap(VaultLink.parse(url, allowedHosts: allowed))
    XCTAssertEqual(link.label, "Lofty API key")
    XCTAssertEqual(link.token, token)
    XCTAssertEqual(link.submitURL.absoluteString, "https://vault.example.com/v1/vault/submit")
    XCTAssertEqual(VaultLink.parse(link.bubbleURL, allowedHosts: allowed), link)
  }

  func testConnectedBubbleDropsTheToken() throws {
    let url = URL(string: "https://vault.example.com/v1/vault/r/abcdEFGH1234_-xy?label=Key&state=pending#t=\(token)")!
    let done = try XCTUnwrap(VaultLink.parse(url, allowedHosts: allowed)).connected()
    XCTAssertNil(done.token)
    XCTAssertFalse(done.bubbleURL.absoluteString.contains(token))
    XCTAssertThrowsError(try done.submission(value: "x", device: "d"))
  }

  func testRejectsForeignHostsCleartextAndMissingTokens() {
    let bad = [
      "https://evil.example.net/v1/vault/r/abcdEFGH1234_-xy?label=Key&state=pending#t=\(token)",
      "http://vault.example.com/v1/vault/r/abcdEFGH1234_-xy?label=Key&state=pending#t=\(token)",
      "https://vault.example.com/v1/vault/r/abcdEFGH1234_-xy?label=Key&state=pending",
      "https://vault.example.com/v1/vault/r/short?label=Key&state=pending#t=\(token)",
      "https://vault.example.com/v1/vault/r/abcdEFGH1234_-xy?state=pending#t=\(token)",
    ]
    for raw in bad { XCTAssertNil(VaultLink.parse(URL(string: raw)!, allowedHosts: allowed), raw) }
    XCTAssertNotNil(
      VaultLink.parse(
        URL(string: "http://localhost:4390/v1/vault/r/abcdEFGH1234_-xy?label=Key&state=pending#t=\(token)")!,
        allowedHosts: allowed), "Loopback http is allowed for local testing")
  }

  func testSubmissionCarriesTokenNotInURL() throws {
    let url = URL(string: "https://vault.example.com/v1/vault/r/abcdEFGH1234_-xy?label=Key&state=pending#t=\(token)")!
    let link = try XCTUnwrap(VaultLink.parse(url, allowedHosts: allowed))
    let body = try JSONSerialization.jsonObject(with: link.submission(value: "sk_123", device: "UUID")) as! [String: String]
    XCTAssertEqual(body, ["id": "abcdEFGH1234_-xy", "token": token, "value": "sk_123", "device": "UUID"])
  }
}
