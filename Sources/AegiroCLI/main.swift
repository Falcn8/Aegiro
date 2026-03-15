
import Foundation
import AegiroCore

enum Exit: Int32 { case ok = 0, usage = 2, fail = 1 }

let AEGIRO_CLI_VERSION = "0.1.0"
#if REAL_CRYPTO
let AEGIRO_CRYPTO_MODE = "REAL_CRYPTO"
#else
let AEGIRO_CRYPTO_MODE = "STUB_CRYPTO"
#endif

struct CLI {
    static func run() throws {
        let args = CommandLine.arguments.dropFirst()
        guard let cmd = args.first else { hint("No command provided.", tip: "Run --help to see available commands.") }
        switch cmd {
        case "--version", "version":
            print("Aegiro CLI v\(AEGIRO_CLI_VERSION) (\(AEGIRO_CRYPTO_MODE))")
            return
        case "--help", "help":
            printUsage(); return
        case "create":
            var path: String?
            var pass: String = ""
            var touch = false
            var it = args.dropFirst().makeIterator()
            while let a = it.next() {
                switch a {
                case "--vault": path = it.next()
                case "--passphrase": pass = it.next() ?? ""
                case "--touchid": touch = true
                default: break
                }
            }
            guard let p = path, !pass.isEmpty else {
                hint("Missing required options for create.", tip: "Use: create --vault <path.agvt> --passphrase \"<pass>\"")
            }
            let v = try AegiroVault.create(at: URL(fileURLWithPath: NSString(string: p).expandingTildeInPath), passphrase: pass, touchID: touch)
            print("Vault created at \(v.url.path)")
        case "import":
            var path: String?
            var files: [String] = []
            var pass: String = ""
            var it = args.dropFirst().makeIterator()
            while let a = it.next() {
                switch a {
                case "--vault": path = it.next()
                case "--passphrase": pass = it.next() ?? ""
                default:
                    files.append(a)
                }
            }
            guard let p = path else {
                hint("Missing --vault for import.", tip: "Use: import --vault <path> <files...")
            }
            guard !files.isEmpty else {
                hint("No files provided to import.", tip: "Use: import --vault <path> <files...")
            }
            guard !pass.isEmpty else {
                hint("Missing --passphrase for import.", tip: "Use: import --vault <path> --passphrase \"<pass>\" <files...>")
            }
            let vpath = NSString(string: p).expandingTildeInPath
            let (imported, _) = try Importer.sidecarImport(vaultURL: URL(fileURLWithPath: vpath), passphrase: pass, files: files.map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath) })
            print("Imported \(imported) file(s) directly into encrypted vault.")
        case "delete":
            var path: String?
            var pass: String = ""
            var logicalPaths: [String] = []
            var it = args.dropFirst().makeIterator()
            while let a = it.next() {
                switch a {
                case "--vault": path = it.next()
                case "--passphrase": pass = it.next() ?? ""
                default:
                    logicalPaths.append(a)
                }
            }
            guard let p = path, !pass.isEmpty else {
                hint("Missing required options for delete.", tip: "Use: delete --vault <path> --passphrase \"<pass>\" <logical-paths...>")
            }
            guard !logicalPaths.isEmpty else {
                hint("No logical paths provided to delete.", tip: "Use: delete --vault <path> --passphrase \"<pass>\" <logical-paths...>")
            }
            let removed = try Editor.deleteEntries(vaultURL: URL(fileURLWithPath: NSString(string: p).expandingTildeInPath),
                                                   passphrase: pass,
                                                   logicalPaths: logicalPaths)
            print("Deleted \(removed) file(s) from vault.")
        case "unlock":
            var path: String?
            var pass: String = ""
            var it = args.dropFirst().makeIterator()
            while let a = it.next() {
                switch a {
                case "--vault": path = it.next()
                case "--passphrase": pass = it.next() ?? ""
                default: break
                }
            }
            guard let p = path, !pass.isEmpty else {
                hint("Missing required options for unlock.", tip: "Use: unlock --vault <path> --passphrase \"<pass>\"")
            }
            let count = try Locker.unlockInfo(vaultURL: URL(fileURLWithPath: NSString(string: p).expandingTildeInPath), passphrase: pass)
            print("Unlocked OK. Index entries: \(count)")
        case "list":
            var path: String?
            var pass: String = ""
            var it = args.dropFirst().makeIterator()
            while let a = it.next() {
                switch a {
                case "--vault": path = it.next()
                case "--passphrase": pass = it.next() ?? ""
                default: break
                }
            }
            guard let p = path, !pass.isEmpty else { hint("Missing required options for list.", tip: "Use: list --vault <path> --passphrase \"<pass>\"") }
            let entries = try Exporter.list(vaultURL: URL(fileURLWithPath: NSString(string: p).expandingTildeInPath), passphrase: pass)
            for e in entries { print("\(e.logicalPath)\t\(e.size) bytes") }
        case "export":
            var path: String?
            var pass: String = ""
            var outDir: String = "."
            var filters: [String] = []
            var it = args.dropFirst().makeIterator()
            while let a = it.next() {
                switch a {
                case "--vault": path = it.next()
                case "--passphrase": pass = it.next() ?? ""
                case "--out": outDir = it.next() ?? "."
                default: filters.append(a)
                }
            }
            guard let p = path, !pass.isEmpty else { hint("Missing required options for export.", tip: "Use: export --vault <path> --passphrase \"<pass>\" [--out <dir>] [filters...]") }
            let results = try Exporter.export(vaultURL: URL(fileURLWithPath: NSString(string: p).expandingTildeInPath), passphrase: pass, filters: filters, outDir: URL(fileURLWithPath: NSString(string: outDir).expandingTildeInPath, isDirectory: true))
            for (logical, out, bytes) in results { print("Exported \(logical) -> \(out.path) (\(bytes) bytes)") }
        case "preview":
            var path: String?
            var pass: String = ""
            var filter: String?
            var it = args.dropFirst().makeIterator()
            while let a = it.next() {
                switch a {
                case "--vault": path = it.next()
                case "--passphrase": pass = it.next() ?? ""
                default: filter = a
                }
            }
            guard let p = path, !pass.isEmpty, let f = filter else { hint("Missing required options for preview.", tip: "Use: preview --vault <path> --passphrase \"<pass>\" <filter>") }
            let entries = try Exporter.list(vaultURL: URL(fileURLWithPath: NSString(string: p).expandingTildeInPath), passphrase: pass)
            guard let match = entries.first(where: { $0.logicalPath.localizedCaseInsensitiveContains(f) }) else { hint("No file matches filter.", tip: f) }
            let tmp = URL(fileURLWithPath: NSTemporaryDirectory(), isDirectory: true).appendingPathComponent((match.logicalPath as NSString).lastPathComponent)
            _ = try Exporter.export(vaultURL: URL(fileURLWithPath: NSString(string: p).expandingTildeInPath), passphrase: pass, filters: [match.logicalPath], outDir: tmp.deletingLastPathComponent())
            print("Preview at: \(tmp.path)")
            let proc = Process()
            proc.executableURL = URL(fileURLWithPath: "/usr/bin/open")
            proc.arguments = [tmp.path]
            try? proc.run()
            proc.waitUntilExit()
        case "doctor":
            var path: String?
            var pass: String?
            var fix = false
            var it = args.dropFirst().makeIterator()
            while let a = it.next() {
                switch a {
                case "--vault": path = it.next()
                case "--passphrase": pass = it.next()
                case "--fix": fix = true
                default: break
                }
            }
            guard let p = path else { hint("Missing --vault for doctor.", tip: "Use: doctor --vault <path> [--passphrase \"<pass>\"] [--fix]") }
            let rep = try Doctor.run(vaultURL: URL(fileURLWithPath: NSString(string: p).expandingTildeInPath), passphrase: pass, fix: fix)
            let _h = rep.headerOK ? "OK" : "BAD"
            let _m = rep.manifestOK ? "OK" : "BAD"
            let _c = rep.chunkAreaOK ? "OK" : "BAD"
            print("Header: \(_h)")
            print("Manifest: \(_m)")
            print("Chunk area: \(_c)")
            if let n = rep.entries { print("Entries: \(n)") }
            if pass == nil || pass?.isEmpty == true {
                print("Note: passphrase not provided; deep chunk authentication and index hash checks were skipped.")
            }
            if !rep.issues.isEmpty {
                print("Issues:")
                for i in rep.issues { print("- \(i)") }
            }
            if rep.fixed { print("Applied fix: re-signed manifest.") }
        case "lock":
            var path: String?
            var pass: String = ""
            var it = args.dropFirst().makeIterator()
            while let a = it.next() {
                switch a {
                case "--vault": path = it.next()
                case "--passphrase": pass = it.next() ?? ""
                default: break
                }
            }
            guard let p = path, !pass.isEmpty else {
                hint("Missing required options for lock.", tip: "Use: lock --vault <path> --passphrase \"<pass>\"")
            }
            let added = try Locker.lockFromSidecar(vaultURL: URL(fileURLWithPath: NSString(string: p).expandingTildeInPath), passphrase: pass)
            if added > 0 {
                print("Lock complete. Imported \(added) legacy staged item(s) from sidecar.")
            } else {
                print("Lock complete. No staged files found; imports are immediate.")
            }
        case "backup":
            var path: String?
            var out: String?
            var pass: String = ""
            var it = args.dropFirst().makeIterator()
            while let a = it.next() {
                switch a {
                case "--vault": path = it.next()
                case "--out": out = it.next()
                case "--passphrase": pass = it.next() ?? ""
                default: break
                }
            }
            guard let p = path, let o = out else {
                hint("Missing required options for backup.", tip: "Use: backup --vault <path> --out <path.aegirobackup> [--passphrase \"<pass>\"]")
            }
            let v = try AegiroVault.open(at: URL(fileURLWithPath: NSString(string: p).expandingTildeInPath))
            try Backup.exportBackup(from: v, to: URL(fileURLWithPath: NSString(string: o).expandingTildeInPath), passphrase: pass)
            print("Backup exported to \(o) (directory created; zip externally).")
        case "scan":
            let paths = Array(args.dropFirst())
            guard !paths.isEmpty else { hint("No paths provided to scan.", tip: "Use: scan <paths...>") }
            let matches = PrivacyMonitor.scan(paths: paths.map { NSString(string: $0).expandingTildeInPath })
            for m in matches {
                print("\(m.path)\t\(m.reason)")
            }
        case "shred":
            let targets = Array(args.dropFirst())
            guard !targets.isEmpty else { hint("No paths provided to shred.", tip: "Use: shred <paths...>") }
            for p in targets {
                try Shredder.shred(path: NSString(string: p).expandingTildeInPath)
                print("Shredded \(p)")
            }
        case "verify":
            var path: String?
            var it = args.dropFirst().makeIterator()
            while let a = it.next() {
                switch a {
                case "--vault": path = it.next()
                default: break
                }
            }
            guard let p = path else { hint("Missing --vault for verify.", tip: "Use: verify --vault <path>") }
            let m = try ManifestIO.load(from: URL(fileURLWithPath: NSString(string: p).expandingTildeInPath))
            #if REAL_CRYPTO
            let sig = Dilithium2()
            #else
            let sig = StubSig()
            #endif
            let ok = ManifestBuilder.verify(m, signer: sig)
            print(ok ? "Manifest signature: OK" : "Manifest signature: INVALID")
        case "status":
            var path: String?
            var pass: String = ""
            var asJSON = false
            var it = args.dropFirst().makeIterator()
            while let a = it.next() {
                switch a {
                case "--vault": path = it.next()
                case "--passphrase": pass = it.next() ?? ""
                case "--json": asJSON = true
                default: break
                }
            }
            guard let p = path else { hint("Missing --vault for status.", tip: "Use: status --vault <path> [--passphrase \"<pass>\"]") }
            let info = try VaultStatus.get(vaultURL: URL(fileURLWithPath: NSString(string: p).expandingTildeInPath), passphrase: pass.isEmpty ? nil : pass)
            if asJSON {
                let enc = JSONEncoder()
                enc.outputFormatting = [.prettyPrinted, .sortedKeys]
                enc.dateEncodingStrategy = .iso8601
                let data = try enc.encode(info)
                print(String(data: data, encoding: .utf8) ?? "{}")
            } else {
                print("Vault Info")
                print("File count: \(info.entries != nil ? String(info.entries!) : "unknown (locked)")")
                print("Vault size: \(formatBytes(info.vaultSizeBytes)) (\(info.vaultSizeBytes) bytes)")
                if let modified = info.vaultLastModified {
                    print("Last edited: \(formatTimestamp(modified))")
                } else {
                    print("Last edited: unknown")
                }
                print("")
                print("Status")
                print("Locked: \(info.locked ? "yes" : "no")")
                print("Sidecar pending: \(info.sidecarPending)")
                print("Manifest: \(info.manifestOK ? "OK" : "INVALID")")
                print("Touch ID: \(info.touchIDEnabled ? "enabled" : "disabled")")
            }
        case "apfs-volume-encrypt":
            var disk: String?
            var pass: String = ""
            var recovery: String?
            var dryRun = false
            var force = false
            var it = args.dropFirst().makeIterator()
            while let a = it.next() {
                switch a {
                case "--disk": disk = it.next()
                case "--passphrase": pass = it.next() ?? ""
                case "--recovery": recovery = it.next()
                case "--dry-run": dryRun = true
                case "--force": force = true
                default: break
                }
            }
            guard let d = disk, !pass.isEmpty else {
                hint("Missing required options for apfs-volume-encrypt.", tip: "Use: apfs-volume-encrypt --disk <diskXsY> --passphrase \"<recovery-pass>\" [--recovery <path.json>] [--dry-run] [--force]")
            }
            let recURL: URL
            if let r = recovery {
                recURL = URL(fileURLWithPath: NSString(string: r).expandingTildeInPath)
            } else {
                recURL = defaultDiskRecoveryURL(diskIdentifier: d)
            }
            let result = try ExternalDiskCrypto.encryptAPFSVolume(diskIdentifier: d,
                                                                  recoveryPassphrase: pass,
                                                                  recoveryURL: recURL,
                                                                  dryRun: dryRun,
                                                                  overwrite: force)
            if result.dryRun {
                print("Dry run: generated PQC recovery bundle without calling diskutil encrypt.")
            } else {
                print("Started APFS encryption for \(d).")
            }
            print("PQC recovery bundle: \(result.recoveryURL.path)")
        case "apfs-volume-decrypt":
            var disk: String?
            var pass: String = ""
            var recovery: String?
            var dryRun = false
            var it = args.dropFirst().makeIterator()
            while let a = it.next() {
                switch a {
                case "--disk": disk = it.next()
                case "--passphrase": pass = it.next() ?? ""
                case "--recovery": recovery = it.next()
                case "--dry-run": dryRun = true
                default: break
                }
            }
            guard let d = disk, !pass.isEmpty, let r = recovery else {
                hint("Missing required options for apfs-volume-decrypt.", tip: "Use: apfs-volume-decrypt --disk <diskXsY> --recovery <path.json> --passphrase \"<recovery-pass>\" [--dry-run]")
            }
            try ExternalDiskCrypto.unlockAPFSVolume(diskIdentifier: d,
                                                    recoveryPassphrase: pass,
                                                    recoveryURL: URL(fileURLWithPath: NSString(string: r).expandingTildeInPath),
                                                    dryRun: dryRun)
            if dryRun {
                print("Dry run: recovery bundle validated and PQC decapsulation succeeded.")
            } else {
                print("Unlock command sent for \(d).")
            }
        case "usb-container-create":
            var image: String?
            var size: String?
            var name = "Aegiro USB"
            var recoveryPass: String = ""
            var recovery: String?
            var containerPass: String?
            var dryRun = false
            var force = false
            var it = args.dropFirst().makeIterator()
            while let a = it.next() {
                switch a {
                case "--image": image = it.next()
                case "--size": size = it.next()
                case "--name": name = it.next() ?? name
                case "--passphrase": recoveryPass = it.next() ?? ""
                case "--recovery": recovery = it.next()
                case "--container-passphrase": containerPass = it.next()
                case "--dry-run": dryRun = true
                case "--force": force = true
                default: break
                }
            }
            guard let i = image, let s = size, !recoveryPass.isEmpty else {
                hint("Missing required options for usb-container-create.", tip: "Use: usb-container-create --image <path.sparsebundle> --size <size> --passphrase \"<recovery-pass>\" [--recovery <path.json>] [--name \"<volume>\"] [--container-passphrase \"<pass>\"] [--dry-run] [--force]")
            }
            let imageURL = URL(fileURLWithPath: NSString(string: i).expandingTildeInPath)
            let recoveryURL: URL
            if let r = recovery {
                recoveryURL = URL(fileURLWithPath: NSString(string: r).expandingTildeInPath)
            } else {
                recoveryURL = defaultUSBContainerRecoveryURL(imageURL: imageURL)
            }
            let result = try USBContainerCrypto.createEncryptedContainer(imageURL: imageURL,
                                                                         size: s,
                                                                         volumeName: name,
                                                                         recoveryPassphrase: recoveryPass,
                                                                         recoveryURL: recoveryURL,
                                                                         overwrite: force,
                                                                         containerPassphrase: containerPass,
                                                                         dryRun: dryRun)
            if result.dryRun {
                print("Dry run: validated encrypted USB container request and PQC recovery bundle creation.")
            } else {
                print("Created encrypted container image: \(result.imageURL.path)")
            }
            print("PQC recovery bundle: \(result.recoveryURL.path)")
        case "usb-container-open":
            var image: String?
            var recoveryPass: String = ""
            var recovery: String?
            var containerPass: String?
            var dryRun = false
            var it = args.dropFirst().makeIterator()
            while let a = it.next() {
                switch a {
                case "--image": image = it.next()
                case "--passphrase": recoveryPass = it.next() ?? ""
                case "--recovery": recovery = it.next()
                case "--container-passphrase": containerPass = it.next()
                case "--dry-run": dryRun = true
                default: break
                }
            }
            guard let i = image else {
                hint("Missing required options for usb-container-open.", tip: "Use: usb-container-open --image <path.sparsebundle> --passphrase \"<recovery-pass>\" [--recovery <path.json>] [--container-passphrase \"<pass>\"] [--dry-run]")
            }
            if (containerPass?.isEmpty ?? true) && recoveryPass.isEmpty {
                hint("Missing passphrase for usb-container-open.", tip: "Use --passphrase for PQC recovery bundle unlock, or --container-passphrase for direct legacy mount.")
            }
            let imageURL = URL(fileURLWithPath: NSString(string: i).expandingTildeInPath)
            let recoveryURL: URL
            if let r = recovery {
                recoveryURL = URL(fileURLWithPath: NSString(string: r).expandingTildeInPath)
            } else {
                recoveryURL = defaultUSBContainerRecoveryURL(imageURL: imageURL)
            }
            let result = try USBContainerCrypto.mountEncryptedContainer(imageURL: imageURL,
                                                                        recoveryPassphrase: recoveryPass,
                                                                        recoveryURL: recoveryURL,
                                                                        containerPassphraseOverride: containerPass,
                                                                        dryRun: dryRun)
            if result.dryRun {
                print("Dry run: validated encrypted USB container mount request.")
            } else {
                if let mountPoint = result.mountPoint {
                    print("Mounted at: \(mountPoint)")
                } else {
                    print("Mounted image (mount point unavailable from hdiutil output).")
                }
                if let device = result.deviceIdentifier {
                    print("Device: \(device)")
                }
            }
        case "usb-container-close":
            var target: String?
            var force = false
            var dryRun = false
            var it = args.dropFirst().makeIterator()
            while let a = it.next() {
                switch a {
                case "--target": target = it.next()
                case "--force": force = true
                case "--dry-run": dryRun = true
                default: break
                }
            }
            guard let t = target else {
                hint("Missing required options for usb-container-close.", tip: "Use: usb-container-close --target <mount-point|diskX> [--force] [--dry-run]")
            }
            try USBContainerCrypto.unmountContainer(target: t, force: force, dryRun: dryRun)
            if dryRun {
                print("Dry run: validated unmount target \(t).")
            } else {
                print("Unmounted \(t).")
            }
        case "usb-vault-pack":
            var source: String?
            var vault: String?
            var passphrase: String = ""
            var dryRun = false
            var deleteOriginals = false
            var it = args.dropFirst().makeIterator()
            while let a = it.next() {
                switch a {
                case "--source": source = it.next()
                case "--vault": vault = it.next()
                case "--passphrase": passphrase = it.next() ?? ""
                case "--dry-run": dryRun = true
                case "--delete-originals": deleteOriginals = true
                default: break
                }
            }
            guard let source, let vault else {
                hint("Missing required options for usb-vault-pack.", tip: "Use: usb-vault-pack --source <folder> --vault <path.agvt> [--passphrase \"<pass>\"] [--dry-run] [--delete-originals]")
            }
            if !dryRun && passphrase.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty {
                hint("Missing passphrase for usb-vault-pack.", tip: "Use --passphrase for encryption mode, or --dry-run for scan-only.")
            }
            if dryRun && deleteOriginals {
                hint("--delete-originals cannot be used with --dry-run.", tip: "Remove --delete-originals or run without --dry-run.")
            }

            let sourceURL = URL(fileURLWithPath: NSString(string: source).expandingTildeInPath, isDirectory: true).standardizedFileURL
            let vaultURL = URL(fileURLWithPath: NSString(string: vault).expandingTildeInPath).standardizedFileURL
            let pass = passphrase.trimmingCharacters(in: .whitespacesAndNewlines)

            let result = try USBUserDataCrypto.encryptUserFiles(sourceRootURL: sourceURL,
                                                                vaultURL: vaultURL,
                                                                passphrase: pass,
                                                                deleteOriginals: deleteOriginals,
                                                                dryRun: dryRun) { progress in
                let stage = progress.stage.rawValue
                print("[\(stage)] \(progress.message)")
            }

            if result.dryRun {
                print("Scan complete: \(result.scannedFileCount) user file(s), \(result.skippedPathCount) skipped system path(s).")
            } else {
                print("Encrypted \(result.encryptedFileCount) user file(s) into \(result.vaultURL.path).")
                if result.createdVault {
                    print("Created vault file: \(result.vaultURL.path)")
                }
                if deleteOriginals {
                    print("Deleted \(result.deletedOriginalCount) original file(s).")
                    if !result.deletionErrors.isEmpty {
                        print("Deletion errors:")
                        for error in result.deletionErrors {
                            print("- \(error)")
                        }
                    }
                }
            }
        default:
            hint("Unknown command: \(cmd)", tip: "Run --help to see available commands.")
        }
    }

    static func printUsage() {
        print("""
Aegiro CLI v\(AEGIRO_CLI_VERSION) (\(AEGIRO_CRYPTO_MODE))
Usage:
  --version | version                      Show CLI version
  --help    | help                         Show this help
  create --vault <path.agvt> --passphrase "<pass>" [--touchid]
  import --vault <path> --passphrase "<pass>" <files...>
  delete --vault <path> --passphrase "<pass>" <logical-paths...>
  lock --vault <path> --passphrase "<pass>"
  unlock --vault <path> --passphrase "<pass>"
  list --vault <path> --passphrase "<pass>"
  export --vault <path> --passphrase "<pass>" [--out <dir>] [filters...]
  preview --vault <path> --passphrase "<pass>" <filter>
  doctor --vault <path> [--passphrase "<pass>"] [--fix]  (deep checks require passphrase)
  backup --vault <path> --out <path.aegirobackup> [--passphrase "<pass>"]
  scan <paths...>
  shred <paths...>
  apfs-volume-encrypt --disk <diskXsY> --passphrase "<recovery-pass>" [--recovery <path.json>] [--dry-run] [--force]
  apfs-volume-decrypt --disk <diskXsY> --recovery <path.json> --passphrase "<recovery-pass>" [--dry-run]
  usb-container-create --image <path.sparsebundle> --size <size> --passphrase "<recovery-pass>" [--recovery <path.json>] [--name "<volume>"] [--container-passphrase "<pass>"] [--dry-run] [--force]
  usb-container-open --image <path.sparsebundle> --passphrase "<recovery-pass>" [--recovery <path.json>] [--container-passphrase "<pass>"] [--dry-run]
  usb-container-close --target <mount-point|diskX> [--force] [--dry-run]
  usb-vault-pack --source <folder> --vault <path.agvt> [--passphrase "<pass>"] [--dry-run] [--delete-originals]
  verify --vault <path>                    Verify manifest signature
  status --vault <path> [--passphrase "<pass>"] [--json]

Limits:
  Max files per vault: \(VaultLimits.defaultMaxFilesPerVault) by default.
  Override: set AEGIRO_MAX_FILES_PER_VAULT=<positive-int>.
""")
    }

    static func hint(_ message: String, tip: String, code: Exit = .usage) -> Never {
        fputs("Error: \(message)\nHint:  \(tip)\n", stderr)
        exit(code.rawValue)
    }

    static func formatBytes(_ bytes: UInt64) -> String {
        let f = ByteCountFormatter()
        f.allowedUnits = [.useBytes, .useKB, .useMB, .useGB, .useTB]
        f.countStyle = .file
        return f.string(fromByteCount: Int64(bytes))
    }

    static func formatTimestamp(_ date: Date) -> String {
        let f = DateFormatter()
        f.dateStyle = .medium
        f.timeStyle = .medium
        return f.string(from: date)
    }

    static func defaultDiskRecoveryURL(diskIdentifier: String) -> URL {
        let safeID = diskIdentifier.replacingOccurrences(of: "/", with: "_")
        return URL(fileURLWithPath: FileManager.default.currentDirectoryPath, isDirectory: true)
            .appendingPathComponent("\(safeID).aegiro-diskkey.json")
    }

    static func defaultUSBContainerRecoveryURL(imageURL: URL) -> URL {
        let base = imageURL.deletingPathExtension().lastPathComponent
        return imageURL
            .deletingLastPathComponent()
            .appendingPathComponent("\(base).aegiro-usbkey.json")
    }
}

do { try CLI.run() } catch {
    fputs("Error: \(error)\n", stderr)
    exit(1)
}
