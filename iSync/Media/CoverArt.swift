import Foundation
import ImageIO
import CoreGraphics
import UniformTypeIdentifiers

/// Extracts embedded pictures and prepares the cover the phone's Music library stores.
enum CoverArt {
    /// Pulls every embedded picture out of `source` byte-for-byte, front cover first.
    static func extract(from source: URL, probe: ProbeResult, tools: FFTools, workDirectory: URL) throws -> [CoverImage] {
        let pictures = probe.orderedPictures
        guard !pictures.isEmpty else { return [] }
        var arguments = ["-v", "error", "-nostdin", "-y", "-i", source.path]
        var outputs = [URL]()
        for (n, picture) in pictures.enumerated() {
            let url = workDirectory.appendingPathComponent("picture-\(n).bin")
            outputs.append(url)
            arguments += ["-map", "0:\(picture.index)", "-c", "copy", "-frames:v", "1", "-update", "1", "-f", "image2", url.path]
        }
        let result = try ProcessRunner.run(tools.ffmpeg, arguments, timeout: 120)
        guard result.status == 0 else {
            logWarning("Could not extract artwork from \(source.lastPathComponent): \(result.stderrString)")
            return []
        }
        var images = [CoverImage]()
        for url in outputs {
            guard let data = try? Data(contentsOf: url), !data.isEmpty else { continue }
            try? FileManager.default.removeItem(at: url)
            if let image = normalisedForMP4(data) {
                images.append(image)
            }
        }
        return images
    }

    /// Classifies picture bytes for an MP4 `covr` atom, converting unsupported formats (GIF, TIFF,
    /// WebP …) to PNG.
    static func normalisedForMP4(_ data: Data) -> CoverImage? {
        if isJPEG(data) { return CoverImage(data: data, kind: .jpeg) }
        if isPNG(data) { return CoverImage(data: data, kind: .png) }
        if data.starts(with: [0x42, 0x4D]) { return CoverImage(data: data, kind: .bmp) }
        guard let png = reencode(data, as: UTType.png, maxEdge: nil) else { return nil }
        return CoverImage(data: png, kind: .png)
    }

    static func isJPEG(_ data: Data) -> Bool { data.starts(with: [0xFF, 0xD8, 0xFF]) }
    static func isPNG(_ data: Data) -> Bool { data.starts(with: [0x89, 0x50, 0x4E, 0x47]) }

    /// The image to register as the track's artwork on the phone. The phone only keeps JPEG originals
    /// (rustunes docs, chapter 06 §14.4) and does not render greyscale ones, so anything else is
    /// re-encoded as an sRGB JPEG with transparency flattened onto white.
    static func phoneJPEG(from cover: CoverImage) -> Data? {
        let maxEdge = 4096
        guard let source = CGImageSourceCreateWithData(cover.data as CFData, nil),
              CGImageSourceGetCount(source) > 0 else { return nil }
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        let colorModel = properties[kCGImagePropertyColorModel] as? String
        let usable = cover.kind == .jpeg
            && width > 0 && height > 0 && max(width, height) <= maxEdge
            && colorModel == (kCGImagePropertyColorModelRGB as String)
            && cover.data.count <= 32 << 20
        if usable { return cover.data }
        return reencode(cover.data, as: UTType.jpeg, maxEdge: maxEdge)
    }

    /// Decodes an image and re-encodes it, flattening transparency onto white.
    static func reencode(_ data: Data, as type: UTType, maxEdge: Int?) -> Data? {
        guard let source = CGImageSourceCreateWithData(data as CFData, nil) else { return nil }
        var options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
        ]
        let properties = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any] ?? [:]
        let width = (properties[kCGImagePropertyPixelWidth] as? NSNumber)?.intValue ?? 0
        let height = (properties[kCGImagePropertyPixelHeight] as? NSNumber)?.intValue ?? 0
        let edge = max(width, height)
        options[kCGImageSourceThumbnailMaxPixelSize] = min(edge > 0 ? edge : 4096, maxEdge ?? Int.max)
        guard let image = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }

        guard let space = CGColorSpace(name: CGColorSpace.sRGB),
              let context = CGContext(data: nil, width: image.width, height: image.height, bitsPerComponent: 8,
                                      bytesPerRow: 0, space: space,
                                      bitmapInfo: type == .jpeg ? CGImageAlphaInfo.noneSkipLast.rawValue
                                                                : CGImageAlphaInfo.premultipliedLast.rawValue) else { return nil }
        let rect = CGRect(x: 0, y: 0, width: image.width, height: image.height)
        if type == .jpeg {
            context.setFillColor(CGColor(red: 1, green: 1, blue: 1, alpha: 1))
            context.fill(rect)
        }
        context.draw(image, in: rect)
        guard let flattened = context.makeImage() else { return nil }

        let output = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(output, type.identifier as CFString, 1, nil) else { return nil }
        let destinationOptions: [CFString: Any] = type == .jpeg ? [kCGImageDestinationLossyCompressionQuality: 0.92] : [:]
        CGImageDestinationAddImage(destination, flattened, destinationOptions as CFDictionary)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return output as Data
    }
}
