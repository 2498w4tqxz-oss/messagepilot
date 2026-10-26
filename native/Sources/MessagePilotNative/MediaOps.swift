import Foundation
import MessagePilotKit
import UniformTypeIdentifiers

/// `media.create`: images, sticker images, conversions and video made inside the workspace.
enum MediaOps {
  static func create(_ p: [String: Any], workspace: String) async throws -> [String: Any] {
    let kind = try required(p, "kind")
    func output(_ ext: String) throws -> URL {
      if let path = p["path"] as? String {
        let resolved = try WorkspacePath.resolve(path, root: workspace)
        guard URL(fileURLWithPath: resolved).pathExtension.lowercased() == ext else {
          throw BridgeFailure("path must end in .\(ext)")
        }
        return URL(fileURLWithPath: resolved)
      }
      return URL(fileURLWithPath: try WorkspacePath.fresh(workspace, stem: kind, ext: ext))
    }
    func source(_ path: String) throws -> URL {
      URL(fileURLWithPath: try WorkspacePath.resolve(path, root: workspace))
    }
    let format = (p["format"] as? String ?? "png").lowercased()
    let type: UTType
    switch format {
    case "png": type = .png
    case "jpeg", "jpg": type = .jpeg
    case "heic": type = .heic
    default: throw BridgeFailure("format must be png, jpeg or heic")
    }
    let ext = format == "jpeg" ? "jpg" : format
    switch kind {
    case "card":
      var card = MediaFactory.Card(title: try required(p, "title"))
      card.body = p["body"] as? String ?? ""
      card.width = p["width"] as? Int ?? card.width
      card.height = p["height"] as? Int ?? card.height
      card.background = p["background"] as? String ?? card.background
      card.foreground = p["foreground"] as? String ?? card.foreground
      let url = try output(ext)
      try MediaFactory.write(try MediaFactory.renderCard(card), to: url, type: type)
      return try MediaFactory.imageInfo(url)
    case "sticker":
      guard type != .jpeg else { throw BridgeFailure("Stickers need transparency: use png or heic") }
      let image = try (p["source"] as? String).map { try MediaFactory.loadImage(try source($0)) }
      let url = try output(ext)
      try MediaFactory.write(
        try MediaFactory.renderSticker(
          text: p["text"] as? String, image: image, size: min(max(p["size"] as? Int ?? 408, 100), 1024)),
        to: url, type: type)
      return try MediaFactory.imageInfo(url)
    case "convert":
      let input = try MediaFactory.loadImage(try source(try required(p, "source")))
      let url = try output(ext)
      try MediaFactory.write(input, to: url, type: type)
      return try MediaFactory.imageInfo(url)
    case "slideshow":
      guard let sources = p["sources"] as? [String], !sources.isEmpty else {
        throw BridgeFailure("sources required")
      }
      let images = try sources.map { try MediaFactory.loadImage(try source($0)) }
      let url = try output("mp4")
      try await MediaFactory.slideshow(
        images: images, secondsPerImage: p["secondsPerImage"] as? Double ?? 2,
        width: p["width"] as? Int ?? 1280, height: p["height"] as? Int ?? 720, to: url)
      return try await MediaFactory.videoInfo(url)
    default:
      throw BridgeFailure("kind must be card, sticker, convert or slideshow")
    }
  }
}
