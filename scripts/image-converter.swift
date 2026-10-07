import Foundation
import ImageIO
import UniformTypeIdentifiers

// Dedicated CLI: thumbnails only, no original metadata copied to derivatives.
guard CommandLine.arguments.count == 3 else { exit(2) }
let input = URL(fileURLWithPath: CommandLine.arguments[1])
let output = URL(fileURLWithPath: CommandLine.arguments[2])
guard let source = CGImageSourceCreateWithURL(input as CFURL, nil),
  let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
  let width = properties[kCGImagePropertyPixelWidth] as? Int,
  let height = properties[kCGImagePropertyPixelHeight] as? Int,
  width > 0, height > 0, width <= 40_000_000 / height,
  let image = CGImageSourceCreateThumbnailAtIndex(
    source, 0,
    [
      kCGImageSourceCreateThumbnailFromImageAlways: true, kCGImageSourceThumbnailMaxPixelSize: 2000,
      kCGImageSourceCreateThumbnailWithTransform: true,
    ] as CFDictionary),
  let target = CGImageDestinationCreateWithURL(
    output as CFURL, UTType.png.identifier as CFString, 1, nil)
else { exit(3) }
CGImageDestinationAddImage(target, image, nil)
guard CGImageDestinationFinalize(target) else { exit(4) }
print("{\"width\":\(width),\"height\":\(height),\"frames\":\(CGImageSourceGetCount(source))}")
