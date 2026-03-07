import Foundation

public struct USBContainerCreateResult {
    public let imageURL: URL
    public let dryRun: Bool

    public init(imageURL: URL, dryRun: Bool) {
        self.imageURL = imageURL
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

public enum USBContainerCrypto {
    public static func createEncryptedContainer(imageURL: URL,
                                                size: String,
                                                volumeName: String,
                                                passphrase: String,
                                                overwrite: Bool = false,
                                                dryRun: Bool = false) throws -> USBContainerCreateResult {
        let normalizedSize = size.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedSize.isEmpty else {
            throw AEGError.io("Missing container size (for example, 8g)")
        }
        let normalizedName = volumeName.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !normalizedName.isEmpty else {
            throw AEGError.io("Missing container volume name")
        }
        guard !passphrase.isEmpty else {
            throw AEGError.io("Missing container passphrase")
        }
        if !overwrite && FileManager.default.fileExists(atPath: imageURL.path) {
            throw AEGError.io("Container image already exists at \(imageURL.path). Use --force to overwrite.")
        }
        let parent = imageURL.deletingLastPathComponent()
        try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)

        if !dryRun {
            if overwrite, FileManager.default.fileExists(atPath: imageURL.path) {
                try FileManager.default.removeItem(at: imageURL)
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
                               stdinLine: passphrase)
        }

        return USBContainerCreateResult(imageURL: imageURL, dryRun: dryRun)
    }

    public static func mountEncryptedContainer(imageURL: URL,
                                               passphrase: String,
                                               dryRun: Bool = false) throws -> USBContainerMountResult {
        guard !passphrase.isEmpty else {
            throw AEGError.io("Missing container passphrase")
        }
        guard FileManager.default.fileExists(atPath: imageURL.path) || dryRun else {
            throw AEGError.io("Container image not found: \(imageURL.path)")
        }

        if dryRun {
            return USBContainerMountResult(imageURL: imageURL, deviceIdentifier: nil, mountPoint: nil, dryRun: true)
        }
        let output = try runHdiutil(arguments: ["attach", imageURL.path, "-stdinpass", "-nobrowse", "-plist"],
                                    stdinLine: passphrase)
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
