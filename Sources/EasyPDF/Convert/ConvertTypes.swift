import Foundation
import CoreGraphics
import UniformTypeIdentifiers

/// How a source image is mapped onto a PDF page.
///
/// The default is `fitA4`, and that matters: none of the CoreGraphics/ImageIO paths
/// look at DPI metadata, so "1 pixel = 1 point" turns a 300-dpi A4 scan into a
/// 34 x 49 inch page. Fitting costs nothing — the embedded image stream is
/// byte-identical either way, only the media box and the CTM change.
enum PageSizeMode: String, CaseIterable, Identifiable {
    case fitA4
    case fitLetter
    case dpi
    case pixels

    var id: String { rawValue }
    var title: String { loc("convert.pagesize.\(rawValue)") }

    /// Paper size in points, portrait. Nil for the two original-size modes.
    var paperSize: CGSize? {
        switch self {
        case .fitA4: return CGSize(width: 595.276, height: 841.89)
        case .fitLetter: return CGSize(width: 612, height: 792)
        case .dpi, .pixels: return nil
        }
    }
}

/// Lossless (Flate / JPEG passthrough) versus re-encoded JPEG.
///
/// Counter-intuitively lossless is *smaller* for the material people convert most
/// often — screenshots, scans, line art, palette graphics. It only loses on real
/// photographs, where it can grow to several times the lossy size.
enum ImageQualityMode: String, CaseIterable, Identifiable {
    case lossless
    case smaller

    var id: String { rawValue }
    var title: String { loc("convert.quality.\(rawValue)") }
}

/// Curated on purpose. `CGImageDestinationCopyTypeIdentifiers()` reports 22 types,
/// most of which are meaningless here (astc, dds, ktx2, pvr …). BMP is deliberately
/// absent even though the system writes it: always uncompressed, ~25 MB per page at
/// 300 dpi. WebP is absent because macOS can read it but not write it.
enum RasterFormat: String, CaseIterable, Identifiable {
    case png
    case jpeg
    case tiff
    case heic
    case avif

    var id: String { rawValue }
    var title: String { loc("convert.format.\(rawValue)") }

    var utTypeIdentifier: CFString {
        switch self {
        case .png: return UTType.png.identifier as CFString
        case .jpeg: return UTType.jpeg.identifier as CFString
        case .tiff: return UTType.tiff.identifier as CFString
        case .heic: return "public.heic" as CFString
        // UTType.avif does not exist as a static property in the macOS SDK.
        case .avif: return "public.avif" as CFString
        }
    }

    var fileExtension: String {
        switch self {
        case .png: return "png"
        case .jpeg: return "jpg"
        case .tiff: return "tiff"
        case .heic: return "heic"
        case .avif: return "avif"
        }
    }

    var supportsQuality: Bool {
        self == .jpeg || self == .heic || self == .avif
    }

    /// PNG and TIFF keep an alpha channel; the lossy formats get a white backdrop.
    var supportsTransparency: Bool {
        self == .png || self == .tiff
    }
}

struct ImageToPDFOptions {
    var pageSize: PageSizeMode = .fitA4
    var quality: ImageQualityMode = .lossless
    var jpegQuality: CGFloat = 0.85
    /// Expand multi-page TIFFs and animated GIFs into one page per frame.
    var expandFrames: Bool = true
    var maxFrames: Int = 500
}

struct PDFToImageOptions {
    var format: RasterFormat = .png
    var dpi: Int = 150
    /// Text at 300 dpi already loses umlauts in OCR at q0.8, so stay high by default.
    var quality: CGFloat = 0.9
    /// Nil converts every page.
    var pageIndices: [Int]? = nil
}

/// Non-fatal findings. Showing these is what separates "it ran" from "it can be
/// trusted" — nearly every failure mode in this pipeline otherwise reports success.
enum ConvertWarning: Identifiable, Equatable {
    case truncatedSource(file: String)
    case framesSkipped(file: String, converted: Int, expected: Int)
    case alphaFlattened(file: String)
    case svgFeaturesUnsupported(file: String)
    case pageClamped(file: String)
    case fileSkipped(file: String, reason: String)

    var id: String { message }

    var message: String {
        switch self {
        case .truncatedSource(let file):
            return loc("convert.warn.truncated", file)
        case .framesSkipped(let file, let converted, let expected):
            return loc("convert.warn.frames", file, converted, expected)
        case .alphaFlattened(let file):
            return loc("convert.warn.alpha", file)
        case .svgFeaturesUnsupported(let file):
            return loc("convert.warn.svg", file)
        case .pageClamped(let file):
            return loc("convert.warn.clamped", file)
        case .fileSkipped(let file, let reason):
            return loc("convert.warn.skipped", file, reason)
        }
    }
}

enum ConvertError: LocalizedError, Equatable {
    case noReadableInput
    case decodeFailed(file: String)
    case gifTooLarge(file: String)
    case imageTooLarge(file: String, megapixels: Int)
    case writeFailed
    case noPagesWritten
    case cancelled

    var errorDescription: String? {
        switch self {
        case .noReadableInput: return loc("convert.error.noInput")
        case .decodeFailed(let file): return loc("convert.error.decode", file)
        case .gifTooLarge(let file): return loc("convert.error.gifTooLarge", file)
        case .imageTooLarge(let file, let mp): return loc("convert.error.tooLarge", file, mp)
        case .writeFailed: return loc("error.writeFailed")
        case .noPagesWritten: return loc("convert.error.noPages")
        case .cancelled: return loc("convert.error.cancelled")
        }
    }
}

struct ConvertResult {
    var outputs: [URL] = []
    var pageCount: Int = 0
    var warnings: [ConvertWarning] = []
}

enum ConvertSupport {
    /// Everything ImageIO reads that we are willing to promise, plus SVG.
    /// Deliberately not derived from `CGImageSourceCopyTypeIdentifiers()`: that
    /// list has 62 entries, 24 of them RAW variants nobody tested.
    static let imageExtensions: Set<String> = [
        "jpg", "jpeg", "jpe", "png", "heic", "heif", "avif", "tif", "tiff",
        "gif", "bmp", "webp", "jp2", "jpf", "svg",
    ]

    static func isSVG(_ url: URL) -> Bool {
        url.pathExtension.lowercased() == "svg"
    }

    static func contentType(of url: URL) -> UTType? {
        if let type = try? url.resourceValues(forKeys: [.contentTypeKey]).contentType {
            return type
        }
        return UTType(filenameExtension: url.pathExtension)
    }

    static func isConvertibleImage(_ url: URL) -> Bool {
        imageExtensions.contains(url.pathExtension.lowercased())
    }
}
