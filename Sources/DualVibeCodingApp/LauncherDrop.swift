import Foundation
import UniformTypeIdentifiers

@MainActor
enum LauncherDrop {
    /// Starts receiving each promised file URL before returning from SwiftUI's drop callback.
    static func accept(_ providers: [NSItemProvider], into launcher: ApplicationLaunchStore,
                       onComplete: @escaping @MainActor (LauncherImportResult) -> Void) -> Bool {
        let fileType = UTType.fileURL.identifier
        let files = providers.filter { $0.hasItemConformingToTypeIdentifier(fileType) }
        guard !files.isEmpty else { return false }
        let providerCount = providers.count
        let batch = PendingFileDrop(count: files.count)
        for (index, provider) in files.enumerated() {
            provider.loadItem(forTypeIdentifier: fileType, options: nil) { item, error in
                let url = error == nil ? LauncherDrop.fileURL(from: item) : nil
                DispatchQueue.main.async {
                    guard let urls = batch.receive(url, at: index) else { return }
                    var result = launcher.importApplications(at: urls)
                    result.invalidCount += providerCount - urls.count
                    onComplete(result)
                }
            }
        }
        return true
    }

    nonisolated private static func fileURL(from item: NSSecureCoding?) -> URL? {
        let candidate: URL?
        switch item {
        case let url as URL:
            candidate = url
        case let data as Data:
            candidate = URL(dataRepresentation: data, relativeTo: nil)
        case let string as String:
            candidate = string.hasPrefix("/") ? URL(fileURLWithPath: string) : URL(string: string)
        default:
            candidate = nil
        }
        guard let candidate, candidate.isFileURL else { return nil }
        return candidate
    }
}

@MainActor
private final class PendingFileDrop {
    private var urls: [URL?]
    private var pending: Int

    init(count: Int) {
        urls = [URL?](repeating: nil, count: count)
        pending = count
    }

    func receive(_ url: URL?, at index: Int) -> [URL]? {
        urls[index] = url
        pending -= 1
        return pending == 0 ? urls.compactMap { $0 } : nil
    }
}
