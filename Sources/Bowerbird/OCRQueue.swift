import Foundation
import BowerbirdCore

/// Runs OCR serially, one image at a time, so a burst of screenshots doesn't saturate the CPU.
@MainActor
final class OCRQueue {
    private let queue = DispatchQueue(label: "app.bowerbird.mac.ocr", qos: .utility)
    private let store: HistoryStore
    /// Once "Recognize text in images" is turned off, new work is ignored
    private let isEnabled: @MainActor () -> Bool
    var onUpdated: (@MainActor (Int64) -> Void)?

    init(store: HistoryStore, isEnabled: @escaping @MainActor () -> Bool = { true }) {
        self.store = store
        self.isEnabled = isEnabled
    }

    func enqueue(_ item: ClipItem) {
        guard isEnabled(), item.kind == .image, item.ocrText == nil, let id = item.id else { return }
        let url = store.imageURL(for: item)
        let notify = onUpdated
        let stillEnabled = isEnabled
        queue.async { [store] in
            // An empty string means "recognized, no text in the image" and must be kept distinct from
            // "this run failed": once an empty string is written it is never retried (pending work is found
            // by ocr_text IS NULL), so a failure to read the image would stick to the item forever. On
            // failure write nothing, and it is queued again on next launch.
            guard let data = try? Data(contentsOf: url),
                  let text = try? OCRService.recognizeText(pngData: data) else { return }
            // Ask again before writing, on the main thread where the switch lives. Recognition
            // takes a second or so; switched off in the meantime, the text used to be written
            // anyway, after the "forget recognised text" pass, and stayed searchable for good.
            Task { @MainActor in
                guard stillEnabled() else { return }
                try? store.setOCRText(id: id, text)
                notify?(id)
            }
        }
    }

    func enqueuePending() {
        guard isEnabled() else { return }
        (try? store.pendingOCR())?.forEach(enqueue)
    }
}
