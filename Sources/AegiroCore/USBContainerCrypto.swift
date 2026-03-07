import Foundation
import CryptoKit

public struct USBContainerCreateResult {
    public let imageURL: URL
    public let recoveryURL: URL
    public let dryRun: Bool

    public init(imageURL: URL, recoveryURL: URL, dryRun: Bool) {
        self.imageURL = imageURL
        self.recoveryURL = recoveryURL
        self.dryRun = dryRun
    }
}

public struct USBContainerMountResult {
    public let imageURL: URL
    public let deviceIdentifier: String?
    public let mountPoint: String?
    public let dryRun: Bool

    public init(imageURL: URL, deviceIdentifier: String?, mountPoint: String?, dryRun: Bool) {
        self.imageURL = imageURL
        self.deviceIdentifier = deviceIdentifier
        self.mountPoint = mountPoint
        self.dryRun = dryRun
    }
}

private struct USBContainerRecoveryBundle: Codable {
    let version: UInt16
    let created_unix: UInt64
    let image_path: String
    let kdf_salt: Data
    let argon2: Argon2Params
    let kem_ciphertext: Data
    let kem_secret_wrap: Data
    let container_passphrase_wrap: Data
}

public enum USBContainerCrypto {
    private static let bundleVersion: UInt16 = 1
    private static let bundleAADPrefix = "AEGIRO-USB-CONTAINER-V1"

    public static func createEncryptedContainer(imageURL: URL,
                                                size: String,
                                                volumeName: String,
                                                recoveryPassphrase: String,
                                                recoveryURL: URL,
                                                overwrite: Bool = false,
                                                containerPassphrase: String? = nil,
                                                dryRun: Bool = false) throws -> USBContainerCreateResult {
        let normalizedSize = size.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSize.isEmpty else {
            throw AEGError.io("Missing container size (for example, 8g)")
        }
        let normalizedName = volumeName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else {
            throw AEGError.io("Missing container volume name")
        }
        guard !recoveryPassphrase.isEmpty else {
            throw AEGError.io("Missing recovery passphrase")
        }
        if !overwrite && FileManager.default.fileExists(atPath: imageURL.path) {
            throw AEGError.io("Container image already exists at \(imageURL.path). Use --force to overwrite.")
        }
        if !overwrite && FileManager.default.fileExists(atPath: recoveryURL.path) {
            throw AEGError.io("Recovery bundle already exists at \(recoveryURL.path). Use --force to overwrite.")
        }
        let parent = imageURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
        let recoveryParent = recoveryURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: recoveryParent, withIntermediateDirectories: true)

        let identifier = normalizedImageIdentifier(imageURL)
        let aad = bundleAAD(for: identifier)
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

        let effectiveContainerPassphrase = {
            let trimmed = containerPassphrase?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
            return trimmed.isEmpty ? randomContainerPassphrase() : trimmed
        }()
        let wrappedContainerPassphrase = try AEAD.encrypt(key: sharedKey,
                                                          nonce: randomNonce(),
                                                          plaintext: Data(effectiveContainerPassphrase.utf8),
                                                          aad: aad)
        let wrappedKEMSecret = try AEAD.encrypt(key: recoveryKey,
                                                nonce: randomNonce(),
                                                plaintext: kemSk,
                                                aad: aad)
        let bundle = USBContainerRecoveryBundle(version: bundleVersion,
                                                created_unix: UInt64(Date().timeIntervalSince1970),
                                                image_path: identifier,
                                                kdf_salt: kdfSalt,
                                                argon2: argon,
                                                kem_ciphertext: kemCiphertext,
                                                kem_secret_wrap: wrappedKEMSecret,
                                                container_passphrase_wrap: wrappedContainerPassphrase)
        let encoder = JSONEncoder()
        encoder.outputFormatting = [.prettyPrinted, .sortedKeys]
        let bundleData = try encoder.encode(bundle)

        if !dryRun {
            if overwrite, FileManager.default.fileExists(atPath: imageURL.path) {
                try FileManager.default.removeItem(at: imageURL)
            }
            if overwrite, FileManager.default.fileExists(atPath: recoveryURL.path) {
                try FileManager.default.removeItem(at: recoveryURL)
            }
            _ = try runHdiutil(arguments: ["create",
                                           imageURL.path,
                                           "-size",
                                           normalizedSize,
                                           "-type",
                                           "SPARSEBUNDLE",
                                           "-fs",
                                           "APFS",
                                           "-volname",
                                           normalizedName,
                                           "-encryption",
                                           "AES-256",
                                           "-stdinpass"],
                               stdinLine: effectiveContainerPassphrase)
            try bundleData.write(to: recoveryURL, options: .atomic)
        }

        return USBContainerCreateResult(imageURL: imageURL, recoveryURL: recoveryURL, dryRun: dryRun)
    }

    public static func mountEncryptedContainer(imageURL: URL,
                                               recoveryPassphrase: String,
                                               recoveryURL: URL,
                                               containerPassphraseOverride: String? = nil,
                                               dryRun: Bool = false) throws -> USBContainerMountResult {
        guard !recoveryPassphrase.isEmpty || !(containerPassphraseOverride?.isEmpty ?? true) else {
            throw AEGError.io("Missing recovery passphrase")
        }
        guard FileManager.default.fileExists(atPath: imageURL.path) || dryRun else {
            throw AEGError.io("Container image not found: \(imageURL.path)")
        }
        if !dryRun && (containerPassphraseOverride?.isEmpty ?? true) && !FileManager.default.fileExists(atPath: recoveryURL.path) {
            throw AEGError.io("Recovery bundle not found: \(recoveryURL.path)")
        }

        if dryRun {
            return USBContainerMountResult(imageURL: imageURL, deviceIdentifier: nil, mountPoint: nil, dryRun: true)
        }

        let passphraseToUse: String
        if let override = containerPassphraseOverride?.trimmingCharacters(in: .whitespacesAndNewlines), !override.isEmpty {
            passphraseToUse = override
        } else {
            passphraseToUse = try recoverContainerPassphrase(imageURL: imageURL,
                                                             recoveryPassphrase: recoveryPassphrase,
                                                             recoveryURL: recoveryURL)
        }

        let output = try runHdiutil(arguments: ["attach", imageURL.path, "-stdinpass", "-nobrowse", "-plist"],
                                    stdinLine: passphraseToUse)
        guard let plistData = output.stdout.data(using: .utf8) else {
            throw AEGError.io("Unable to decode hdiutil attach output")
        }
        return try parseAttachResult(plistData: plistData, imageURL: imageURL)
    }

    public static func unmountContainer(target: String,
                                        force: Bool = false,
                                        dryRun: Bool = false) throws {
        let trimmed = target.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !trimmed.isEmpty else {
            throw AEGError.io("Missing unmount target (disk identifier or mount point)")
        }
        guard !dryRun else { return }

        var args = ["detach", trimmed]
        if force {
            args.append("-force")
        }
        _ = try runHdiutil(arguments: args, stdinLine: nil)
    }

    static func parseAttachResult(plistData: Data,
                                  imageURL: URL) throws -> USBContainerMountResult {
        let decoder = PropertyListDecoder()
        let response = try decoder.decode(HDIAttachPlist.self, from: plistData)
        let entities = response.systemEntities ?? []

        let mountedEntity = entities.first { entity in
            if let mountPoint = entity.mountPoint {
                return !mountPoint.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            }
            return false
        }
        let device = mountedEntity?.devEntry ?? entities.first?.devEntry
        return USBContainerMountResult(imageURL: imageURL,
                                       deviceIdentifier: sanitizeDeviceIdentifier(device),
                                       mountPoint: mountedEntity?.mountPoint,
                                       dryRun: false)
    }

    static func recoverContainerPassphrase(imageURL: URL,
                                           recoveryPassphrase: String,
                                           recoveryURL: URL) throws -> String {
        guard !recoveryPassphrase.isEmpty else {
            throw AEGError.io("Missing recovery passphrase")
        }

        let bundleData = try Data(contentsOf: recoveryURL)
        let bundle = try JSONDecoder().decode(USBContainerRecoveryBundle.self, from: bundleData)
        guard bundle.version == bundleVersion else {
            throw AEGError.unsupported("Unsupported USB container recovery bundle version: \(bundle.version)")
        }

        let identifier = normalizedImageIdentifier(imageURL)
        guard bundle.image_path == identifier else {
            throw AEGError.integrity("Recovery bundle targets \(bundle.image_path), not \(identifier)")
        }

        let aad = bundleAAD(for: bundle.image_path)
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
        let passphraseData = try AEAD.decrypt(key: sharedKey,
                                              nonce: try AES.GCM.Nonce(data: bundle.container_passphrase_wrap.prefix(12)),
                                              combined: bundle.container_passphrase_wrap,
                                              aad: aad)
        guard let passphrase = String(data: passphraseData, encoding: .utf8), !passphrase.isEmpty else {
            throw AEGError.integrity("Recovered container passphrase is invalid UTF-8")
        }
        return passphrase
    }

    private static func deriveRecoveryKey(passphrase: String, salt: Data, argon: Argon2Params) throws -> SymmetricKey {
        _ = argon
        #if REAL_CRYPTO
        let kdf = Argon2idKDF()
        #else
        let kdf = StubKDF()
        #endif
        let raw = try kdf.deriveKey(passphrase: passphrase, salt: salt, outLen: 32)
        return SymmetricKey(data: raw)
    }

    private static func sanitizeDeviceIdentifier(_ devEntry: String?) -> String? {
        guard let devEntry else { return nil }
        if devEntry.hasPrefix("/dev/") {
            return String(devEntry.dropFirst("/dev/".count))
        }
        return devEntry
    }

    private static func runHdiutil(arguments: [String], stdinLine: String?) throws -> (stdout: String, stderr: String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
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
            let data = Data((line + "\n").utf8)
            stdinPipe.fileHandleForWriting.write(data)
            try? stdinPipe.fileHandleForWriting.close()
        }
        process.waitUntilExit()

        let stdout = String(data: stdoutPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        let stderr = String(data: stderrPipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
        if process.terminationStatus != 0 {
            let details = stderr.isEmpty ? stdout : stderr
            throw AEGError.io("hdiutil \(arguments.joined(separator: " ")) failed (\(process.terminationStatus)): \(details)")
        }
        return (stdout, stderr)
    }

    private static func randomContainerPassphrase() -> String {
        randomBytes(32).map { String(format: "%02x", $0) }.joined()
    }

    private static func randomBytes(_ count: Int) -> Data {
        Data((0..<count).map { _ in UInt8.random(in: 0...255) })
    }

    private static func randomNonce() -> AES.GCM.Nonce {
        AES.GCM.Nonce()
    }

    private static func normalizedImageIdentifier(_ imageURL: URL) -> String {
        imageURL.standardizedFileURL.path
    }

    private static func bundleAAD(for imageIdentifier: String) -> Data {
        Data("\(bundleAADPrefix):\(imageIdentifier)".utf8)
    }
}

private struct HDIAttachPlist: Decodable {
    let systemEntities: [HDISystemEntityPlist]?

    private enum CodingKeys: String, CodingKey {
        case systemEntities = "system-entities"
    }
}

private struct HDISystemEntityPlist: Decodable {
    let devEntry: String?
    let mountPoint: String?

    private enum CodingKeys: String, CodingKey {
        case devEntry = "dev-entry"
        case mountPoint = "mount-point"
    }
}
