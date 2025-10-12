import Foundation
import AppKit
import Quartz
import AegiroCore

final class QuickLookCoordinator: NSObject, QLPreviewPanelDataSource, QLPreviewPanelDelegate {
    static let shared = QuickLookCoordinator()
    private override init() {}

    private var items: [NSURL] = []

    func setItems(_ urls: [URL]) {
        self.items = urls.map { $0 as NSURL }
    }

    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        return items.count
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> QLPreviewItem! {
        guard index >= 0 && index < items.count else { return nil }
        return items[index]
    }
}

extension VaultModel {
    func quickLook(logicalPath: String) {
        exportToTempAndPreview(filters: [logicalPath])
    }

    func quickLookSelection(filters: [String]) {
        exportToTempAndPreview(filters: filters)
    }

    private func exportToTempAndPreview(filters: [String]) {
        guard let url = vaultURL else { return }
        let tmpDir = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true)
        do {
            let results = try Exporter.export(vaultURL: url, passphrase: passphrase, filters: filters, outDir: tmpDir)
            let urls = results.map { $0.1 }
            QuickLookCoordinator.shared.setItems(urls)
            if let panel = QLPreviewPanel.shared() {
                panel.dataSource = QuickLookCoordinator.shared
                panel.delegate = QuickLookCoordinator.shared
                panel.makeKeyAndOrderFront(nil)
            }
        } catch {
            self.status = "Quick Look failed: \(error)"
        }
    }
}
