import AVFoundation
import AppKit
import CoreGraphics
import Foundation
import ImageIO
import UniformTypeIdentifiers

/// Creates images, stickers and videos inside the worker workspace so an agent can send media it
/// made itself without shell access. Output is validated after writing.
public enum MediaFactory {
  public struct Card {
    public var title: String
    public var body: String
    public var width: Int
    public var height: Int
    public var background: String
    public var foreground: String
    public init(
      title: String, body: String = "", width: Int = 1200, height: Int = 900,
      background: String = "#1F2937", foreground: String = "#FFFFFF"
    ) {
      self.title = title
      self.body = body
      self.width = width
      self.height = height
      self.background = background
      self.foreground = foreground
    }
  }

  public static func color(_ hex: String) throws -> NSColor {
    var s = hex.trimmingCharacters(in: .whitespaces)
    if s.hasPrefix("#") { s.removeFirst() }
    guard [6, 8].contains(s.count), let v = UInt64(s, radix: 16) else {
      throw KitError("Colors must be #RRGGBB or #RRGGBBAA")
    }
    let rgba = s.count == 6 ? (v << 8) | 0xFF : v
    return NSColor(
      srgbRed: CGFloat((rgba >> 24) & 0xFF) / 255, green: CGFloat((rgba >> 16) & 0xFF) / 255,
      blue: CGFloat((rgba >> 8) & 0xFF) / 255, alpha: CGFloat(rgba & 0xFF) / 255)
  }

  static func context(width: Int, height: Int) throws -> CGContext {
    guard (16...4096).contains(width), (16...4096).contains(height),
      let ctx = CGContext(
        data: nil, width: width, height: height, bitsPerComponent: 8, bytesPerRow: 0,
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue)
    else { throw KitError("Image size must be 16–4096 px per side") }
    return ctx
  }

  static func drawText(
    _ text: String, in rect: CGRect, size: CGFloat, weight: NSFont.Weight, color: NSColor,
    ctx: CGContext, align: NSTextAlignment = .left
  ) {
    let paragraph = NSMutableParagraphStyle()
    paragraph.alignment = align
    paragraph.lineBreakMode = .byWordWrapping
    let attributed = NSAttributedString(
      string: text,
      attributes: [
        .font: NSFont.systemFont(ofSize: size, weight: weight), .foregroundColor: color,
        .paragraphStyle: paragraph,
      ])
    NSGraphicsContext.saveGraphicsState()
    NSGraphicsContext.current = NSGraphicsContext(cgContext: ctx, flipped: false)
    attributed.draw(with: rect, options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine])
    NSGraphicsContext.restoreGraphicsState()
  }

  public static func renderCard(_ card: Card) throws -> CGImage {
    let ctx = try context(width: card.width, height: card.height)
    ctx.setFillColor(try color(card.background).cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: card.width, height: card.height))
    let fg = try color(card.foreground)
    let margin = CGFloat(card.width) * 0.07
    let w = CGFloat(card.width) - margin * 2
    let titleSize = max(18, CGFloat(card.width) / 16)
    drawText(
      card.title,
      in: CGRect(x: margin, y: CGFloat(card.height) * 0.45, width: w, height: CGFloat(card.height) * 0.45),
      size: titleSize, weight: .bold, color: fg, ctx: ctx)
    if !card.body.isEmpty {
      drawText(
        card.body, in: CGRect(x: margin, y: margin, width: w, height: CGFloat(card.height) * 0.4),
        size: titleSize * 0.5, weight: .regular, color: fg.withAlphaComponent(0.85), ctx: ctx)
    }
    guard let image = ctx.makeImage() else { throw KitError("Rendering failed") }
    return image
  }

  /// A transparent square sticker image: an emoji or short text with a white outline, or an
  /// existing image fitted into the square. Messages treats it as a sticker only when inserted
  /// through a sticker surface (picker or Messages extension); as a file it sends as a photo.
  public static func renderSticker(text: String?, image: CGImage?, size: Int = 408) throws
    -> CGImage
  {
    let ctx = try context(width: size, height: size)
    ctx.clear(CGRect(x: 0, y: 0, width: size, height: size))
    if let image {
      let scale = min(CGFloat(size) / CGFloat(image.width), CGFloat(size) / CGFloat(image.height))
      let w = CGFloat(image.width) * scale
      let h = CGFloat(image.height) * scale
      ctx.draw(image, in: CGRect(x: (CGFloat(size) - w) / 2, y: (CGFloat(size) - h) / 2, width: w, height: h))
    } else if let text, !text.isEmpty {
      let fontSize = text.count <= 2 ? CGFloat(size) * 0.7 : CGFloat(size) / CGFloat(max(4, text.count)) * 1.6
      let rect = CGRect(x: 0, y: CGFloat(size) * 0.12, width: CGFloat(size), height: CGFloat(size) * 0.8)
      // Outline pass then fill pass gives the familiar die-cut sticker edge.
      ctx.setShadow(offset: .zero, blur: CGFloat(size) / 40, color: NSColor.white.cgColor)
      for _ in 0..<3 {
        drawText(text, in: rect, size: fontSize, weight: .heavy, color: .white, ctx: ctx, align: .center)
      }
      ctx.setShadow(offset: .zero, blur: 0, color: nil)
      drawText(text, in: rect, size: fontSize, weight: .heavy, color: .black, ctx: ctx, align: .center)
    } else {
      throw KitError("Sticker needs text or an image")
    }
    guard let out = ctx.makeImage() else { throw KitError("Rendering failed") }
    return out
  }

  public static func loadImage(_ url: URL) throws -> CGImage {
    guard let source = CGImageSourceCreateWithURL(url as CFURL, nil),
      let image = CGImageSourceCreateImageAtIndex(source, 0, nil)
    else {
      // SVG and PDF go through AppKit, which rasterizes vector formats.
      guard let ns = NSImage(contentsOf: url),
        let cg = ns.cgImage(forProposedRect: nil, context: nil, hints: nil)
      else { throw KitError("Unreadable image: \(url.lastPathComponent)") }
      return cg
    }
    return image
  }

  public static func write(_ image: CGImage, to url: URL, type: UTType = .png) throws {
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    guard let dest = CGImageDestinationCreateWithURL(url as CFURL, type.identifier as CFString, 1, nil)
    else { throw KitError("Cannot write \(type.preferredFilenameExtension ?? "image")") }
    CGImageDestinationAddImage(dest, image, nil)
    guard CGImageDestinationFinalize(dest) else { throw KitError("Image encoding failed") }
  }

  public static func imageInfo(_ url: URL) throws -> [String: Any] {
    let image = try loadImage(url)
    let alpha = image.alphaInfo
    return [
      "path": url.path, "width": image.width, "height": image.height,
      "hasAlpha": ![.none, .noneSkipFirst, .noneSkipLast].contains(alpha),
      "bytes": (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0,
    ]
  }

  /// Builds an H.264 MP4 slideshow: each image is shown for `secondsPerImage`.
  public static func slideshow(
    images: [CGImage], secondsPerImage: Double, width: Int, height: Int, to url: URL
  ) async throws {
    guard !images.isEmpty, images.count <= 120, (0.1...30).contains(secondsPerImage),
      width % 2 == 0, height % 2 == 0, (64...3840).contains(width), (64...3840).contains(height)
    else { throw KitError("1–120 images, 0.1–30 s each, even dimensions 64–3840") }
    try? FileManager.default.removeItem(at: url)
    try FileManager.default.createDirectory(
      at: url.deletingLastPathComponent(), withIntermediateDirectories: true)
    let writer = try AVAssetWriter(outputURL: url, fileType: url.pathExtension.lowercased() == "mov" ? .mov : .mp4)
    let input = AVAssetWriterInput(
      mediaType: .video,
      outputSettings: [
        AVVideoCodecKey: AVVideoCodecType.h264, AVVideoWidthKey: width, AVVideoHeightKey: height,
      ])
    input.expectsMediaDataInRealTime = false
    let adaptor = AVAssetWriterInputPixelBufferAdaptor(
      assetWriterInput: input,
      sourcePixelBufferAttributes: [
        kCVPixelBufferPixelFormatTypeKey as String: kCVPixelFormatType_32ARGB,
        kCVPixelBufferWidthKey as String: width, kCVPixelBufferHeightKey as String: height,
      ])
    guard writer.canAdd(input) else { throw KitError("Video writer rejected input") }
    writer.add(input)
    guard writer.startWriting() else {
      throw KitError("Video writer failed: \(writer.error?.localizedDescription ?? "unknown")")
    }
    writer.startSession(atSourceTime: .zero)
    let fps: Int32 = 30
    let framesPerImage = max(1, Int(secondsPerImage * Double(fps)))
    var frame: Int64 = 0
    for image in images {
      let buffer = try pixelBuffer(image, width: width, height: height)
      for _ in 0..<framesPerImage {
        while !input.isReadyForMoreMediaData { try await Task.sleep(nanoseconds: 2_000_000) }
        guard adaptor.append(buffer, withPresentationTime: CMTime(value: frame, timescale: fps))
        else { throw KitError("Video frame append failed: \(writer.error?.localizedDescription ?? "")") }
        frame += 1
      }
    }
    input.markAsFinished()
    await writer.finishWriting()
    guard writer.status == .completed else {
      throw KitError("Video encoding failed: \(writer.error?.localizedDescription ?? "unknown")")
    }
  }

  static func pixelBuffer(_ image: CGImage, width: Int, height: Int) throws -> CVPixelBuffer {
    var buffer: CVPixelBuffer?
    CVPixelBufferCreate(
      kCFAllocatorDefault, width, height, kCVPixelFormatType_32ARGB,
      [kCVPixelBufferCGImageCompatibilityKey: true, kCVPixelBufferCGBitmapContextCompatibilityKey: true]
        as CFDictionary, &buffer)
    guard let buffer else { throw KitError("Pixel buffer allocation failed") }
    CVPixelBufferLockBaseAddress(buffer, [])
    defer { CVPixelBufferUnlockBaseAddress(buffer, []) }
    guard
      let ctx = CGContext(
        data: CVPixelBufferGetBaseAddress(buffer), width: width, height: height,
        bitsPerComponent: 8, bytesPerRow: CVPixelBufferGetBytesPerRow(buffer),
        space: CGColorSpace(name: CGColorSpace.sRGB)!,
        bitmapInfo: CGImageAlphaInfo.noneSkipFirst.rawValue)
    else { throw KitError("Pixel buffer context failed") }
    ctx.setFillColor(NSColor.black.cgColor)
    ctx.fill(CGRect(x: 0, y: 0, width: width, height: height))
    let scale = min(CGFloat(width) / CGFloat(image.width), CGFloat(height) / CGFloat(image.height))
    let w = CGFloat(image.width) * scale
    let h = CGFloat(image.height) * scale
    ctx.draw(image, in: CGRect(x: (CGFloat(width) - w) / 2, y: (CGFloat(height) - h) / 2, width: w, height: h))
    return buffer
  }

  public static func videoInfo(_ url: URL) async throws -> [String: Any] {
    let asset = AVURLAsset(url: url)
    let duration = try await asset.load(.duration)
    let tracks = try await asset.loadTracks(withMediaType: .video)
    guard let track = tracks.first else { throw KitError("No video track") }
    let size = try await track.load(.naturalSize)
    return [
      "path": url.path, "seconds": duration.seconds, "width": Int(size.width),
      "height": Int(size.height),
      "bytes": (try? FileManager.default.attributesOfItem(atPath: url.path)[.size] as? Int) ?? 0,
    ]
  }
}
