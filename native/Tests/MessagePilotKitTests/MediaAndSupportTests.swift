import AVFoundation
import Foundation
import XCTest

@testable import MessagePilotKit

final class MediaTests: XCTestCase {
  var dir: URL!
  override func setUpWithError() throws {
    dir = URL(fileURLWithPath: NSTemporaryDirectory()).appendingPathComponent("media-\(UUID().uuidString)")
    try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
  }
  override func tearDown() { try? FileManager.default.removeItem(at: dir) }

  func testCardRendersAtRequestedSize() throws {
    let url = dir.appendingPathComponent("card.png")
    try MediaFactory.write(
      try MediaFactory.renderCard(.init(title: "Open house Saturday", body: "11–2 · 12 Main St", width: 1200, height: 900)),
      to: url)
    let info = try MediaFactory.imageInfo(url)
    XCTAssertEqual(info["width"] as? Int, 1200)
    XCTAssertEqual(info["height"] as? Int, 900)
    XCTAssertGreaterThan(info["bytes"] as? Int ?? 0, 1000)
  }

  func testStickerImageIsTransparentSquare() throws {
    let url = dir.appendingPathComponent("sticker.png")
    try MediaFactory.write(try MediaFactory.renderSticker(text: "🎉", image: nil, size: 408), to: url)
    let info = try MediaFactory.imageInfo(url)
    XCTAssertEqual(info["width"] as? Int, 408)
    XCTAssertEqual(info["hasAlpha"] as? Bool, true)
    let image = try MediaFactory.loadImage(url)
    // Corner pixel stays transparent: a die-cut sticker, not a filled photo.
    let ctx = CGContext(
      data: nil, width: 1, height: 1, bitsPerComponent: 8, bytesPerRow: 4,
      space: CGColorSpace(name: CGColorSpace.sRGB)!,
      bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)!
    ctx.draw(image, in: CGRect(x: 0, y: 0, width: image.width, height: image.height))
    XCTAssertEqual(ctx.data!.load(fromByteOffset: 3, as: UInt8.self), 0)
  }

  func testConversionAndBadInput() throws {
    let png = dir.appendingPathComponent("a.png")
    try MediaFactory.write(try MediaFactory.renderCard(.init(title: "x", width: 64, height: 64)), to: png)
    let jpg = dir.appendingPathComponent("a.jpg")
    try MediaFactory.write(try MediaFactory.loadImage(png), to: jpg, type: .jpeg)
    XCTAssertEqual(try MediaFactory.imageInfo(jpg)["hasAlpha"] as? Bool, false)
    XCTAssertThrowsError(try MediaFactory.color("red"))
    XCTAssertThrowsError(try MediaFactory.renderCard(.init(title: "x", width: 8, height: 8)))
    XCTAssertThrowsError(try MediaFactory.renderSticker(text: nil, image: nil))
  }

  func testSlideshowVideoHasExpectedDurationAndSize() async throws {
    let frames = try ["One", "Two", "Three"].map {
      try MediaFactory.renderCard(.init(title: $0, width: 640, height: 360))
    }
    let url = dir.appendingPathComponent("show.mp4")
    try await MediaFactory.slideshow(images: frames, secondsPerImage: 1, width: 640, height: 360, to: url)
    let info = try await MediaFactory.videoInfo(url)
    XCTAssertEqual(info["seconds"] as? Double ?? 0, 3, accuracy: 0.1)
    XCTAssertEqual(info["width"] as? Int, 640)
    XCTAssertEqual(info["height"] as? Int, 360)
    do {
      try await MediaFactory.slideshow(images: frames, secondsPerImage: 1, width: 641, height: 360, to: url)
      XCTFail("Odd dimensions must be rejected")
    } catch {}
  }
}

final class SupportTests: XCTestCase {
  func testSendLaterWindow() throws {
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    let ok = try SendLater.parse("2027-01-15T08:15:00Z", now: now)
    XCTAssertEqual(ok.timeIntervalSince1970, 1_800_000_900)
    XCTAssertThrowsError(try SendLater.parse("2027-01-15T07:00:30Z", now: now), "Under a minute ahead")
    XCTAssertThrowsError(try SendLater.parse("2027-02-15T08:00:00Z", now: now), "More than 14 days")
    XCTAssertThrowsError(try SendLater.parse("tomorrow 9am", now: now))
    XCTAssertThrowsError(try SendLater.parse("2027-01-15T08:15:00", now: now), "Needs a time zone")
    let requested = try SendLater.parse("2027-01-15T08:15:42Z", now: now)
    XCTAssertTrue(SendLater.matches(persisted: SendLater.minute(requested), requested: requested))
    XCTAssertFalse(SendLater.matches(persisted: requested.addingTimeInterval(600), requested: requested))
  }

  func testMessageIDsAndDeepLinks() throws {
    XCTAssertEqual(MessageID.guid("ABCD-1234_2"), "ABCD-1234")
    XCTAssertEqual(MessageID.part("ABCD-1234_2"), 2)
    XCTAssertNil(MessageID.part("ABCD-1234"))
    let link = try MessageID.deepLink(guid: "ABCD-1234", overlay: true)
    XCTAssertEqual(link.absoluteString, "imessage:open?message-guid=ABCD-1234&overlay=1")
    XCTAssertThrowsError(try MessageID.deepLink(guid: "x&address=+1555", overlay: false))
  }

  func testWorkspacePathRefusesEscapes() throws {
    let root = NSTemporaryDirectory() + "ws-\(UUID().uuidString)"
    try FileManager.default.createDirectory(atPath: root, withIntermediateDirectories: true)
    defer { try? FileManager.default.removeItem(atPath: root) }
    XCTAssertTrue(try WorkspacePath.resolve("media/a.png", root: root).hasSuffix("/media/a.png"))
    XCTAssertThrowsError(try WorkspacePath.resolve("../etc/passwd", root: root))
    XCTAssertThrowsError(try WorkspacePath.resolve("/etc/passwd", root: root))
    try FileManager.default.createSymbolicLink(atPath: root + "/link", withDestinationPath: "/etc")
    XCTAssertThrowsError(try WorkspacePath.resolve("link/passwd", root: root), "Symlinks are resolved first")
    let fresh = try WorkspacePath.fresh(root, stem: "card/../../x", ext: "png")
    XCTAssertTrue(fresh.contains("/media/card"))
  }
}

final class PluginKitTests: XCTestCase {
  func testParsesMessagesExtensionsRecordedOnMacOS() throws {
    let url = try XCTUnwrap(
      Bundle.module.url(forResource: "pluginkit-message-extensions", withExtension: "txt", subdirectory: "Fixtures"))
    let output = try String(contentsOf: url, encoding: .utf8)
    let extensions = PluginKit.messagesExtensions(output)
    XCTAssertEqual(extensions.count, 10)
    let names = Set(extensions.compactMap { $0["name"] as? String })
    for expected in ["#images", "Image Playground", "Memoji Stickers", "Apple Cash", "Game Center"] {
      XCTAssertTrue(names.contains(expected), expected)
    }
    XCTAssertTrue(extensions.allSatisfy { $0["platform"] as? String == "Mac Catalyst" })
    XCTAssertEqual(extensions.first { $0["name"] as? String == "#images" }?["election"] as? String, "enabled")
  }

  func testHeaderParsing() {
    let records = PluginKit.parse(
      "-    com.example.Line.Stickers(1.2)\n\t     SDK = com.apple.message-payload-provider\n\t    Display Name = Line Stickers\n")
    XCTAssertEqual(records.first?["id"], "com.example.Line.Stickers")
    XCTAssertEqual(records.first?["version"], "1.2")
    XCTAssertEqual(records.first?["election"], "disabled")
    XCTAssertEqual(records.first?["Display Name"], "Line Stickers")
  }
}

final class OperationCatalogTests: XCTestCase {
  func testNamesAreUniqueAndGatedByConfiguration() {
    let names = OperationCatalog.specs.map(\.name)
    XCTAssertEqual(names.count, Set(names).count)
    let locked = OperationCatalog.Flags(
      enableComputer: false, enableEffects: false, enableUI: false, enableFiles: false, hasToolkit: false)
    let caps = Dictionary(
      uniqueKeysWithValues: OperationCatalog.capabilities(locked).map { ($0["operation"] as! String, $0) })
    XCTAssertEqual(caps["messages.send"]?["available"] as? Bool, true)
    XCTAssertEqual(caps["messages.reactions"]?["available"] as? Bool, true)
    XCTAssertEqual(caps["messages.sticker"]?["available"] as? Bool, false)
    XCTAssertEqual(caps["messages.effect"]?["available"] as? Bool, false)
    XCTAssertEqual(caps["files.write"]?["available"] as? Bool, false)
    XCTAssertEqual(caps["messages.sticker"]?["verification"] as? String, "unavailable")
    let lines = OperationCatalog.Flags(
      enableComputer: false, enableEffects: true, enableUI: true, enableFiles: true, hasToolkit: false)
    let open = Dictionary(
      uniqueKeysWithValues: OperationCatalog.capabilities(lines).map { ($0["operation"] as! String, $0) })
    XCTAssertEqual(open["files.write"]?["available"] as? Bool, true, "enableFiles without computer tools")
    XCTAssertEqual(open["computer.exec"]?["available"] as? Bool, false)
    XCTAssertEqual(open["messages.schedule"]?["available"] as? Bool, true)
  }
}
