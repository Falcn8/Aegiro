
import Foundation
import CryptoKit
import Security

public struct VaultOpenContext {
    public var pdkKey: SymmetricKey?
    public var sdkKey: SymmetricKey?
    public var pqSk: Data?
    public var sigPk: Data?
    public var fileNonceSeed: SymmetricKey
}

private let vaultFlagTouchID: UInt32 = 1 << 0
private let vaultFlagPQCUnlockV1: UInt32 = 1 << 1
private let vaultAAD = Data("AEGIRO-V1".utf8)
private let vaultChunkAADPrefixV1 = Data("AEGIRO-CHUNK-V1".utf8)
private let vaultFileKeyInfoPrefixV1 = Data("AEGIRO-FILE-KEY-V1".utf8)
private let vaultChunkFormatV1: UInt8 = 1
private let vaultChunkAlgAESGCM: UInt8 = 1
private let vaultChunkAlgChaChaPoly1305: UInt8 = 2
private let vaultChunkKeySaltLength = 16
private let vaultChunkNoncePrefixLength = 4
private let vaultChunkTagLength = 16
private let vaultChunkAEADIDV1: UInt16 = 1

private struct PQAccessBundleV1: Codable {
    let version: UInt8
    let kemCiphertext: Data
    let kemSecretWrap: Data
}

public final class AegiroVault {
    public let url: URL
    public var header: VaultHeader
    public var index: VaultIndex
    public var manifest: Manifest
    public var openCtx: VaultOpenContext?

    public init(url: URL, header: VaultHeader, index: VaultIndex, manifest: Manifest) {
        self.url = url
        self.header = header
        self.index = index
        self.manifest = manifest
        self.openCtx = nil
    }

    public static func create(at url: URL, passphrase: String, touchID: Bool) throws -> AegiroVault {
        let kem = Kyber512()
        let sig = Dilithium2()
        let (kemPk, kemSk) = try kem.keypair()
        let (sigPk, sigSk) = try sig.keypair()

        let algs = AlgIDs(aead: vaultChunkAEADIDV1, kdf: 2, kem: 3, sig: 4)
        let argon = Argon2Params(mMiB: 256, t: 3, p: 1)
        let pq = PQPublicKeys(kyber_pk: kemPk, dilithium_pk: sigPk)
        var header = VaultHeader(alg: algs, argon2: argon, pq: pq)
        if touchID { header.flags |= vaultFlagTouchID }
        header.flags |= vaultFlagPQCUnlockV1

        let kdf = Argon2idKDF()
        let pdkRaw = try kdf.deriveKey(passphrase: passphrase, salt: header.kdf_salt, outLen: 32)
        let pdk = SymmetricKey(data: pdkRaw)

        let fileSeed = SymmetricKey(size: .bits256)
        let accessKey = SymmetricKey(size: .bits256)
        let dek = SymmetricKey(size: .bits256)
        let aad = vaultAAD

        let pdkNonce = AES.GCM.Nonce()
        let accessRaw = accessKey.withUnsafeBytes { Data($0) }
        let pdkWrap = try AEAD.encrypt(key: pdk, nonce: pdkNonce, plaintext: accessRaw, aad: aad)

        // sdkWrap will carry the Dilithium signing secret key wrapped under DEK
        let sigSkWrapNonce = AES.GCM.Nonce()
        let sigSkWrap = try AEAD.encrypt(key: dek,
                                         nonce: sigSkWrapNonce,
                                         plaintext: sigSk,
                                         aad: aad)
        let (ss, kemCt) = try kem.encap(kemPk)
        let kemSkWrapNonce = AES.GCM.Nonce()
        let kemSkWrap = try AEAD.encrypt(key: accessKey,
                                         nonce: kemSkWrapNonce,
                                         plaintext: kemSk,
                                         aad: aad)
        let accessBundle = PQAccessBundleV1(version: 1, kemCiphertext: kemCt, kemSecretWrap: kemSkWrap)
        let accessBundleBlob = try JSONEncoder().encode(accessBundle)
        let pqKey = SymmetricKey(data: ss)
        let pqNonce = AES.GCM.Nonce()
        let pqWrap = try AEAD.encrypt(key: pqKey, nonce: pqNonce, plaintext: dek.withUnsafeBytes{ raw in Data(bytes: raw.baseAddress!, count: raw.count) }, aad: aad)

        // Prepare index and manifest blobs with lengths for reliable parsing
        let index = VaultIndex(entries: [], thumbnails: [:])
        let idxKey = dek
        let idxBlob = try IndexCrypto.encryptIndex(index, key: idxKey, aad: aad)
        let idxLenLE = withUnsafeBytes(of: UInt32(idxBlob.count).littleEndian) { Data($0) }

        let chunkMap = try JSONSerialization.data(withJSONObject: [], options: [])
        let manifest = try ManifestBuilder.build(index: index, chunkMap: chunkMap, signer: sig, sk: sigSk, pk: sigPk)
        let manBlob = try JSONEncoder().encode(manifest)
        let manLenLE = withUnsafeBytes(of: UInt32(manBlob.count).littleEndian) { Data($0) }

        // Compute header with correct offsets after knowing sizes
        // We'll compute a provisional header to get JSON length for header_len and offsets
        let tempHeader = header
        // First, encode to know JSON length with placeholder offsets
        let provisional = try tempHeader.serialize()
        let hdrBaseLen = provisional.count // includes MAGIC + len + JSON
        let pdkOff = UInt32(hdrBaseLen)
        let sdkOff = pdkOff + UInt32(pdkWrap.count)
        let pqcOff = sdkOff + UInt32(sigSkWrap.count) // repurpose pqc_off to mark signer wrap start
        header.wraps_offsets = WrapOffsets(pdk_off: pdkOff, sdk_off: sdkOff, pqc_off: pqcOff)
        let finalHeader = try header.serialize()

        // Write out file in the agreed layout
        let fm = FileManager.default
        fm.createFile(atPath: url.path, contents: Data(), attributes: [.extensionHidden: true])
        let handle = try FileHandle(forWritingTo: url)
        try handle.write(contentsOf: finalHeader)
        try handle.write(contentsOf: pdkWrap)
        let ctLen = withUnsafeBytes(of: UInt32(accessBundleBlob.count).littleEndian, { raw in Data(bytes: raw.baseAddress!, count: raw.count) })
        try handle.write(contentsOf: ctLen)
        try handle.write(contentsOf: accessBundleBlob)
        try handle.write(contentsOf: pqWrap)
        // signer wrap len (u32) + blob (in addition to header offsets)
        let signerLen = withUnsafeBytes(of: UInt32(sigSkWrap.count).littleEndian) { Data($0) }
        try handle.write(contentsOf: signerLen)
        try handle.write(contentsOf: sigSkWrap)
        try handle.write(contentsOf: idxLenLE)
        try handle.write(contentsOf: idxBlob)
        try handle.write(contentsOf: manLenLE)
        try handle.write(contentsOf: manBlob)
        // initial empty chunk map (len + blob)
        let cmLenLE = withUnsafeBytes(of: UInt32(chunkMap.count).littleEndian) { Data($0) }
        try handle.write(contentsOf: cmLenLE)
        try handle.write(contentsOf: chunkMap)
        try handle.close()

        let v = AegiroVault(url: url, header: header, index: index, manifest: manifest)
        v.openCtx = VaultOpenContext(pdkKey: pdk, sdkKey: nil, pqSk: kemSk, sigPk: sigPk, fileNonceSeed: fileSeed)
        return v
    }

    public static func open(at url: URL) throws -> AegiroVault {
        let components = try readVaultReadComponents(vaultURL: url, includeIndex: false, includeManifest: true)
        // Note: index is encrypted; we return stub index until unlocked with passphrase.
        let manifest = try JSONDecoder().decode(Manifest.self, from: components.manBlob)
        let v = AegiroVault(url: url, header: components.header, index: VaultIndex(entries: [], thumbnails: [:]), manifest: manifest)
        return v
    }
}

func parseHeaderAndOffset(_ data: Data) throws -> (VaultHeader, Int) {
    guard data.count > 8 else { throw NSError(domain: "VaultHeader", code: -10) }
    let prefix = data.prefix(8)
    guard Array(prefix) == VaultHeader.MAGIC else { throw NSError(domain: "VaultHeader", code: -11) }
    // Try new format first
    if data.count >= 12 {
        let lenBytes = data.dropFirst(8).prefix(4)
        let headerLen = lenBytes.withUnsafeBytes { $0.load(as: UInt32.self) }.littleEndian
        let jsonStart = 12
        if data.count >= jsonStart + Int(headerLen) {
            let json = data.subdata(in: jsonStart..<(jsonStart + Int(headerLen)))
            if let hdr = try? JSONDecoder().decode(VaultHeader.self, from: json) {
                return (hdr, jsonStart + Int(headerLen))
            }
        }
    }
    // Legacy fallback: JSON immediately after MAGIC
    let maxEnd = min(data.count, 8 + 4096)
    var endIdx = 8
    while endIdx <= maxEnd {
        let slice = data.subdata(in: 8..<endIdx)
        if let hdr = try? JSONDecoder().decode(VaultHeader.self, from: slice) {
            return (hdr, endIdx)
        }
        endIdx += 1
    }
    throw NSError(domain: "VaultHeader", code: -12)
}

private struct VaultReadComponents {
    let header: VaultHeader
    let pdkWrap: Data
    let pqAccessBlob: Data
    let pqWrap: Data
    let idxBlob: Data
    let manBlob: Data
}

private func readExactBytes(from handle: FileHandle, offset: UInt64, count: Int) throws -> Data {
    guard count >= 0 else {
        throw NSError(domain: "VaultRead", code: -1, userInfo: [NSLocalizedDescriptionKey: "Invalid read length"])
    }
    try handle.seek(toOffset: offset)
    guard let data = try handle.read(upToCount: count), data.count == count else {
        throw NSError(domain: "VaultRead", code: -2, userInfo: [NSLocalizedDescriptionKey: "Unexpected end of file while reading vault"])
    }
    return data
}

private func readUInt32LE(from handle: FileHandle, offset: UInt64) throws -> UInt32 {
    let data = try readExactBytes(from: handle, offset: offset, count: 4)
    return data.withUnsafeBytes { $0.load(as: UInt32.self) }.littleEndian
}

private func readVaultReadComponents(vaultURL: URL,
                                     includeIndex: Bool,
                                     includeManifest: Bool) throws -> VaultReadComponents {
    let handle = try FileHandle(forReadingFrom: vaultURL)
    defer { try? handle.close() }
    let fileSize = (try? FileManager.default.attributesOfItem(atPath: vaultURL.path)[.size] as? NSNumber)?.uint64Value ?? 0
    guard fileSize > 12 else {
        throw NSError(domain: "VaultRead", code: -3, userInfo: [NSLocalizedDescriptionKey: "Vault file is too small"])
    }

    let probeSizes: [Int] = [8 * 1024, 64 * 1024, 512 * 1024, 2 * 1024 * 1024]
    var parsedHeader: (VaultHeader, Int)?
    for size in probeSizes {
        let readCount = Int(min(UInt64(size), fileSize))
        guard readCount > 0 else { break }
        let prefix = try readExactBytes(from: handle, offset: 0, count: readCount)
        if let result = try? parseHeaderAndOffset(prefix) {
            parsedHeader = result
            break
        }
        if UInt64(readCount) >= fileSize {
            break
        }
    }

    guard let (header, headerLen) = parsedHeader else {
        throw NSError(domain: "VaultRead", code: -4, userInfo: [NSLocalizedDescriptionKey: "Could not parse vault header"])
    }

    var cursor = UInt64(headerLen)

    let pdkWrap = try readExactBytes(from: handle, offset: cursor, count: 60)
    cursor += 60

    let pqCiphertextLength = Int(try readUInt32LE(from: handle, offset: cursor))
    cursor += 4
    let pqAccessBlob = try readExactBytes(from: handle, offset: cursor, count: pqCiphertextLength)
    cursor += UInt64(pqCiphertextLength)

    let pqWrap = try readExactBytes(from: handle, offset: cursor, count: 60)
    cursor += 60

    let signerWrapLength = Int(try readUInt32LE(from: handle, offset: cursor))
    cursor += 4 + UInt64(signerWrapLength)

    let idxLength = Int(try readUInt32LE(from: handle, offset: cursor))
    cursor += 4
    let idxBlob = includeIndex
        ? try readExactBytes(from: handle, offset: cursor, count: idxLength)
        : Data()
    cursor += UInt64(idxLength)

    let manifestLength = Int(try readUInt32LE(from: handle, offset: cursor))
    cursor += 4
    let manBlob = includeManifest
        ? try readExactBytes(from: handle, offset: cursor, count: manifestLength)
        : Data()

    return VaultReadComponents(header: header,
                               pdkWrap: pdkWrap,
                               pqAccessBlob: pqAccessBlob,
                               pqWrap: pqWrap,
                               idxBlob: idxBlob,
                               manBlob: manBlob)
}

private func normalizedPath(_ url: URL) -> String {
    return url.standardizedFileURL.resolvingSymlinksInPath().path
}

private func sanitizedExportRelativePath(from logicalPath: String) -> String {
    let normalized = logicalPath.replacingOccurrences(of: "\\", with: "/")
    let rawComponents = normalized
        .split(separator: "/", omittingEmptySubsequences: true)
        .map(String.init)

    let safeComponents: [String]
    if rawComponents.isEmpty {
        safeComponents = ["unnamed"]
    } else {
        safeComponents = rawComponents.map { component in
            var trimmed = component.trimmingCharacters(in: .whitespacesAndNewlines)
            if trimmed.isEmpty || trimmed == "." || trimmed == ".." {
                trimmed = "_"
            }
            return trimmed.replacingOccurrences(of: ":", with: "_")
        }
    }

    return NSString.path(withComponents: safeComponents)
}

private func preferredVaultChunkAlgorithm() -> UInt8 {
    #if arch(arm64)
    return vaultChunkAlgAESGCM
    #else
    return vaultChunkAlgChaChaPoly1305
    #endif
}

private func secureRandomData(count: Int) throws -> Data {
    var data = Data(count: count)
    let status = data.withUnsafeMutableBytes { raw in
        guard let base = raw.baseAddress else { return errSecParam }
        return SecRandomCopyBytes(kSecRandomDefault, count, base)
    }
    if status != errSecSuccess {
        throw AEGError.crypto("SecRandomCopyBytes failed: \(status)")
    }
    return data
}

private func makeVaultChunkCrypto() throws -> VaultChunkCrypto {
    VaultChunkCrypto(format: vaultChunkFormatV1,
                     algorithm: preferredVaultChunkAlgorithm(),
                     keySalt: try secureRandomData(count: vaultChunkKeySaltLength),
                     noncePrefix: try secureRandomData(count: vaultChunkNoncePrefixLength))
}

private func validateVaultChunkCrypto(_ crypto: VaultChunkCrypto) throws {
    guard crypto.format == vaultChunkFormatV1 else {
        throw AEGError.unsupported("Unsupported chunk crypto format: \(crypto.format)")
    }
    guard crypto.keySalt.count == vaultChunkKeySaltLength else {
        throw AEGError.integrity("Invalid chunk key salt length: \(crypto.keySalt.count)")
    }
    guard crypto.noncePrefix.count == vaultChunkNoncePrefixLength else {
        throw AEGError.integrity("Invalid chunk nonce prefix length: \(crypto.noncePrefix.count)")
    }
    guard crypto.algorithm == vaultChunkAlgAESGCM || crypto.algorithm == vaultChunkAlgChaChaPoly1305 else {
        throw AEGError.unsupported("Unsupported chunk algorithm: \(crypto.algorithm)")
    }
}

private func deriveVaultFileKey(dek: SymmetricKey,
                                fileID: Data,
                                crypto: VaultChunkCrypto,
                                infoPrefix: Data = vaultFileKeyInfoPrefixV1) throws -> SymmetricKey {
    try validateVaultChunkCrypto(crypto)
    let info = infoPrefix + fileID + Data([crypto.algorithm, crypto.format])
    return HKDF<SHA256>.deriveKey(inputKeyMaterial: dek,
                                  salt: crypto.keySalt,
                                  info: info,
                                  outputByteCount: 32)
}

private func makeVaultChunkAAD(vaultSalt: Data,
                               fileID: Data,
                               ordinal: UInt32,
                               crypto: VaultChunkCrypto,
                               aadPrefix: Data = vaultChunkAADPrefixV1) -> Data {
    var out = Data()
    out.reserveCapacity(aadPrefix.count + vaultSalt.count + fileID.count + 8)
    out.append(aadPrefix)
    out.append(vaultSalt)
    out.append(fileID)
    out.append(Data([crypto.algorithm, crypto.format]))
    var ordinalLE = ordinal.littleEndian
    withUnsafeBytes(of: &ordinalLE) { out.append(contentsOf: $0) }
    return out
}

private func makeVaultChunkNonce(prefix: Data, ordinal: UInt32) -> Data {
    var out = Data()
    out.reserveCapacity(12)
    out.append(prefix)
    var ctr = UInt64(ordinal).littleEndian
    withUnsafeBytes(of: &ctr) { out.append(contentsOf: $0) }
    return out
}

private func sealVaultChunk(_ plaintext: Data,
                            key: SymmetricKey,
                            nonceData: Data,
                            aad: Data,
                            algorithm: UInt8) throws -> Data {
    switch algorithm {
    case vaultChunkAlgAESGCM:
        let nonce = try AES.GCM.Nonce(data: nonceData)
        let sealed = try AES.GCM.seal(plaintext, using: key, nonce: nonce, authenticating: aad)
        var out = Data()
        out.reserveCapacity(sealed.ciphertext.count + sealed.tag.count)
        out.append(sealed.ciphertext)
        out.append(sealed.tag)
        return out
    case vaultChunkAlgChaChaPoly1305:
        let nonce = try ChaChaPoly.Nonce(data: nonceData)
        let sealed = try ChaChaPoly.seal(plaintext, using: key, nonce: nonce, authenticating: aad)
        var out = Data()
        out.reserveCapacity(sealed.ciphertext.count + sealed.tag.count)
        out.append(sealed.ciphertext)
        out.append(sealed.tag)
        return out
    default:
        throw AEGError.unsupported("Unsupported chunk algorithm: \(algorithm)")
    }
}

private func openVaultChunk(_ payload: Data,
                            key: SymmetricKey,
                            nonceData: Data,
                            aad: Data,
                            algorithm: UInt8) throws -> Data {
    guard payload.count >= vaultChunkTagLength else {
        throw AEGError.integrity("Chunk payload too short")
    }
    let ct = payload.prefix(payload.count - vaultChunkTagLength)
    let tag = payload.suffix(vaultChunkTagLength)
    switch algorithm {
    case vaultChunkAlgAESGCM:
        let nonce = try AES.GCM.Nonce(data: nonceData)
        let box = try AES.GCM.SealedBox(nonce: nonce, ciphertext: ct, tag: tag)
        return try AES.GCM.open(box, using: key, authenticating: aad)
    case vaultChunkAlgChaChaPoly1305:
        let nonce = try ChaChaPoly.Nonce(data: nonceData)
        let box = try ChaChaPoly.SealedBox(nonce: nonce, ciphertext: ct, tag: tag)
        return try ChaChaPoly.open(box, using: key, authenticating: aad)
    default:
        throw AEGError.unsupported("Unsupported chunk algorithm: \(algorithm)")
    }
}

private func ensureVaultChunkScheme(_ head: VaultHeader) throws {
    guard head.alg_ids.aead == vaultChunkAEADIDV1 else {
        throw AEGError.unsupported("Unsupported vault chunk AEAD id \(head.alg_ids.aead). Expected \(vaultChunkAEADIDV1).")
    }
}

public enum Importer {
    private static func throwIfCancelled(_ isCancelled: (() -> Bool)?) throws {
        if isCancelled?() == true {
            throw AEGError.io("USB vault-pack cancelled by user.")
        }
    }

    private static func expandImportSources(_ files: [URL],
                                            isCancelled: (() -> Bool)? = nil) throws -> [URL] {
        try throwIfCancelled(isCancelled)
        let fm = FileManager.default
        let keys: Set<URLResourceKey> = [.isRegularFileKey, .isDirectoryKey, .isSymbolicLinkKey]
        var expanded: [URL] = []
        expanded.reserveCapacity(files.count)

        for input in files {
            try throwIfCancelled(isCancelled)
            let normalizedInput = input.standardizedFileURL.resolvingSymlinksInPath()
            var isDirectory: ObjCBool = false
            guard fm.fileExists(atPath: normalizedInput.path, isDirectory: &isDirectory) else {
                throw AEGError.io("Import source does not exist: \(normalizedInput.path)")
            }

            if !isDirectory.boolValue {
                expanded.append(normalizedInput)
                continue
            }

            guard let enumerator = fm.enumerator(at: normalizedInput,
                                                 includingPropertiesForKeys: Array(keys),
                                                 options: [],
                                                 errorHandler: { _, _ in true }) else {
                throw AEGError.io("Unable to enumerate import directory: \(normalizedInput.path)")
            }

            var directoryFiles: [URL] = []
            while let item = enumerator.nextObject() as? URL {
                try throwIfCancelled(isCancelled)
                let rawCandidate = item.standardizedFileURL
                let values = try? rawCandidate.resourceValues(forKeys: keys)
                if values?.isSymbolicLink == true {
                    if values?.isDirectory == true {
                        enumerator.skipDescendants()
                    }
                    continue
                }
                if values?.isDirectory == true {
                    continue
                }
                if values?.isRegularFile == true {
                    directoryFiles.append(rawCandidate.resolvingSymlinksInPath())
                }
            }
            directoryFiles.sort { $0.path.localizedCaseInsensitiveCompare($1.path) == .orderedAscending }
            expanded.append(contentsOf: directoryFiles)
        }
        return expanded
    }

    public static func sidecarImport(vaultURL: URL,
                                     passphrase: String,
                                     files: [URL],
                                     progress: ((Int, Int, String) -> Void)? = nil,
                                     preparationProgress: ((Int, Int, String) -> Void)? = nil,
                                     isCancelled: (() -> Bool)? = nil) throws -> (imported: Int, sidecar: URL) {
        try throwIfCancelled(isCancelled)
        let sidecar = vaultURL.deletingPathExtension().appendingPathExtension("aegirofiles")
        defer {
            try? FileManager.default.removeItem(at: sidecar)
        }
        let data = try Data(contentsOf: vaultURL)
        let (head, hdrLen) = try parseHeaderAndOffset(data)
        try ensureVaultChunkScheme(head)
        let layout = computeLayout(data, afterHeader: hdrLen)
        let dek = try Exporter.deriveDEK(data: data, passphrase: passphrase)
        let aad = vaultAAD
        let items = try directImportItems(files: files,
                                          vaultURL: vaultURL,
                                          sidecarURL: sidecar,
                                          head: head,
                                          preparationProgress: preparationProgress,
                                          isCancelled: isCancelled)
        let imported = try mergeImportedItems(vaultURL: vaultURL,
                                              data: data,
                                              head: head,
                                              layout: layout,
                                              dek: dek,
                                              aad: aad,
                                              items: items,
                                              progress: progress,
                                              isCancelled: isCancelled)
        return (imported, sidecar)
    }

    private static func directImportItems(files: [URL],
                                          vaultURL: URL,
                                          sidecarURL: URL,
                                          head: VaultHeader,
                                          preparationProgress: ((Int, Int, String) -> Void)? = nil,
                                          isCancelled: (() -> Bool)? = nil) throws -> [ImportItem] {
        try throwIfCancelled(isCancelled)
        let expandedFiles = try expandImportSources(files, isCancelled: isCancelled)
        let vaultPath = normalizedPath(vaultURL)
        let sidecarPath = normalizedPath(sidecarURL)
        let sidecarPrefix = sidecarPath.hasSuffix("/") ? sidecarPath : sidecarPath + "/"
        var candidates: [(sourcePath: String, sourceURL: URL, nameHash: Data)] = []
        var seenSources = Set<String>()
        for f in expandedFiles {
            let sourcePath = normalizedPath(f)
            if sourcePath == vaultPath || sourcePath == sidecarPath || sourcePath.hasPrefix(sidecarPrefix) {
                continue
            }
            if seenSources.contains(sourcePath) {
                continue
            }
            let name = (sourcePath as NSString).lastPathComponent
            let h = HMACUtil.hmacNameHash(name, salt: head.index_salt)
            candidates.append((sourcePath: sourcePath, sourceURL: f, nameHash: h))
            seenSources.insert(sourcePath)
        }

        let total = candidates.count
        var items: [ImportItem] = []
        items.reserveCapacity(total)
        for (index, candidate) in candidates.enumerated() {
            try throwIfCancelled(isCancelled)
            items.append(ImportItem(path: candidate.sourcePath,
                                    nameHash: candidate.nameHash,
                                    order: index,
                                    payload: .sourceURL(candidate.sourceURL)))
            preparationProgress?(index + 1, total, candidate.sourcePath)
        }
        return items
    }
}

struct VaultLayout {
    let headerLen: Int
    let pdkWrapRange: Range<Int>
    let pqCtRange: Range<Int>
    let pqWrapRange: Range<Int>
    let signerWrapLenPos: Int
    let signerWrapRange: Range<Int>
    let idxLenPos: Int
    let idxRange: Range<Int>
    let manLenPos: Int
    let manRange: Range<Int>
    let chunkMapLenPos: Int
    let chunkMapRange: Range<Int>
    let chunkAreaStart: Int
}

func computeLayout(_ data: Data, afterHeader hdrLen: Int) -> VaultLayout {
    var cursor = hdrLen
    // pdk wrap (12+32+16)
    let pdkRange = cursor..<(cursor+60)
    cursor += 60
    // pq ct len + ct
    let ctLen = data.subdata(in: cursor..<(cursor+4)).withUnsafeBytes { $0.load(as: UInt32.self) }.littleEndian
    cursor += 4
    let pqCtRange = cursor..<(cursor + Int(ctLen))
    cursor += Int(ctLen)
    // pq wrap (12+32+16)
    let pqWrapRange = cursor..<(cursor + 60)
    cursor += 60
    // signer wrap len + blob
    let signerLenPos = cursor
    let signerLen = data.subdata(in: cursor..<(cursor+4)).withUnsafeBytes { $0.load(as: UInt32.self) }.littleEndian
    cursor += 4
    let signerRange = cursor..<(cursor + Int(signerLen))
    cursor += Int(signerLen)
    // idx len + blob
    let idxLenPos = cursor
    let idxLen = data.subdata(in: cursor..<(cursor+4)).withUnsafeBytes { $0.load(as: UInt32.self) }.littleEndian
    cursor += 4
    let idxRange = cursor..<(cursor + Int(idxLen))
    cursor += Int(idxLen)
    // manifest len + blob
    let manLenPos = cursor
    let manLen = data.subdata(in: cursor..<(cursor+4)).withUnsafeBytes { $0.load(as: UInt32.self) }.littleEndian
    cursor += 4
    let manRange = cursor..<(cursor + Int(manLen))
    cursor += Int(manLen)
    // chunk map len + blob
    let cmLenPos = cursor
    let cmLen = data.subdata(in: cursor..<(cursor+4)).withUnsafeBytes { $0.load(as: UInt32.self) }.littleEndian
    cursor += 4
    let cmRange = cursor..<(cursor + Int(cmLen))
    cursor += Int(cmLen)
    let chunkStart = cursor
    return VaultLayout(headerLen: hdrLen,
                       pdkWrapRange: pdkRange,
                       pqCtRange: pqCtRange,
                       pqWrapRange: pqWrapRange,
                       signerWrapLenPos: signerLenPos,
                       signerWrapRange: signerRange,
                       idxLenPos: idxLenPos,
                       idxRange: idxRange,
                       manLenPos: manLenPos,
                       manRange: manRange,
                       chunkMapLenPos: cmLenPos,
                       chunkMapRange: cmRange,
                       chunkAreaStart: chunkStart)
}

private enum ImportPayload {
    case plaintext(Data)
    case sourceURL(URL)
}

private struct ImportItem {
    let path: String
    let nameHash: Data
    let order: Int
    let payload: ImportPayload
}

private func mergeImportedItems(vaultURL: URL,
                                data: Data,
                                head: VaultHeader,
                                layout: VaultLayout,
                                dek: SymmetricKey,
                                aad: Data,
                                items: [ImportItem],
                                progress: ((Int, Int, String) -> Void)? = nil,
                                isCancelled: (() -> Bool)? = nil) throws -> Int {
    if isCancelled?() == true {
        throw AEGError.io("USB vault-pack cancelled by user.")
    }
    try ensureVaultChunkScheme(head)
    guard !items.isEmpty else { return 0 }

    let idxBlobOld = data.subdata(in: layout.idxRange)
    var index = try IndexCrypto.decryptIndex(idxBlobOld, key: dek, aad: aad)

    let replacingPaths = Set(items.map { $0.path })
    let replacedCount = index.entries.reduce(into: 0) { count, entry in
        if replacingPaths.contains(entry.logicalPath) {
            count += 1
        }
    }
    try VaultLimits.enforceProjectedFileCount(existingCount: index.entries.count,
                                              replacedCount: replacedCount,
                                              addingCount: items.count)

    // Preserve existing encrypted chunks except for paths being replaced.
    let existingCM = data.subdata(in: layout.chunkMapRange)
    let existingChunks = ((try? JSONDecoder().decode([ChunkInfo].self, from: existingCM)) ?? []).sorted { $0.relOffset < $1.relOffset }
    let existingArea = data.subdata(in: layout.chunkAreaStart..<data.count)
    let replacingFileIDs = Set(index.entries.filter { replacingPaths.contains($0.logicalPath) }.map(\.fileID))

    let chunkSize = 128 * 1024
    var chunkArea = Data()
    var chunkInfos: [ChunkInfo] = []
    chunkArea.reserveCapacity(existingArea.count)

    for c in existingChunks where !replacingFileIDs.contains(c.fileID) {
        if isCancelled?() == true {
            throw AEGError.io("USB vault-pack cancelled by user.")
        }
        let start = Int(c.relOffset)
        let end = start + c.length
        guard start >= 0, end <= existingArea.count else { continue }
        let blob = existingArea.subdata(in: start..<end)
        let offset = UInt64(chunkArea.count)
        chunkArea.append(blob)
        chunkInfos.append(ChunkInfo(fileID: c.fileID,
                                    ordinal: c.ordinal,
                                    relOffset: offset,
                                    length: blob.count))
    }

    // Replace matching entries while keeping metadata for untouched files.
    let priorByPath = Dictionary(uniqueKeysWithValues: index.entries.map { ($0.logicalPath, $0) })
    index.entries.removeAll { replacingPaths.contains($0.logicalPath) }

    // Encrypt new plaintext data and append chunk descriptors.
    let orderedItems = items.sorted(by: { $0.order < $1.order })
    let totalItems = orderedItems.count
    var importedCount = 0
    for item in orderedItems {
        if isCancelled?() == true {
            throw AEGError.io("USB vault-pack cancelled by user.")
        }
        let fileID = try secureRandomData(count: 16)
        let chunkCrypto = try makeVaultChunkCrypto()
        let fileKey = try deriveVaultFileKey(dek: dek, fileID: fileID, crypto: chunkCrypto)
        var fileChunkIndex: UInt32 = 0
        var perFileCount = 0
        var plainSize: UInt64 = 0
        switch item.payload {
        case .plaintext(let plain):
            plainSize = UInt64(plain.count)
            var remaining = plain.count
            var cursorPlain = 0
            while remaining > 0 {
                if isCancelled?() == true {
                    throw AEGError.io("USB vault-pack cancelled by user.")
                }
                let n = min(remaining, chunkSize)
                let chunk = plain.subdata(in: cursorPlain..<(cursorPlain + n))
                let nonceData = makeVaultChunkNonce(prefix: chunkCrypto.noncePrefix, ordinal: fileChunkIndex)
                let chunkAAD = makeVaultChunkAAD(vaultSalt: head.kdf_salt,
                                                 fileID: fileID,
                                                 ordinal: fileChunkIndex,
                                                 crypto: chunkCrypto)
                let payload = try sealVaultChunk(chunk,
                                                 key: fileKey,
                                                 nonceData: nonceData,
                                                 aad: chunkAAD,
                                                 algorithm: chunkCrypto.algorithm)
                let offset = UInt64(chunkArea.count)
                chunkArea.append(payload)
                chunkInfos.append(ChunkInfo(fileID: fileID,
                                            ordinal: fileChunkIndex,
                                            relOffset: offset,
                                            length: payload.count))
                if fileChunkIndex == UInt32.max {
                    throw AEGError.io("File \(item.path) exceeds max supported chunk count")
                }
                fileChunkIndex += 1
                perFileCount += 1
                remaining -= n
                cursorPlain += n
            }
        case .sourceURL(let sourceURL):
            let handle = try FileHandle(forReadingFrom: sourceURL)
            defer { try? handle.close() }
            while true {
                if isCancelled?() == true {
                    throw AEGError.io("USB vault-pack cancelled by user.")
                }
                guard let chunk = try handle.read(upToCount: chunkSize), !chunk.isEmpty else {
                    break
                }
                let nonceData = makeVaultChunkNonce(prefix: chunkCrypto.noncePrefix, ordinal: fileChunkIndex)
                let chunkAAD = makeVaultChunkAAD(vaultSalt: head.kdf_salt,
                                                 fileID: fileID,
                                                 ordinal: fileChunkIndex,
                                                 crypto: chunkCrypto)
                let payload = try sealVaultChunk(chunk,
                                                 key: fileKey,
                                                 nonceData: nonceData,
                                                 aad: chunkAAD,
                                                 algorithm: chunkCrypto.algorithm)
                let offset = UInt64(chunkArea.count)
                chunkArea.append(payload)
                chunkInfos.append(ChunkInfo(fileID: fileID,
                                            ordinal: fileChunkIndex,
                                            relOffset: offset,
                                            length: payload.count))
                if fileChunkIndex == UInt32.max {
                    throw AEGError.io("File \(item.path) exceeds max supported chunk count")
                }
                fileChunkIndex += 1
                perFileCount += 1
                plainSize += UInt64(chunk.count)
            }
        }

        let previous = priorByPath[item.path]
        let now = Date()
        let entry = VaultIndexEntry(fileID: fileID,
                                    nameHash: item.nameHash,
                                    logicalPath: item.path,
                                    size: plainSize,
                                    mime: previous?.mime ?? "application/octet-stream",
                                    tags: previous?.tags ?? [],
                                    chunkCount: perFileCount,
                                    chunkCrypto: chunkCrypto,
                                    created: previous?.created ?? now,
                                    modified: now,
                                    sidecarName: nil)
        index.entries.append(entry)
        importedCount += 1
        progress?(importedCount, totalItems, item.path)
    }

    let chunkCounts = chunkInfos.reduce(into: [Data: Int]()) { counts, chunk in
        counts[chunk.fileID, default: 0] += 1
    }
    for i in index.entries.indices {
        if isCancelled?() == true {
            throw AEGError.io("USB vault-pack cancelled by user.")
        }
        let fileID = index.entries[i].fileID
        index.entries[i].chunkCount = chunkCounts[fileID] ?? 0
        index.entries[i].sidecarName = nil
    }

    // Build new index/blob and chunk map.
    if isCancelled?() == true {
        throw AEGError.io("USB vault-pack cancelled by user.")
    }
    let newIdxBlob = try IndexCrypto.encryptIndex(index, key: dek, aad: aad)
    let chunkMap = try JSONEncoder().encode(chunkInfos)

    // Re-sign manifest using signer SK (wrapped under DEK).
    if isCancelled?() == true {
        throw AEGError.io("USB vault-pack cancelled by user.")
    }
    let signerWrap = data.subdata(in: layout.signerWrapRange)
    let signerSk = try AEAD.decrypt(key: dek, nonce: try AES.GCM.Nonce(data: signerWrap.prefix(12)), combined: signerWrap, aad: aad)
    let sig = Dilithium2()
    let manifest = try ManifestBuilder.build(index: index, chunkMap: chunkMap, signer: sig, sk: signerSk, pk: head.pq_pubkeys.dilithium_pk)
    let manBlob = try JSONEncoder().encode(manifest)

    // Reconstruct vault file in-memory (header + wraps + idx + manifest + chunk map + chunk area).
    if isCancelled?() == true {
        throw AEGError.io("USB vault-pack cancelled by user.")
    }
    let pqCt = data.subdata(in: layout.pqCtRange)
    let pqWrap = data.subdata(in: layout.pqWrapRange)

    let signerLen = data.subdata(in: layout.signerWrapLenPos..<(layout.signerWrapLenPos+4))
    let signerBlob = data.subdata(in: layout.signerWrapRange)
    let pdkBlob = data.subdata(in: layout.pdkWrapRange)

    let idxLenLE = withUnsafeBytes(of: UInt32(newIdxBlob.count).littleEndian) { Data($0) }
    let manLenLE = withUnsafeBytes(of: UInt32(manBlob.count).littleEndian) { Data($0) }

    var out = Data()
    let finalHeader = try head.serialize()
    out.append(finalHeader)
    out.append(pdkBlob)
    out.append(withUnsafeBytes(of: UInt32(pqCt.count).littleEndian) { Data($0) })
    out.append(pqCt)
    out.append(pqWrap)
    out.append(signerLen)
    out.append(signerBlob)
    out.append(idxLenLE)
    out.append(newIdxBlob)
    out.append(manLenLE)
    out.append(manBlob)
    let cmLenLE = withUnsafeBytes(of: UInt32(chunkMap.count).littleEndian) { Data($0) }
    out.append(cmLenLE)
    out.append(chunkMap)
    out.append(chunkArea)

    if isCancelled?() == true {
        throw AEGError.io("USB vault-pack cancelled by user.")
    }
    try out.write(to: vaultURL, options: .atomic)
    Exporter.invalidateListCache(vaultURL: vaultURL)
    return importedCount
}

private func derivePassphraseKey(passphrase: String, salt: Data) throws -> SymmetricKey {
    let kdf = Argon2idKDF()
    let raw = try kdf.deriveKey(passphrase: passphrase, salt: salt, outLen: 32)
    return SymmetricKey(data: raw)
}

private func unlockDEK(data: Data, head: VaultHeader, layout: VaultLayout, passphrase: String) throws -> SymmetricKey {
    let pdkWrap = data.subdata(in: layout.pdkWrapRange)
    let accessBlob = data.subdata(in: layout.pqCtRange)
    let pqWrap = data.subdata(in: layout.pqWrapRange)
    return try unlockDEK(head: head,
                         pdkWrap: pdkWrap,
                         pqAccessBlob: accessBlob,
                         pqWrap: pqWrap,
                         passphrase: passphrase)
}

private func unlockDEK(head: VaultHeader,
                       pdkWrap: Data,
                       pqAccessBlob: Data,
                       pqWrap: Data,
                       passphrase: String) throws -> SymmetricKey {
    let pdk = try derivePassphraseKey(passphrase: passphrase, salt: head.kdf_salt)
    let pdkPlain = try AEAD.decrypt(key: pdk, nonce: try AES.GCM.Nonce(data: pdkWrap.prefix(12)), combined: pdkWrap, aad: vaultAAD)

    // Legacy vaults: DEK was wrapped directly under passphrase-derived key.
    if (head.flags & vaultFlagPQCUnlockV1) == 0 {
        return SymmetricKey(data: pdkPlain)
    }

    guard pdkPlain.count == 32 else {
        throw AEGError.integrity("Invalid PQC access key length: \(pdkPlain.count)")
    }
    let accessKey = SymmetricKey(data: pdkPlain)

    let accessBundle: PQAccessBundleV1
    do {
        accessBundle = try JSONDecoder().decode(PQAccessBundleV1.self, from: pqAccessBlob)
    } catch {
        throw AEGError.integrity("PQC access bundle decode failed: \(error)")
    }
    guard accessBundle.version == 1 else {
        throw AEGError.unsupported("Unsupported PQC access bundle version: \(accessBundle.version)")
    }

    let kemSk = try AEAD.decrypt(key: accessKey,
                                 nonce: try AES.GCM.Nonce(data: accessBundle.kemSecretWrap.prefix(12)),
                                 combined: accessBundle.kemSecretWrap,
                                 aad: vaultAAD)
    let kem = Kyber512()
    let ss = try kem.decap(accessBundle.kemCiphertext, sk: kemSk)
    let pqKey = SymmetricKey(data: ss)
    let dekRaw = try AEAD.decrypt(key: pqKey,
                                  nonce: try AES.GCM.Nonce(data: pqWrap.prefix(12)),
                                  combined: pqWrap,
                                  aad: vaultAAD)
    return SymmetricKey(data: dekRaw)
}

private enum UnlockMode {
    case legacy
    case pqcV1
}

private func inferUnlockMode(data: Data, head: VaultHeader, layout: VaultLayout, passphrase: String) throws -> UnlockMode {
    let pdk = try derivePassphraseKey(passphrase: passphrase, salt: head.kdf_salt)
    let pdkWrap = data.subdata(in: layout.pdkWrapRange)
    let pdkPlain = try AEAD.decrypt(key: pdk, nonce: try AES.GCM.Nonce(data: pdkWrap.prefix(12)), combined: pdkWrap, aad: vaultAAD)

    let idxBlob = data.subdata(in: layout.idxRange)

    let legacyDEK = SymmetricKey(data: pdkPlain)
    let legacyValid = (try? IndexCrypto.decryptIndex(idxBlob, key: legacyDEK, aad: vaultAAD)) != nil

    var pqcValid = false
    if pdkPlain.count == 32 {
        let accessKey = SymmetricKey(data: pdkPlain)
        let accessBlob = data.subdata(in: layout.pqCtRange)
        if let accessBundle = try? JSONDecoder().decode(PQAccessBundleV1.self, from: accessBlob),
           accessBundle.version == 1,
           let kemSk = try? AEAD.decrypt(key: accessKey,
                                         nonce: try AES.GCM.Nonce(data: accessBundle.kemSecretWrap.prefix(12)),
                                         combined: accessBundle.kemSecretWrap,
                                         aad: vaultAAD) {
            do {
                let kem = Kyber512()
                let ss = try kem.decap(accessBundle.kemCiphertext, sk: kemSk)
                let pqKey = SymmetricKey(data: ss)
                let pqWrap = data.subdata(in: layout.pqWrapRange)
                let dekRaw = try AEAD.decrypt(key: pqKey,
                                              nonce: try AES.GCM.Nonce(data: pqWrap.prefix(12)),
                                              combined: pqWrap,
                                              aad: vaultAAD)
                let pqDEK = SymmetricKey(data: dekRaw)
                pqcValid = (try? IndexCrypto.decryptIndex(idxBlob, key: pqDEK, aad: vaultAAD)) != nil
            } catch {
                pqcValid = false
            }
        }
    }

    switch (legacyValid, pqcValid) {
    case (true, false):
        return .legacy
    case (false, true):
        return .pqcV1
    case (true, true):
        return (head.flags & vaultFlagPQCUnlockV1) != 0 ? .pqcV1 : .legacy
    case (false, false):
        throw AEGError.integrity("Could not infer unlock mode from passphrase and index data.")
    }
}

public enum Locker {
    public static func unlockInfo(vaultURL: URL, passphrase: String) throws -> Int {
        let firstPage = try Exporter.listPage(vaultURL: vaultURL,
                                              passphrase: passphrase,
                                              offset: 0,
                                              limit: 1)
        return firstPage.totalCount
    }

    public static func lockFromSidecar(vaultURL: URL, passphrase: String) throws -> Int {
        let data = try Data(contentsOf: vaultURL)
        let (head, hdrLen) = try parseHeaderAndOffset(data)
        let layout = computeLayout(data, afterHeader: hdrLen)
        let dek = try Exporter.deriveDEK(data: data, passphrase: passphrase)
        let aad = vaultAAD

        // Read sidecar meta
        let sidecar = vaultURL.deletingPathExtension().appendingPathExtension("aegirofiles")
        let metaURL = sidecar.appendingPathComponent("index.json")
        guard FileManager.default.fileExists(atPath: metaURL.path) else { return 0 }
        let metaObj = try JSONSerialization.jsonObject(with: Data(contentsOf: metaURL)) as? [[String: Any]] ?? []
        let vaultPath = normalizedPath(vaultURL)
        let sidecarPath = normalizedPath(sidecar)
        let sidecarPrefix = sidecarPath.hasSuffix("/") ? sidecarPath : sidecarPath + "/"

        // Deduplicate by logical path: newest sidecar record wins.
        var stagedByPath: [String: ImportItem] = [:]
        var order = 0
        for item in metaObj {
            defer { order += 1 }
            guard let source = item["source"] as? String,
                  let stored = item["stored"] as? String else { continue }
            let normalizedSource = normalizedPath(URL(fileURLWithPath: source))
            if normalizedSource == vaultPath || normalizedSource == sidecarPath || normalizedSource.hasPrefix(sidecarPrefix) {
                continue
            }
            let blobURL = sidecar.appendingPathComponent(stored)
            guard let blob = try? Data(contentsOf: blobURL) else { continue }
            guard let sealed = try? AES.GCM.SealedBox(combined: blob),
                  let plain = try? AES.GCM.open(sealed, using: dek) else { continue }
            let name = (normalizedSource as NSString).lastPathComponent
            let h = HMACUtil.hmacNameHash(name, salt: head.index_salt)
            stagedByPath[normalizedSource] = ImportItem(path: normalizedSource,
                                                        nameHash: h,
                                                        order: order,
                                                        payload: .plaintext(plain))
        }
        let staged = stagedByPath.values.sorted { $0.order < $1.order }
        guard !staged.isEmpty else {
            try? FileManager.default.removeItem(at: sidecar)
            return 0
        }
        let added = try mergeImportedItems(vaultURL: vaultURL, data: data, head: head, layout: layout, dek: dek, aad: aad, items: staged)

        // cleanup sidecar
        try? FileManager.default.removeItem(at: sidecar)
        return added
    }
}

public enum Exporter {
    private struct ListCacheEntry {
        let entries: [VaultIndexEntry]
        let insertedAt: Date
    }

    private static let listCacheLimit = 4
    private static let listCacheLock = NSLock()
    private static var listCache: [String: ListCacheEntry] = [:]
    private static var listCacheOrder: [String] = []

    static func deriveDEK(data: Data, passphrase: String) throws -> SymmetricKey {
        let (head, hdrLen) = try parseHeaderAndOffset(data)
        let layout = computeLayout(data, afterHeader: hdrLen)
        return try unlockDEK(data: data, head: head, layout: layout, passphrase: passphrase)
    }

    private static func listCacheKey(vaultURL: URL, passphrase: String) -> String? {
        let normalizedVaultURL = vaultURL.standardizedFileURL
        let attrs = try? FileManager.default.attributesOfItem(atPath: normalizedVaultURL.path)
        let mod = (attrs?[.modificationDate] as? Date)?.timeIntervalSince1970 ?? 0
        let size = (attrs?[.size] as? NSNumber)?.uint64Value ?? 0
        let passHash = SHA256.hash(data: Data(passphrase.utf8)).map { String(format: "%02x", $0) }.joined()
        return "\(normalizedVaultURL.path)|\(size)|\(mod)|\(passHash)"
    }

    private static func cachedEntries(for key: String) -> [VaultIndexEntry]? {
        listCacheLock.lock()
        defer { listCacheLock.unlock() }
        guard let cached = listCache[key] else { return nil }
        if let orderIndex = listCacheOrder.firstIndex(of: key) {
            listCacheOrder.remove(at: orderIndex)
        }
        listCacheOrder.append(key)
        return cached.entries
    }

    private static func cacheEntries(_ entries: [VaultIndexEntry], for key: String) {
        listCacheLock.lock()
        defer { listCacheLock.unlock() }
        listCache[key] = ListCacheEntry(entries: entries, insertedAt: Date())
        if let orderIndex = listCacheOrder.firstIndex(of: key) {
            listCacheOrder.remove(at: orderIndex)
        }
        listCacheOrder.append(key)
        while listCacheOrder.count > listCacheLimit {
            let evicted = listCacheOrder.removeFirst()
            listCache.removeValue(forKey: evicted)
        }
    }

    public static func invalidateListCache(vaultURL: URL? = nil) {
        listCacheLock.lock()
        defer { listCacheLock.unlock() }

        guard let vaultURL else {
            listCache.removeAll()
            listCacheOrder.removeAll()
            return
        }

        let prefix = vaultURL.standardizedFileURL.path + "|"
        let keysToRemove = listCacheOrder.filter { $0.hasPrefix(prefix) }
        guard !keysToRemove.isEmpty else { return }
        let keySet = Set(keysToRemove)
        for key in keySet {
            listCache.removeValue(forKey: key)
        }
        listCacheOrder.removeAll { keySet.contains($0) }
    }

    private static func loadAllEntries(vaultURL: URL, passphrase: String) throws -> [VaultIndexEntry] {
        let components = try readVaultReadComponents(vaultURL: vaultURL,
                                                     includeIndex: true,
                                                     includeManifest: false)
        let dek = try unlockDEK(head: components.header,
                                pdkWrap: components.pdkWrap,
                                pqAccessBlob: components.pqAccessBlob,
                                pqWrap: components.pqWrap,
                                passphrase: passphrase)
        let index = try IndexCrypto.decryptIndex(components.idxBlob, key: dek, aad: vaultAAD)
        return index.entries
    }

    public static func list(vaultURL: URL, passphrase: String) throws -> [VaultIndexEntry] {
        if let key = listCacheKey(vaultURL: vaultURL, passphrase: passphrase),
           let cached = cachedEntries(for: key) {
            return cached
        }
        let entries = try loadAllEntries(vaultURL: vaultURL, passphrase: passphrase)
        if let key = listCacheKey(vaultURL: vaultURL, passphrase: passphrase) {
            cacheEntries(entries, for: key)
        }
        return entries
    }

    public static func listPage(vaultURL: URL,
                                passphrase: String,
                                offset: Int,
                                limit: Int) throws -> VaultIndexPage {
        let all = try list(vaultURL: vaultURL, passphrase: passphrase)
        let safeOffset = max(0, offset)
        let safeLimit = max(1, limit)
        let start = min(safeOffset, all.count)
        let end = min(all.count, start + safeLimit)
        return VaultIndexPage(entries: Array(all[start..<end]),
                              totalCount: all.count,
                              nextOffset: end,
                              hasMore: end < all.count)
    }

    public static func export(vaultURL: URL, passphrase: String, filters: [String], outDir: URL) throws -> [(String, URL, Int)] {
        let data = try Data(contentsOf: vaultURL)
        let (head, hdrLen) = try parseHeaderAndOffset(data)
        try ensureVaultChunkScheme(head)
        let layout = computeLayout(data, afterHeader: hdrLen)
        let dek = try deriveDEK(data: data, passphrase: passphrase)
        let aad = vaultAAD
        let idxBlob = data.subdata(in: layout.idxRange)
        let index = try IndexCrypto.decryptIndex(idxBlob, key: dek, aad: aad)
        let cmData = data.subdata(in: layout.chunkMapRange)
        let chunks = (try? JSONDecoder().decode([ChunkInfo].self, from: cmData)) ?? []
        let chunksByFileID = Dictionary(grouping: chunks, by: \.fileID)

        let selection: [VaultIndexEntry]
        if filters.isEmpty {
            selection = index.entries
        } else {
            selection = index.entries.filter { e in filters.contains { f in e.logicalPath.contains(f) } }
        }

        var results: [(String, URL, Int)] = []
        for e in selection {
            try validateVaultChunkCrypto(e.chunkCrypto)
            let fileKey = try deriveVaultFileKey(dek: dek,
                                                 fileID: e.fileID,
                                                 crypto: e.chunkCrypto,
                                                 infoPrefix: vaultFileKeyInfoPrefixV1)
            let fileChunks = (chunksByFileID[e.fileID] ?? []).sorted { $0.ordinal < $1.ordinal }
            guard fileChunks.count == e.chunkCount else {
                throw AEGError.integrity("Chunk count mismatch for \(e.logicalPath)")
            }
            var plain = Data(capacity: Int(e.size))
            for (expectedOrdinal, c) in fileChunks.enumerated() {
                guard c.ordinal == UInt32(expectedOrdinal) else {
                    throw AEGError.integrity("Chunk ordinal mismatch for \(e.logicalPath)")
                }
                let start = layout.chunkAreaStart + Int(c.relOffset)
                let end = start + c.length
                guard end <= data.count else { continue }
                let payload = data.subdata(in: start..<end)
                let nonceData = makeVaultChunkNonce(prefix: e.chunkCrypto.noncePrefix, ordinal: c.ordinal)
                let chunkAAD = makeVaultChunkAAD(vaultSalt: head.kdf_salt,
                                                 fileID: e.fileID,
                                                 ordinal: c.ordinal,
                                                 crypto: e.chunkCrypto,
                                                 aadPrefix: vaultChunkAADPrefixV1)
                let dec = try openVaultChunk(payload,
                                             key: fileKey,
                                             nonceData: nonceData,
                                             aad: chunkAAD,
                                             algorithm: e.chunkCrypto.algorithm)
                plain.append(dec)
            }
            let relativePath = sanitizedExportRelativePath(from: e.logicalPath)
            let outURL = outDir.appendingPathComponent(relativePath, isDirectory: false)
            let parentDirectory = outURL.deletingLastPathComponent()
            try FileManager.default.createDirectory(at: parentDirectory, withIntermediateDirectories: true)
            try plain.write(to: outURL)
            results.append((e.logicalPath, outURL, plain.count))
        }
        return results
    }
}
public struct VaultStatusInfo: Codable {
    public var locked: Bool
    public var entries: Int?
    public var sidecarPending: Int
    public var manifestOK: Bool
    public var touchIDEnabled: Bool
    public var vaultSizeBytes: UInt64
    public var vaultLastModified: Date?
}

public enum VaultStatus {
    public static func get(vaultURL: URL, passphrase: String?) throws -> VaultStatusInfo {
        let attrs = (try? FileManager.default.attributesOfItem(atPath: vaultURL.path)) ?? [:]
        let vaultSizeBytes = (attrs[.size] as? NSNumber)?.uint64Value ?? 0
        let vaultLastModified = attrs[.modificationDate] as? Date
        let needIndex = !(passphrase?.isEmpty ?? true)
        let components = try readVaultReadComponents(vaultURL: vaultURL,
                                                     includeIndex: needIndex,
                                                     includeManifest: true)
        let head = components.header

        // Sidecar count
        let sidecar = vaultURL.deletingPathExtension().appendingPathExtension("aegirofiles")
        var pending = 0
        if let metaData = try? Data(contentsOf: sidecar.appendingPathComponent("index.json")),
           let arr = try? JSONSerialization.jsonObject(with: metaData) as? [[String: Any]] {
            pending = arr.count
        }

        // Manifest verify
        let manifest = try JSONDecoder().decode(Manifest.self, from: components.manBlob)
        let sig = Dilithium2()
        let ok = ManifestBuilder.verify(manifest, signer: sig)

        // Entries if we can decrypt
        var entriesCount: Int? = nil
        var locked = true
        if let pass = passphrase, !pass.isEmpty {
            if let dek = try? unlockDEK(head: head,
                                        pdkWrap: components.pdkWrap,
                                        pqAccessBlob: components.pqAccessBlob,
                                        pqWrap: components.pqWrap,
                                        passphrase: pass) {
                if let index = try? IndexCrypto.decryptIndex(components.idxBlob, key: dek, aad: vaultAAD) {
                    entriesCount = index.entries.count
                    locked = false
                }
            }
        }
        let touchIDEnabled = (head.flags & vaultFlagTouchID) != 0
        return VaultStatusInfo(
            locked: locked,
            entries: entriesCount,
            sidecarPending: pending,
            manifestOK: ok,
            touchIDEnabled: touchIDEnabled,
            vaultSizeBytes: vaultSizeBytes,
            vaultLastModified: vaultLastModified
        )
    }
}

public enum VaultSettings {
    public static func setTouchIDEnabled(vaultURL: URL, enabled: Bool) throws {
        let data = try Data(contentsOf: vaultURL)
        let (head, headerEnd) = try parseHeaderAndOffset(data)

        var updated = head
        if enabled {
            updated.flags |= vaultFlagTouchID
        } else {
            updated.flags &= ~vaultFlagTouchID
        }

        let newHeader = try updated.serialize()
        guard newHeader.count == headerEnd else {
            throw NSError(
                domain: "VaultSettings",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Vault header size changed; Touch ID flag update is not safe for this vault."]
            )
        }

        var out = data
        out.replaceSubrange(0..<headerEnd, with: newHeader)
        try out.write(to: vaultURL, options: .atomic)
        Exporter.invalidateListCache(vaultURL: vaultURL)
    }

    public static func normalizeUnlockFlags(vaultURL: URL, passphrase: String) throws -> Bool {
        let data = try Data(contentsOf: vaultURL)
        let (head, headerEnd) = try parseHeaderAndOffset(data)
        let layout = computeLayout(data, afterHeader: headerEnd)

        let inferredMode = try inferUnlockMode(data: data, head: head, layout: layout, passphrase: passphrase)
        let expectedPQCFlag = (inferredMode == .pqcV1)
        let hasPQCFlag = (head.flags & vaultFlagPQCUnlockV1) != 0

        guard expectedPQCFlag != hasPQCFlag else { return false }

        var updated = head
        if expectedPQCFlag {
            updated.flags |= vaultFlagPQCUnlockV1
        } else {
            updated.flags &= ~vaultFlagPQCUnlockV1
        }

        let newHeader = try updated.serialize()
        guard newHeader.count == headerEnd else {
            throw NSError(
                domain: "VaultSettings",
                code: -2,
                userInfo: [NSLocalizedDescriptionKey: "Vault header size changed; unlock flag update is not safe for this vault."]
            )
        }

        var out = data
        out.replaceSubrange(0..<headerEnd, with: newHeader)
        try out.write(to: vaultURL, options: .atomic)
        Exporter.invalidateListCache(vaultURL: vaultURL)
        return true
    }
}

public struct DoctorReport: Codable {
    public var headerOK: Bool
    public var manifestOK: Bool
    public var chunkAreaOK: Bool
    public var entries: Int?
    public var issues: [String]
    public var fixed: Bool
}

public enum Doctor {
    public static func run(vaultURL: URL,
                           passphrase: String?,
                           fix: Bool,
                           deepCheck: Bool = true,
                           progress: ((String) -> Void)? = nil) throws -> DoctorReport {
        progress?("Loading vault data...")
        let data = try Data(contentsOf: vaultURL)
        var issues: [String] = []
        var fixed = false
        let (head, hdrLen): (VaultHeader, Int)
        do {
            (head, hdrLen) = try parseHeaderAndOffset(data)
        } catch {
            return DoctorReport(headerOK: false, manifestOK: false, chunkAreaOK: false, entries: nil, issues: ["Header parse failed: \(error)"], fixed: false)
        }
        progress?("Parsing manifest and chunk map...")
        let layout = computeLayout(data, afterHeader: hdrLen)
        let aad = vaultAAD

        // Manifest parse and signature/hash checks
        let manBlob = data.subdata(in: layout.manRange)
        var manifest: Manifest
        do {
            manifest = try JSONDecoder().decode(Manifest.self, from: manBlob)
        } catch {
            return DoctorReport(
                headerOK: true,
                manifestOK: false,
                chunkAreaOK: false,
                entries: nil,
                issues: ["Manifest decode failed: \(error)"],
                fixed: false
            )
        }
        let sig = Dilithium2()
        let cmData = data.subdata(in: layout.chunkMapRange)
        let chunkMapHash = Data(SHA256.hash(data: cmData))
        var manifestSignatureOK = ManifestBuilder.verify(manifest, signer: sig)
        var manifestSignerMatchesHeader = (manifest.signerPK == head.pq_pubkeys.dilithium_pk)
        var manifestChunkMapHashMatches = (manifest.chunkMapHash == chunkMapHash)
        var manifestIndexHashMatches: Bool? = nil

        var decryptedIndex: VaultIndex?
        var decryptedIndexHash: Data?
        var dekForDeepChecks: SymmetricKey?
        if let pass = passphrase, !pass.isEmpty {
            progress?("Decrypting index...")
            let dek = try Exporter.deriveDEK(data: data, passphrase: pass)
            let idxBlob = data.subdata(in: layout.idxRange)
            let idxPlain = try decryptIndexBlob(idxBlob, key: dek, aad: aad)
            let idxHash = Data(SHA256.hash(data: idxPlain))
            if deepCheck {
                decryptedIndex = try JSONDecoder().decode(VaultIndex.self, from: idxPlain)
            }
            decryptedIndexHash = idxHash
            dekForDeepChecks = dek
            manifestIndexHashMatches = (idxHash == manifest.indexRootHash)
        }

        if fix,
           let idxHash = decryptedIndexHash,
           let dek = dekForDeepChecks,
           (!manifestSignatureOK
            || !manifestSignerMatchesHeader
            || !manifestChunkMapHashMatches
            || manifestIndexHashMatches == false) {
            progress?("Applying manifest fix...")
            // Preserve the exact decrypted index hash bytes from disk to avoid
            // process-dependent JSON key ordering when rebuilding a manifest.
            let msg = idxHash + chunkMapHash
            let sigBytes = try sig.sign(message: msg, sk: try unwrapSignerSK(data: data, dek: dek))
            let newManifest = Manifest(indexRootHash: idxHash,
                                       chunkMapHash: chunkMapHash,
                                       signature: sigBytes,
                                       signerPK: head.pq_pubkeys.dilithium_pk)
            let newManBlob = try JSONEncoder().encode(newManifest)
            var d = data
            let newLenLE = withUnsafeBytes(of: UInt32(newManBlob.count).littleEndian) { Data($0) }
            d.replaceSubrange(layout.manLenPos..<(layout.manLenPos + 4), with: newLenLE)
            d.replaceSubrange(layout.manRange, with: newManBlob)
            try d.write(to: vaultURL, options: .atomic)
            Exporter.invalidateListCache(vaultURL: vaultURL)

            manifest = newManifest
            manifestSignatureOK = ManifestBuilder.verify(manifest, signer: sig)
            manifestSignerMatchesHeader = (manifest.signerPK == head.pq_pubkeys.dilithium_pk)
            manifestChunkMapHashMatches = (manifest.chunkMapHash == chunkMapHash)
            manifestIndexHashMatches = (idxHash == manifest.indexRootHash)
            fixed = true
        }

        var manifestOK = manifestSignatureOK && manifestSignerMatchesHeader && manifestChunkMapHashMatches
        if let manifestIndexHashMatches {
            manifestOK = manifestOK && manifestIndexHashMatches
        }
        if !manifestSignatureOK {
            issues.append("Manifest signature invalid.")
        }
        if !manifestSignerMatchesHeader {
            issues.append("Manifest signer key does not match header key.")
        }
        if !manifestChunkMapHashMatches {
            issues.append("Manifest chunk map hash does not match chunk map bytes.")
        }
        if manifestIndexHashMatches == false {
            issues.append("Manifest index hash does not match decrypted index.")
        }

        // Chunk map parse and area consistency checks.
        let chunks: [ChunkInfo]
        do {
            chunks = try JSONDecoder().decode([ChunkInfo].self, from: cmData)
        } catch {
            chunks = []
            issues.append("Chunk map decode failed: \(error)")
        }

        let areaBytes = data.count - layout.chunkAreaStart
        var chunkAreaOK = true
        var cursor = 0
        for c in chunks.sorted(by: { $0.relOffset < $1.relOffset }) {
            guard let relRange = chunkRelativeRange(c, areaBytes: areaBytes) else {
                chunkAreaOK = false
                issues.append("Chunk range invalid for file \(c.fileID.base64EncodedString()) at offset \(c.relOffset) length \(c.length).")
                continue
            }
            if relRange.lowerBound != cursor {
                chunkAreaOK = false
                issues.append("Chunk map gap/overlap near file \(c.fileID.base64EncodedString()) at offset \(c.relOffset).")
            }
            cursor = max(cursor, relRange.upperBound)
        }
        if cursor != areaBytes {
            chunkAreaOK = false
            issues.append("Chunk area length \(areaBytes) does not match chunk map coverage \(cursor).")
        }

        // Entry and chunk authentication checks when passphrase is available.
        var entryCount: Int? = nil
        if deepCheck, let index = decryptedIndex, let dek = dekForDeepChecks {
            entryCount = index.entries.count

            var plainBytesByName: [String: UInt64] = [:]
            let entryByFileID = Dictionary(uniqueKeysWithValues: index.entries.map { ($0.fileID, $0) })
            var fileKeyByID: [Data: SymmetricKey] = [:]
            fileKeyByID.reserveCapacity(index.entries.count)
            for entry in index.entries {
                try validateVaultChunkCrypto(entry.chunkCrypto)
                let fileKey = try deriveVaultFileKey(dek: dek,
                                                     fileID: entry.fileID,
                                                     crypto: entry.chunkCrypto,
                                                     infoPrefix: vaultFileKeyInfoPrefixV1)
                fileKeyByID[entry.fileID] = fileKey
            }
            if chunks.isEmpty {
                progress?("No chunks to authenticate.")
            } else {
                progress?("Authenticating \(chunks.count) chunk(s)...")
                let progressStride = max(1, chunks.count / 40)
                if chunks.count >= 96 {
                    var chunkPlainBytes = Array(repeating: UInt64(0), count: chunks.count)
                    var chunkOwners = Array<String?>(repeating: nil, count: chunks.count)
                    var chunkIssues = Array<String?>(repeating: nil, count: chunks.count)
                    let progressLock = NSLock()
                    var processed = 0

                    DispatchQueue.concurrentPerform(iterations: chunks.count) { index in
                        let c = chunks[index]
                        guard let entry = entryByFileID[c.fileID],
                              let fileKey = fileKeyByID[c.fileID] else {
                            chunkIssues[index] = "Chunk map contains unknown file identifier."
                            return
                        }
                        if let relRange = chunkRelativeRange(c, areaBytes: areaBytes) {
                            let start = layout.chunkAreaStart + relRange.lowerBound
                            let end = layout.chunkAreaStart + relRange.upperBound
                            let payload = data.subdata(in: start..<end)
                            do {
                                let nonceData = makeVaultChunkNonce(prefix: entry.chunkCrypto.noncePrefix, ordinal: c.ordinal)
                                let chunkAAD = makeVaultChunkAAD(vaultSalt: head.kdf_salt,
                                                                 fileID: c.fileID,
                                                                 ordinal: c.ordinal,
                                                                 crypto: entry.chunkCrypto,
                                                                 aadPrefix: vaultChunkAADPrefixV1)
                                let plain = try openVaultChunk(payload,
                                                               key: fileKey,
                                                               nonceData: nonceData,
                                                               aad: chunkAAD,
                                                               algorithm: entry.chunkCrypto.algorithm)
                                chunkPlainBytes[index] = UInt64(plain.count)
                                chunkOwners[index] = entry.logicalPath
                            } catch {
                                chunkIssues[index] = "Chunk authentication failed for \(entry.logicalPath) at offset \(c.relOffset)."
                            }
                        }

                        guard progress != nil else { return }
                        var emitCount: Int?
                        progressLock.lock()
                        processed += 1
                        if processed == 1 || processed == chunks.count || processed % progressStride == 0 {
                            emitCount = processed
                        }
                        progressLock.unlock()
                        if let emitCount {
                            progress?("Authenticating chunks: \(emitCount)/\(chunks.count)")
                        }
                    }

                    for index in chunks.indices {
                        if let owner = chunkOwners[index] {
                            plainBytesByName[owner, default: 0] += chunkPlainBytes[index]
                        }
                        if let issue = chunkIssues[index] {
                            chunkAreaOK = false
                            issues.append(issue)
                        }
                    }
                } else {
                    var authenticated = 0
                    for c in chunks {
                        guard let entry = entryByFileID[c.fileID],
                              let fileKey = fileKeyByID[c.fileID] else {
                            chunkAreaOK = false
                            issues.append("Chunk map contains unknown file identifier.")
                            continue
                        }
                        guard let relRange = chunkRelativeRange(c, areaBytes: areaBytes) else { continue }
                        let start = layout.chunkAreaStart + relRange.lowerBound
                        let end = layout.chunkAreaStart + relRange.upperBound
                        let payload = data.subdata(in: start..<end)
                        do {
                            let nonceData = makeVaultChunkNonce(prefix: entry.chunkCrypto.noncePrefix, ordinal: c.ordinal)
                            let chunkAAD = makeVaultChunkAAD(vaultSalt: head.kdf_salt,
                                                             fileID: c.fileID,
                                                             ordinal: c.ordinal,
                                                             crypto: entry.chunkCrypto,
                                                             aadPrefix: vaultChunkAADPrefixV1)
                            let plain = try openVaultChunk(payload,
                                                           key: fileKey,
                                                           nonceData: nonceData,
                                                           aad: chunkAAD,
                                                           algorithm: entry.chunkCrypto.algorithm)
                            plainBytesByName[entry.logicalPath, default: 0] += UInt64(plain.count)
                        } catch {
                            chunkAreaOK = false
                            issues.append("Chunk authentication failed for \(entry.logicalPath) at offset \(c.relOffset).")
                        }
                        authenticated += 1
                        if authenticated == 1 || authenticated == chunks.count || authenticated % progressStride == 0 {
                            progress?("Authenticating chunks: \(authenticated)/\(chunks.count)")
                        }
                    }
                }
            }

            let chunkCounts = chunks.reduce(into: [Data: Int]()) { partial, chunk in
                partial[chunk.fileID, default: 0] += 1
            }

            for e in index.entries {
                let actualCount = chunkCounts[e.fileID, default: 0]
                if actualCount == 0, e.size > 0 {
                    issues.append("No chunks for \(e.logicalPath).")
                }
                if e.chunkCount != actualCount {
                    issues.append("Chunk count mismatch for \(e.logicalPath): index \(e.chunkCount), map \(actualCount).")
                }
                let plainBytes = plainBytesByName[e.logicalPath, default: 0]
                if plainBytes != e.size {
                    chunkAreaOK = false
                    issues.append("Plaintext size mismatch for \(e.logicalPath): index \(e.size), decrypted \(plainBytes).")
                }
            }

            let entryIDs = Set(index.entries.map(\.fileID))
            for fileID in Set(chunks.map(\.fileID)) where !entryIDs.contains(fileID) {
                chunkAreaOK = false
                issues.append("Chunk map contains unknown file identifier: \(fileID.base64EncodedString()).")
            }
            progress?("Chunk checks completed.")
        } else if !deepCheck {
            progress?("Deep chunk authentication skipped (fast mode).")
        } else {
            progress?("Passphrase not provided. Skipping deep chunk authentication and index-hash checks.")
        }

        progress?("Doctor completed.")
        return DoctorReport(headerOK: true, manifestOK: manifestOK, chunkAreaOK: chunkAreaOK, entries: entryCount, issues: issues, fixed: fixed)
    }

    private static func decryptIndexBlob(_ blob: Data, key: SymmetricKey, aad: Data) throws -> Data {
        let box = try AES.GCM.SealedBox(combined: blob)
        return try AES.GCM.open(box, using: key, authenticating: aad)
    }

    private static func chunkRelativeRange(_ chunk: ChunkInfo, areaBytes: Int) -> Range<Int>? {
        guard chunk.relOffset <= UInt64(Int.max), chunk.length >= 0 else { return nil }
        let start = Int(chunk.relOffset)
        let end = start + chunk.length
        guard start >= 0, end >= start, end <= areaBytes else { return nil }
        return start..<end
    }

    static func unwrapSignerSK(data: Data, dek: SymmetricKey) throws -> Data {
        // Locate signer wrap via layout and decrypt
        let (_, hdrLen) = try parseHeaderAndOffset(data)
        let layout = computeLayout(data, afterHeader: hdrLen)
        let wrap = data.subdata(in: layout.signerWrapRange)
        let aad = vaultAAD
        return try AEAD.decrypt(key: dek, nonce: try AES.GCM.Nonce(data: wrap.prefix(12)), combined: wrap, aad: aad)
    }
}

public enum Editor {
    public static func updateTags(vaultURL: URL, passphrase: String, updates: [String: [String]]) throws {
        let data = try Data(contentsOf: vaultURL)
        let (head, hdrLen) = try parseHeaderAndOffset(data)
        let layout = computeLayout(data, afterHeader: hdrLen)

        let dek = try unlockDEK(data: data, head: head, layout: layout, passphrase: passphrase)
        let aad = vaultAAD

        // Decrypt index, apply updates
        let idxBlob = data.subdata(in: layout.idxRange)
        var index = try IndexCrypto.decryptIndex(idxBlob, key: dek, aad: aad)
        var changed = false
        for i in 0..<index.entries.count {
            let logical = index.entries[i].logicalPath
            if let tags = updates[logical] {
                index.entries[i].tags = tags
                changed = true
            }
        }
        guard changed else { return }

        // Re-encrypt index
        let newIdxBlob = try IndexCrypto.encryptIndex(index, key: dek, aad: aad)
        var d = data
        let newLenLE = withUnsafeBytes(of: UInt32(newIdxBlob.count).littleEndian) { Data($0) }
        d.replaceSubrange(layout.idxLenPos..<(layout.idxLenPos+4), with: newLenLE)
        d.replaceSubrange(layout.idxRange, with: newIdxBlob)

        // Re-sign manifest
        let signerSk = try AEAD.decrypt(key: dek, nonce: try AES.GCM.Nonce(data: d.subdata(in: layout.signerWrapRange).prefix(12)), combined: d.subdata(in: layout.signerWrapRange), aad: aad)
        let sig = Dilithium2()
        let chunkMap = d.subdata(in: layout.chunkMapRange)
        let manifest = try ManifestBuilder.build(index: index, chunkMap: chunkMap, signer: sig, sk: signerSk, pk: head.pq_pubkeys.dilithium_pk)
        let manBlob = try JSONEncoder().encode(manifest)
        let manLenLE = withUnsafeBytes(of: UInt32(manBlob.count).littleEndian) { Data($0) }
        d.replaceSubrange(layout.manLenPos..<(layout.manLenPos+4), with: manLenLE)
        d.replaceSubrange(layout.manRange, with: manBlob)

        try d.write(to: vaultURL, options: .atomic)
        Exporter.invalidateListCache(vaultURL: vaultURL)
    }

    public static func deleteEntries(vaultURL: URL, passphrase: String, logicalPaths: [String]) throws -> Int {
        let targets = Set(
            logicalPaths
                .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
                .filter { !$0.isEmpty }
        )
        guard !targets.isEmpty else { return 0 }

        let data = try Data(contentsOf: vaultURL)
        let (head, hdrLen) = try parseHeaderAndOffset(data)
        let layout = computeLayout(data, afterHeader: hdrLen)

        let dek = try unlockDEK(data: data, head: head, layout: layout, passphrase: passphrase)
        let aad = vaultAAD

        let idxBlobOld = data.subdata(in: layout.idxRange)
        var index = try IndexCrypto.decryptIndex(idxBlobOld, key: dek, aad: aad)
        let targetFileIDs = Set(index.entries.filter { targets.contains($0.logicalPath) }.map(\.fileID))
        let oldCount = index.entries.count
        index.entries.removeAll { targets.contains($0.logicalPath) }
        let removed = oldCount - index.entries.count
        guard removed > 0 else { return 0 }

        let existingCM = data.subdata(in: layout.chunkMapRange)
        let existingChunks = ((try? JSONDecoder().decode([ChunkInfo].self, from: existingCM)) ?? []).sorted { $0.relOffset < $1.relOffset }
        let existingArea = data.subdata(in: layout.chunkAreaStart..<data.count)

        var chunkArea = Data()
        var chunkInfos: [ChunkInfo] = []
        chunkArea.reserveCapacity(existingArea.count)

        for c in existingChunks where !targetFileIDs.contains(c.fileID) {
            let start = Int(c.relOffset)
            let end = start + c.length
            guard start >= 0, end <= existingArea.count else { continue }
            let blob = existingArea.subdata(in: start..<end)
            let offset = UInt64(chunkArea.count)
            chunkArea.append(blob)
            chunkInfos.append(ChunkInfo(fileID: c.fileID,
                                        ordinal: c.ordinal,
                                        relOffset: offset,
                                        length: blob.count))
        }

        let chunkCounts = chunkInfos.reduce(into: [Data: Int]()) { counts, chunk in
            counts[chunk.fileID, default: 0] += 1
        }
        for i in index.entries.indices {
            let fileID = index.entries[i].fileID
            index.entries[i].chunkCount = chunkCounts[fileID] ?? 0
            index.entries[i].sidecarName = nil
        }

        let newIdxBlob = try IndexCrypto.encryptIndex(index, key: dek, aad: aad)
        let chunkMap = try JSONEncoder().encode(chunkInfos)

        let signerWrap = data.subdata(in: layout.signerWrapRange)
        let signerSk = try AEAD.decrypt(key: dek, nonce: try AES.GCM.Nonce(data: signerWrap.prefix(12)), combined: signerWrap, aad: aad)
        let sig = Dilithium2()
        let manifest = try ManifestBuilder.build(index: index, chunkMap: chunkMap, signer: sig, sk: signerSk, pk: head.pq_pubkeys.dilithium_pk)
        let manBlob = try JSONEncoder().encode(manifest)

        let pqCt = data.subdata(in: layout.pqCtRange)
        let pqWrap = data.subdata(in: layout.pqWrapRange)
        let signerLen = data.subdata(in: layout.signerWrapLenPos..<(layout.signerWrapLenPos+4))
        let signerBlob = data.subdata(in: layout.signerWrapRange)
        let pdkBlob = data.subdata(in: layout.pdkWrapRange)

        let idxLenLE = withUnsafeBytes(of: UInt32(newIdxBlob.count).littleEndian) { Data($0) }
        let manLenLE = withUnsafeBytes(of: UInt32(manBlob.count).littleEndian) { Data($0) }
        let cmLenLE = withUnsafeBytes(of: UInt32(chunkMap.count).littleEndian) { Data($0) }

        var out = Data()
        let finalHeader = try head.serialize()
        out.append(finalHeader)
        out.append(pdkBlob)
        out.append(withUnsafeBytes(of: UInt32(pqCt.count).littleEndian) { Data($0) })
        out.append(pqCt)
        out.append(pqWrap)
        out.append(signerLen)
        out.append(signerBlob)
        out.append(idxLenLE)
        out.append(newIdxBlob)
        out.append(manLenLE)
        out.append(manBlob)
        out.append(cmLenLE)
        out.append(chunkMap)
        out.append(chunkArea)

        try out.write(to: vaultURL, options: .atomic)
        Exporter.invalidateListCache(vaultURL: vaultURL)
        return removed
    }
}
