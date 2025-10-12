
import Foundation
import AegiroCore

enum Exit: Int32 { case ok = 0, usage = 2, fail = 1 }

let AEGIRO_CLI_VERSION = "0.1.0"

struct CLI {
    static func run() throws {
        let args = CommandLine.arguments.dropFirst()
        guard let cmd = args.first else { hint("No command provided.", tip: "Run --help to see available commands.") }
        switch cmd {
        case "--version", "version":
            print("Aegiro CLI v\(AEGIRO_CLI_VERSION)")
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
                hint("Missing required options for create.", tip: "Use: create --vault <path.aegirovault> --passphrase \"<pass>\"")
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
            let (imported, sidecar) = try Importer.sidecarImport(vaultURL: URL(fileURLWithPath: vpath), passphrase: pass, files: files.map { URL(fileURLWithPath: NSString(string: $0).expandingTildeInPath) })
            print("Imported \(imported) file(s) into sidecar: \(sidecar.path)")
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
            print("Locked. Added \(added) item(s) from sidecar into encrypted index. Manifest re-sign pending.")
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
            var it = args.dropFirst().makeIterator()
            while let a = it.next() {
                switch a {
                case "--vault": path = it.next()
                case "--passphrase": pass = it.next() ?? ""
                default: break
                }
            }
            guard let p = path else { hint("Missing --vault for status.", tip: "Use: status --vault <path> [--passphrase \"<pass>\"]") }
            let info = try VaultStatus.get(vaultURL: URL(fileURLWithPath: NSString(string: p).expandingTildeInPath), passphrase: pass.isEmpty ? nil : pass)
            print("Locked: \(info.locked ? "yes" : "no")")
            print("Entries: \(info.entries != nil ? String(info.entries!) : "unknown (locked)")")
            print("Sidecar pending: \(info.sidecarPending)")
            print("Manifest: \(info.manifestOK ? "OK" : "INVALID")")
        default:
            hint("Unknown command: \(cmd)", tip: "Run --help to see available commands.")
        }
    }

    static func printUsage() {
        print("""
Aegiro CLI v\(AEGIRO_CLI_VERSION)
Usage:
  --version | version                      Show CLI version
  --help    | help                         Show this help
  create --vault <path.aegirovault> --passphrase "<pass>" [--touchid]
  import --vault <path> --passphrase "<pass>" <files...>
  lock --vault <path> --passphrase "<pass>"
  unlock --vault <path> --passphrase "<pass>"
  list --vault <path> --passphrase "<pass>"
  export --vault <path> --passphrase "<pass>" [--out <dir>] [filters...]
  preview --vault <path> --passphrase "<pass>" <filter>
  doctor --vault <path> [--passphrase "<pass>"] [--fix]
  backup --vault <path> --out <path.aegirobackup> [--passphrase "<pass>"]
  scan <paths...>
  shred <paths...>
  verify --vault <path>                    Verify manifest signature
  status --vault <path> [--passphrase "<pass>"] [--json]
""")
    }

    static func hint(_ message: String, tip: String, code: Exit = .usage) -> Never {
        fputs("Error: \(message)\nHint:  \(tip)\n", stderr)
        exit(code.rawValue)
    }
}

do { try CLI.run() } catch {
    fputs("Error: \(error)\n", stderr)
    exit(1)
}
