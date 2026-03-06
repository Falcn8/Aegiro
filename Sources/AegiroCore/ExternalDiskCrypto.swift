import Foundation
import CryptoKit

public struct ExternalDiskEncryptResult {
    public let diskIdentifier: String
    public let recoveryURL: URL
    public let dryRun: Bool

    public init(diskIdentifier: String, recoveryURL: URL, dryRun: Bool) {
        self.diskIdentifier = diskIdentifier
        self.recoveryURL = recoveryURL
        self.dryRun = dryRun
    }
}

private struct DiskRecoveryBundle: Codable {
    let version: UInt16
    let created_unix: UInt64
    let disk_identifier: String
    let kdf_salt: Data
    let argon2: Argon2Params
    let kem_ciphertext: Data
    let kem_secret_wrap: Data
    let disk_passphrase_wrap: Data
}

public enum ExternalDiskCrypto {
    private static let bundleVersion: UInt16 = 1
    private static let bundleAADPrefix = "AEGIRO-DISK-V1"

    public static func encryptAPFSVolume(diskIdentifier: String,
                                         recoveryPassphrase: String,
                                         recoveryURL: URL,
                                         dryRun: Bool,
                                         overwrite: Bool = false) throws -> ExternalDiskEncryptResult {
        guard !diskIdentifier.isEmpty else {
            throw AEGError.io("Missing APFS disk identifier")
        }
        guard !recoveryPassphrase.isEmpty else {
            throw AEGError.io("Missing recovery passphrase")
        }

        if !overwrite && FileManager.default.fileExists(atPath: recoveryURL.path) {
            throw AEGError.io("Recovery bundle already exists at \(recoveryURL.path). Use --force to overwrite.")
        }

        let aad = bundleAAD(for: diskIdentifier)
        let kdfSalt = randomBytes(32)
        let argon = Argon2Params(mMiB: 256, t: 3, p: 1)
        let recoveryKey = try deriveRecoveryKey(passphrase: recoveryPassphrase, salt: kdfSalt, argon: argon)

        #if REAL_CRYPTO
        let kem = Kyber512()
        #else
        let kem = StubKEM()
        #endif
        let (kemPk, kemSk) = try kem.keypair()
        let (sharedSecret, kemCiphertext) = try kem.encap(kemPk)
        let sharedKey = SymmetricKey(data: sharedSecret)

        let diskPassphrase = randomDiskPassphrase()
        let wrappedDiskPassphrase = try AEAD.encrypt(key: sharedKey,
                                                     nonce: randomNonce(),
                                                     plaintext: Data(diskPassphrase.utf8),
                                                     aad: aad)
        let wrappedKEMSecret = try AEAD.encrypt(key: recoveryKey,
                                                nonce: randomNonce(),
                                                plaintext: kemSk,
                                                aad: aad)

        let bundle = DiskRecoveryBundle(version: bundleVersion,
                                        created_unix: UInt64(Date().timeIntervalSince1970),
                                        disk_identifier: diskIdentifier,
                                        kdf_salt: kdfSalt,
                                        argon2: argon,
                                        kem_ciphertext: kemCiphertext,
                                        kem_secret_wrap: wrappedKEMSecret,
                                        disk_passphrase_wrap: wrappedDiskPassphrase)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let bundleData = try encoder.encode(bundle)
        try bundleData.write(to: recoveryURL, options: .atomic)

        if !dryRun {
            _ = try runDiskutil(arguments: ["apfs", "encryptVolume", diskIdentifier, "-user", "disk", "-stdinpassphrase"],
                                stdinLine: diskPassphrase)
        }

        return ExternalDiskEncryptResult(diskIdentifier: diskIdentifier, recoveryURL: recoveryURL, dryRun: dryRun)
    }

    public static func unlockAPFSVolume(diskIdentifier: String,
                                        recoveryPassphrase: String,
                                        recoveryURL: URL,
                                        dryRun: Bool) throws {
        let diskPassphrase = try recoverDiskPassphrase(diskIdentifier: diskIdentifier,
                                                       recoveryPassphrase: recoveryPassphrase,
                                                       recoveryURL: recoveryURL)
        if !dryRun {
            _ = try runDiskutil(arguments: ["apfs", "unlockVolume", diskIdentifier, "-user", "disk", "-stdinpassphrase"],
                                stdinLine: diskPassphrase)
        }
    }

    static func recoverDiskPassphrase(diskIdentifier: String,
                                      recoveryPassphrase: String,
                                      recoveryURL: URL) throws -> String {
        guard !diskIdentifier.isEmpty else {
            throw AEGError.io("Missing APFS disk identifier")
        }
        guard !recoveryPassphrase.isEmpty else {
            throw AEGError.io("Missing recovery passphrase")
        }

        let bundleData = try Data(contentsOf: recoveryURL)
        let bundle = try JSONDecoder().decode(DiskRecoveryBundle.self, from: bundleData)
        guard bundle.version == bundleVersion else {
            throw AEGError.unsupported("Unsupported disk recovery bundle version: \(bundle.version)")
        }
        guard bundle.disk_identifier == diskIdentifier else {
            throw AEGError.integrity("Recovery bundle targets \(bundle.disk_identifier), not \(diskIdentifier)")
        }

        let aad = bundleAAD(for: bundle.disk_identifier)
        let recoveryKey = try deriveRecoveryKey(passphrase: recoveryPassphrase, salt: bundle.kdf_salt, argon: bundle.argon2)
        let kemSecret = try AEAD.decrypt(key: recoveryKey,
                                         nonce: try AES.GCM.Nonce(data: bundle.kem_secret_wrap.prefix(12)),
                                         combined: bundle.kem_secret_wrap,
                                         aad: aad)
        #if REAL_CRYPTO
        let kem = Kyber512()
        #else
        let kem = StubKEM()
        #endif
        let sharedSecret = try kem.decap(bundle.kem_ciphertext, sk: kemSecret)
        let sharedKey = SymmetricKey(data: sharedSecret)
        let diskPassphraseData = try AEAD.decrypt(key: sharedKey,
                                                  nonce: try AES.GCM.Nonce(data: bundle.disk_passphrase_wrap.prefix(12)),
                                                  combined: bundle.disk_passphrase_wrap,
                                                  aad: aad)
        guard let diskPassphrase = String(data: diskPassphraseData, encoding: .utf8), !diskPassphrase.isEmpty else {
            throw AEGError.integrity("Recovered disk passphrase is invalid UTF-8")
        }
        return diskPassphrase
    }

    private static func deriveRecoveryKey(passphrase: String, salt: Data, argon: Argon2Params) throws -> SymmetricKey {
        // Current KDF implementations use fixed defaults; argon metadata is persisted for forward compatibility.
        _ = argon
        #if REAL_CRYPTO
        let kdf = Argon2idKDF()
        #else
        let kdf = StubKDF()
        #endif
        let raw = try kdf.deriveKey(passphrase: passphrase, salt: salt, outLen: 32)
        return SymmetricKey(data: raw)
    }

    private static func runDiskutil(arguments: [String], stdinLine: String?) throws -> (stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/sbin/diskutil")
        process.arguments = arguments

        let stdoutPipe = Pipe()
        let stderrPipe = Pipe()
        process.standardOutput = stdoutPipe
        process.standardError = stderrPipe

        let stdinPipe = Pipe()
        if stdinLine != nil {
            process.standardInput = stdinPipe
        }

        try process.run()
        if let line = stdinLine {
            let d = Data((line + "\n").utf8)
            stdinPipe.fileHandleForWriting.write(d)
            try? stdinPipe.fileHandleForWriting.close()
        }
        process.waitUntilExit()

        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if process.terminationStatus != 0 {
            let details = stderr.isEmpty ? stdout : stderr
            throw AEGError.io("diskutil \(arguments.joined(separator: " ")) failed (\(process.terminationStatus)): \(details)")
        }
        return (stdout, stderr)
    }

    private static func randomDiskPassphrase() -> String {
        randomBytes(32).map { String(format: "%02x", $0) }.joined()
    }

    private static func randomBytes(_ count: Int) -> Data {
        Data((0..<count).map { _ in UInt8.random(in: 0...255) })
    }

    private static func randomNonce() -> AES.GCM.Nonce {
        AES.GCM.Nonce()
    }

    private static func bundleAAD(for diskIdentifier: String) -> Data {
        Data("\(bundleAADPrefix):\(diskIdentifier)".utf8)
    }
}
