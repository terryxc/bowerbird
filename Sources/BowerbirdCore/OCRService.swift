import CoreGraphics
import Foundation
import ImageIO
import Vision

public enum OCRService {
    /// Synchronous recognition; the caller is responsible for running it on a background thread.
    ///
    /// Vision picks the language of each line itself, as Maccy and Clipy do. Passing the system's
    /// languages instead made one script win everywhere: on a Chinese-first Mac, email addresses in a
    /// screenshot came out as "panqian.pqcbytedance.com", and putting English first turned the
    /// Chinese into symbols.
    public static func recognizeText(in image: CGImage) throws -> String {
        let request = VNRecognizeTextRequest()
        request.recognitionLevel = .accurate
        request.automaticallyDetectsLanguage = true
        request.usesLanguageCorrection = true
        let handler = VNImageRequestHandler(cgImage: image, options: [:])
        try handler.perform([request])
        let lines = (request.results ?? []).compactMap { $0.topCandidates(1).first?.string }
        return lines.joined(separator: "\n")
    }

    public static func recognizeText(pngData: Data) throws -> String {
        guard let source = CGImageSourceCreateWithData(pngData as CFData, nil),
              let image = CGImageSourceCreateImageAtIndex(source, 0, nil) else { return "" }
        return try recognizeText(in: image)
    }
}
