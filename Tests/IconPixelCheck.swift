import CoreGraphics
import Foundation
import ImageIO

// Decodes every representation directly from an .icns (or PNG) and verifies it
// has at least one nontransparent pixel. This is a pixel-data check, not a
// screenshot: it only reads the asset file supplied on the command line.

@main
struct IconPixelCheck {
    static func main() {
        let paths = Array(CommandLine.arguments.dropFirst())
        guard !paths.isEmpty else {
            FileHandle.standardError.write(Data("usage: icon-pixel-check <icns-or-png> [...]\n".utf8))
            exit(2)
        }

        var failures = 0
        for path in paths {
            failures += check(path: path)
        }

        if failures > 0 {
            FileHandle.standardError.write(Data("\(failures) icon assertion(s) failed\n".utf8))
            exit(1)
        }
        print("Icon pixel tests passed")
    }

    private static func check(path: String) -> Int {
        let url = URL(fileURLWithPath: path)
        guard let source = CGImageSourceCreateWithURL(url as CFURL, nil) else {
            return fail("could not open \(path)")
        }

        let count = CGImageSourceGetCount(source)
        guard count > 0 else {
            return fail("\(path) contains no images")
        }

        var failures = 0
        var representations = 0
        var smallestPixels = Int.max
        var totalOpaquePixels = 0
        for index in 0..<count {
            guard let image = CGImageSourceCreateImageAtIndex(source, index, nil) else {
                failures += fail("\(path) image \(index) could not be decoded")
                continue
            }

            let width = image.width
            let height = image.height
            guard width > 0, height > 0 else {
                failures += fail("\(path) image \(index) has empty dimensions")
                continue
            }

            guard let context = CGContext(
                data: nil,
                width: width,
                height: height,
                bitsPerComponent: 8,
                bytesPerRow: 0,
                space: CGColorSpaceCreateDeviceRGB(),
                bitmapInfo: CGImageAlphaInfo.premultipliedLast.rawValue
            ) else {
                failures += fail("\(path) image \(index) could not create a raster context")
                continue
            }

            context.clear(CGRect(x: 0, y: 0, width: width, height: height))
            context.draw(image, in: CGRect(x: 0, y: 0, width: width, height: height))

            guard let data = context.data else {
                failures += fail("\(path) image \(index) has no raster data")
                continue
            }

            let rowBytes = context.bytesPerRow
            var opaquePixels = 0
            for y in 0..<height {
                let row = data.advanced(by: y * rowBytes).assumingMemoryBound(to: UInt8.self)
                for x in 0..<width where row[x * 4 + 3] > 0 {
                    opaquePixels += 1
                }
            }

            guard opaquePixels > 0 else {
                failures += fail("\(path) image \(index) is fully transparent (\(width)x\(height))")
                continue
            }

            representations += 1
            smallestPixels = min(smallestPixels, width * height)
            totalOpaquePixels += opaquePixels
        }

        if failures == 0 {
            print(
                "\(path): \(representations) representation(s), smallest \(smallestPixels) pixels, "
                    + "\(totalOpaquePixels) nontransparent pixels total"
            )
        }
        return failures
    }

    private static func fail(_ message: String) -> Int {
        FileHandle.standardError.write(Data("FAIL: \(message)\n".utf8))
        return 1
    }
}
