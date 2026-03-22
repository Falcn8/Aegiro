import Foundation
import AppKit
import AegiroCore

private func formattedDirectoryImportError(_ error: Error) -> String {
    AegiroUserError.messageWithCode(for: error)
}

extension VaultModel {
    func importFiles(destinationDirectoryPath: String) {
        guard let url = vaultURL else { return }
        guard !locked else {
            status = "Unlock to import files"
            return
        }
        let panel = NSOpenPanel()
        panel.allowsMultipleSelection = true
        panel.canChooseFiles = true
        panel.canChooseDirectories = false
        if panel.runModal() == .OK {
            do {
                let (imported, _) = try Importer.sidecarImport(vaultURL: url,
                                                               passphrase: passphrase,
                                                               files: panel.urls,
                                                               destinationDirectoryPath: destinationDirectoryPath)
                status = imported == 0 ? "No files imported" : "Imported \(imported) file(s) into encrypted vault"
                refreshStatus()
            } catch {
                status = "Import failed: \(formattedDirectoryImportError(error))"
            }
        }
    }

    func importFiles(urls: [URL], destinationDirectoryPath: String) {
        guard let vaultURL else { return }
        guard !locked else {
            status = "Unlock to import files"
            return
        }

        let readableFiles = urls.filter { FileManager.default.fileExists(atPath: $0.path) }
        guard !readableFiles.isEmpty else {
            status = "No readable files were dropped"
            return
        }

        do {
            let (imported, _) = try Importer.sidecarImport(vaultURL: vaultURL,
                                                           passphrase: passphrase,
                                                           files: readableFiles,
                                                           destinationDirectoryPath: destinationDirectoryPath)
            status = imported == 0 ? "No files imported" : "Imported \(imported) file(s) into encrypted vault"
            refreshStatus()
        } catch {
            status = "Import failed: \(formattedDirectoryImportError(error))"
        }
    }
}
