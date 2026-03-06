
import Foundation
import CryptoKit

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
        #if REAL_CRYPTO
        let kem = Kyber512()
        let sig = Dilithium2()
        #else
        let kem = StubKEM()
        let sig = StubSig()
        #endif
        let (kemPk, kemSk) = try kem.keypair()
        let (sigPk, sigSk) = try sig.keypair()

        let algs = AlgIDs(aead: 1, kdf: 2, kem: 3, sig: 4)
        let argon = Argon2Params(mMiB: 256, t: 3, p: 1)
        let pq = PQPublicKeys(kyber_pk: kemPk, dilithium_pk: sigPk)
        var header = VaultHeader(alg: algs, argon2: argon, pq: pq)
        if touchID { header.flags |= vaultFlagTouchID }
        header.flags |= vaultFlagPQCUnlockV1

        #if REAL_CRYPTO
        let kdf = Argon2idKDF()
        #else
        let kdf = StubKDF()
        #endif
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
        var tempHeader = header
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
        let data = try Data(contentsOf: url)
        let (head, hdrLen) = try parseHeaderAndOffset(data)
        var cursor = hdrLen
        cursor += 60 // pdk
        let ctLen = data.subdata(in: cursor..<(cursor+4)).withUnsafeBytes { $0.load(as: UInt32.self) }.littleEndian
        cursor += 4
        cursor += Int(ctLen)
        cursor += 60 // pqWrap
        let signerWrapLen = data.subdata(in: cursor..<(cursor+4)).withUnsafeBytes { $0.load(as: UInt32.self) }.littleEndian
        cursor += 4
        cursor += Int(signerWrapLen)
        let idxLen = data.subdata(in: cursor..<(cursor+4)).withUnsafeBytes { $0.load(as: UInt32.self) }.littleEndian
        cursor += 4
        let idxBlob = data.subdata(in: cursor..<(cursor + Int(idxLen)))
        cursor += Int(idxLen)
        let manLen = data.subdata(in: cursor..<(cursor+4)).withUnsafeBytes { $0.load(as: UInt32.self) }.littleEndian
        cursor += 4
        let manBlob = data.subdata(in: cursor..<(cursor + Int(manLen)))

        // Note: index is encrypted; we return stub index until unlocked with passphrase
        let manifest = try JSONDecoder().decode(Manifest.self, from: manBlob)
        let v = AegiroVault(url: url, header: head, index: VaultIndex(entries: [], thumbnails: [:]), manifest: manifest)
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

private func normalizedPath(_ url: URL) -> String {
    return url.standardizedFileURL.resolvingSymlinksInPath().path
}

public enum Importer {
    public static func sidecarImport(vaultURL: URL, passphrase: String, files: [URL]) throws -> (imported: Int, sidecar: URL) {
        let sidecar = vaultURL.deletingPathExtension().appendingPathExtension("aegirofiles")
        let data = try Data(contentsOf: vaultURL)
        let (head, hdrLen) = try parseHeaderAndOffset(data)
        let layout = computeLayout(data, afterHeader: hdrLen)
        let dek = try Exporter.deriveDEK(data: data, passphrase: passphrase)
        let aad = vaultAAD
        let items = try directImportItems(files: files, vaultURL: vaultURL, sidecarURL: sidecar, head: head)
        let imported = try mergeImportedPlainItems(vaultURL: vaultURL, data: data, head: head, layout: layout, dek: dek, aad: aad, items: items)
        try? FileManager.default.removeItem(at: sidecar)
        return (imported, sidecar)
    }

    private static func directImportItems(files: [URL], vaultURL: URL, sidecarURL: URL, head: VaultHeader) throws -> [PlainImportItem] {
        let vaultPath = normalizedPath(vaultURL)
        let sidecarPath = normalizedPath(sidecarURL)
        let sidecarPrefix = sidecarPath.hasSuffix("/") ? sidecarPath : sidecarPath + "/"
        var bySource: [String: PlainImportItem] = [:]
        var order = 0
        for f in files {
            let sourcePath = normalizedPath(f)
            if sourcePath == vaultPath || sourcePath == sidecarPath || sourcePath.hasPrefix(sidecarPrefix) {
                continue
            }
            let plain = try Data(contentsOf: f)
            let name = (sourcePath as NSString).lastPathComponent
            let h = HMACUtil.hmacNameHash(name, salt: head.index_salt)
            bySource[sourcePath] = PlainImportItem(path: sourcePath, plain: plain, nameHash: h, order: order)
            order += 1
        }
        return bySource.values.sorted { $0.order < $1.order }
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

private struct PlainImportItem {
    let path: String
    let plain: Data
    let nameHash: Data
    let order: Int
}

private func mergeImportedPlainItems(vaultURL: URL,
                                     data: Data,
                                     head: VaultHeader,
                                     layout: VaultLayout,
                                     dek: SymmetricKey,
                                     aad: Data,
                                     items: [PlainImportItem]) throws -> Int {
    guard !items.isEmpty else { return 0 }

    let idxBlobOld = data.subdata(in: layout.idxRange)
    var index = try IndexCrypto.decryptIndex(idxBlobOld, key: dek, aad: aad)

    // Preserve existing encrypted chunks except for paths being replaced.
    let replacingPaths = Set(items.map { $0.path })
    let existingCM = data.subdata(in: layout.chunkMapRange)
    let existingChunks = ((try? JSONDecoder().decode([ChunkInfo].self, from: existingCM)) ?? []).sorted { $0.relOffset < $1.relOffset }
    let existingArea = data.subdata(in: layout.chunkAreaStart..<data.count)

    let chunkSize = 1024 * 1024
    var chunkArea = Data()
    var chunkInfos: [ChunkInfo] = []
    chunkArea.reserveCapacity(existingArea.count)

    for c in existingChunks where !replacingPaths.contains(c.name) {
        let start = Int(c.relOffset)
        let end = start + c.length
        guard start >= 0, end <= existingArea.count else { continue }
        let blob = existingArea.subdata(in: start..<end)
        let offset = UInt64(chunkArea.count)
        chunkArea.append(blob)
        chunkInfos.append(ChunkInfo(name: c.name, relOffset: offset, length: blob.count))
    }

    // Replace matching entries while keeping metadata for untouched files.
    let priorByPath = Dictionary(uniqueKeysWithValues: index.entries.map { ($0.logicalPath, $0) })
    index.entries.removeAll { replacingPaths.contains($0.logicalPath) }

    // Encrypt new plaintext data and append chunk descriptors.
    for item in items.sorted(by: { $0.order < $1.order }) {
        let plain = item.plain
        let seedKey = SymmetricKey(data: HMAC<SHA256>.authenticationCode(for: item.nameHash, using: dek))
        var fileChunkIndex: UInt64 = 0
        var remaining = plain.count
        var cursorPlain = 0
        var perFileCount = 0
        while remaining > 0 {
            let n = min(remaining, chunkSize)
            let chunk = plain.subdata(in: cursorPlain..<(cursorPlain + n))
            let nonce = NonceScheme.nonce(fileSeed: seedKey, chunkIndex: fileChunkIndex)
            let combined = try AEAD.encrypt(key: dek, nonce: nonce, plaintext: chunk, aad: aad)
            let offset = UInt64(chunkArea.count)
            chunkArea.append(combined)
            chunkInfos.append(ChunkInfo(name: item.path, relOffset: offset, length: combined.count))
            fileChunkIndex += 1
            perFileCount += 1
            remaining -= n
            cursorPlain += n
        }

        let previous = priorByPath[item.path]
        let now = Date()
        let entry = VaultIndexEntry(nameHash: item.nameHash,
                                    logicalPath: item.path,
                                    size: UInt64(plain.count),
                                    mime: previous?.mime ?? "application/octet-stream",
                                    tags: previous?.tags ?? [],
                                    chunkCount: perFileCount,
                                    created: previous?.created ?? now,
                                    modified: now,
                                    sidecarName: nil)
        index.entries.append(entry)
    }

    let chunkCounts = chunkInfos.reduce(into: [String: Int]()) { counts, chunk in
        counts[chunk.name, default: 0] += 1
    }
    for i in index.entries.indices {
        let logical = index.entries[i].logicalPath
        index.entries[i].chunkCount = chunkCounts[logical] ?? 0
        index.entries[i].sidecarName = nil
    }

    // Build new index/blob and chunk map.
    let newIdxBlob = try IndexCrypto.encryptIndex(index, key: dek, aad: aad)
    let chunkMap = try JSONEncoder().encode(chunkInfos)

    // Re-sign manifest using signer SK (wrapped under DEK).
    let signerWrap = data.subdata(in: layout.signerWrapRange)
    let signerSk = try AEAD.decrypt(key: dek, nonce: try AES.GCM.Nonce(data: signerWrap.prefix(12)), combined: signerWrap, aad: aad)
    #if REAL_CRYPTO
    let sig = Dilithium2()
    #else
    let sig = StubSig()
    #endif
    let manifest = try ManifestBuilder.build(index: index, chunkMap: chunkMap, signer: sig, sk: signerSk, pk: head.pq_pubkeys.dilithium_pk)
    let manBlob = try JSONEncoder().encode(manifest)

    // Reconstruct vault file in-memory (header + wraps + idx + manifest + chunk map + chunk area).
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

    try out.write(to: vaultURL, options: .atomic)
    return items.count
}

private func derivePassphraseKey(passphrase: String, salt: Data) throws -> SymmetricKey {
    #if REAL_CRYPTO
    let kdf = Argon2idKDF()
    #else
    let kdf = StubKDF()
    #endif
    let raw = try kdf.deriveKey(passphrase: passphrase, salt: salt, outLen: 32)
    return SymmetricKey(data: raw)
}

private func unlockDEK(data: Data, head: VaultHeader, layout: VaultLayout, passphrase: String) throws -> SymmetricKey {
    let pdk = try derivePassphraseKey(passphrase: passphrase, salt: head.kdf_salt)
    let pdkWrap = data.subdata(in: layout.pdkWrapRange)
    let pdkPlain = try AEAD.decrypt(key: pdk, nonce: try AES.GCM.Nonce(data: pdkWrap.prefix(12)), combined: pdkWrap, aad: vaultAAD)

    // Legacy vaults: DEK was wrapped directly under passphrase-derived key.
    if (head.flags & vaultFlagPQCUnlockV1) == 0 {
        return SymmetricKey(data: pdkPlain)
    }

    guard pdkPlain.count == 32 else {
        throw AEGError.integrity("Invalid PQC access key length: \(pdkPlain.count)")
    }
    let accessKey = SymmetricKey(data: pdkPlain)

    let accessBlob = data.subdata(in: layout.pqCtRange)
    let accessBundle: PQAccessBundleV1
    do {
        accessBundle = try JSONDecoder().decode(PQAccessBundleV1.self, from: accessBlob)
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
    #if REAL_CRYPTO
    let kem = Kyber512()
    #else
    let kem = StubKEM()
    #endif
    let ss = try kem.decap(accessBundle.kemCiphertext, sk: kemSk)
    let pqKey = SymmetricKey(data: ss)
    let pqWrap = data.subdata(in: layout.pqWrapRange)
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
                #if REAL_CRYPTO
                let kem = Kyber512()
                #else
                let kem = StubKEM()
                #endif
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
        let data = try Data(contentsOf: vaultURL)
        let (head, hdrLen) = try parseHeaderAndOffset(data)
        let layout = computeLayout(data, afterHeader: hdrLen)
        let dek = try unlockDEK(data: data, head: head, layout: layout, passphrase: passphrase)
        let aad = vaultAAD
        let idxBlob = data.subdata(in: layout.idxRange)
        let index = try IndexCrypto.decryptIndex(idxBlob, key: dek, aad: aad)
        return index.entries.count
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
        var stagedByPath: [String: PlainImportItem] = [:]
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
            stagedByPath[normalizedSource] = PlainImportItem(path: normalizedSource, plain: plain, nameHash: h, order: order)
        }
        let staged = stagedByPath.values.sorted { $0.order < $1.order }
        guard !staged.isEmpty else {
            try? FileManager.default.removeItem(at: sidecar)
            return 0
        }
        let added = try mergeImportedPlainItems(vaultURL: vaultURL, data: data, head: head, layout: layout, dek: dek, aad: aad, items: staged)

        // cleanup sidecar
        try? FileManager.default.removeItem(at: sidecar)
        return added
    }
}

public enum Exporter {
    static func deriveDEK(data: Data, passphrase: String) throws -> SymmetricKey {
        let (head, hdrLen) = try parseHeaderAndOffset(data)
        let layout = computeLayout(data, afterHeader: hdrLen)
        return try unlockDEK(data: data, head: head, layout: layout, passphrase: passphrase)
    }

    public static func list(vaultURL: URL, passphrase: String) throws -> [VaultIndexEntry] {
        let data = try Data(contentsOf: vaultURL)
        let (_, hdrLen) = try parseHeaderAndOffset(data)
        let layout = computeLayout(data, afterHeader: hdrLen)
        let dek = try deriveDEK(data: data, passphrase: passphrase)
        let aad = vaultAAD
        let idxBlob = data.subdata(in: layout.idxRange)
        let index = try IndexCrypto.decryptIndex(idxBlob, key: dek, aad: aad)
        return index.entries
    }

    public static func export(vaultURL: URL, passphrase: String, filters: [String], outDir: URL) throws -> [(String, URL, Int)] {
        let data = try Data(contentsOf: vaultURL)
        let (_, hdrLen) = try parseHeaderAndOffset(data)
        let layout = computeLayout(data, afterHeader: hdrLen)
        let dek = try deriveDEK(data: data, passphrase: passphrase)
        let aad = vaultAAD
        let idxBlob = data.subdata(in: layout.idxRange)
        let index = try IndexCrypto.decryptIndex(idxBlob, key: dek, aad: aad)
        let cmData = data.subdata(in: layout.chunkMapRange)
        let chunks = (try? JSONDecoder().decode([ChunkInfo].self, from: cmData)) ?? []

        let selection: [VaultIndexEntry]
        if filters.isEmpty {
            selection = index.entries
        } else {
            selection = index.entries.filter { e in filters.contains { f in e.logicalPath.contains(f) } }
        }

        var results: [(String, URL, Int)] = []
        for e in selection {
            let fileChunks = chunks.filter { $0.name == e.logicalPath }
            var plain = Data(capacity: Int(e.size))
            for c in fileChunks {
                let start = layout.chunkAreaStart + Int(c.relOffset)
                let end = start + c.length
                guard end <= data.count else { continue }
                let combined = data.subdata(in: start..<end)
                // Use SealedBox combined form
                let sb = try AES.GCM.SealedBox(combined: combined)
                let dec = try AES.GCM.open(sb, using: dek, authenticating: aad)
                plain.append(dec)
            }
            let outURL = outDir.appendingPathComponent((e.logicalPath as NSString).lastPathComponent)
            try FileManager.default.createDirectory(at: outDir, withIntermediateDirectories: true)
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
        let data = try Data(contentsOf: vaultURL)
        let attrs = (try? FileManager.default.attributesOfItem(atPath: vaultURL.path)) ?? [:]
        let vaultSizeBytes = (attrs[.size] as? NSNumber)?.uint64Value ?? UInt64(data.count)
        let vaultLastModified = attrs[.modificationDate] as? Date
        let (head, hdrLen) = try parseHeaderAndOffset(data)
        let layout = computeLayout(data, afterHeader: hdrLen)

        // Sidecar count
        let sidecar = vaultURL.deletingPathExtension().appendingPathExtension("aegirofiles")
        var pending = 0
        if let metaData = try? Data(contentsOf: sidecar.appendingPathComponent("index.json")),
           let arr = try? JSONSerialization.jsonObject(with: metaData) as? [[String: Any]] {
            pending = arr.count
        }

        // Manifest verify
        let manBlob = data.subdata(in: layout.manRange)
        let manifest = try JSONDecoder().decode(Manifest.self, from: manBlob)
        #if REAL_CRYPTO
        let sig = Dilithium2()
        #else
        let sig = StubSig()
        #endif
        let ok = ManifestBuilder.verify(manifest, signer: sig)

        // Entries if we can decrypt
        var entriesCount: Int? = nil
        var locked = true
        if let pass = passphrase, !pass.isEmpty {
            if let dek = try? unlockDEK(data: data, head: head, layout: layout, passphrase: pass) {
                let aad = vaultAAD
                let idxBlob = data.subdata(in: layout.idxRange)
                if let index = try? IndexCrypto.decryptIndex(idxBlob, key: dek, aad: aad) {
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
    public static func run(vaultURL: URL, passphrase: String?, fix: Bool) throws -> DoctorReport {
        let data = try Data(contentsOf: vaultURL)
        var issues: [String] = []
        var fixed = false
        let (head, hdrLen): (VaultHeader, Int)
        do {
            (head, hdrLen) = try parseHeaderAndOffset(data)
        } catch {
            return DoctorReport(headerOK: false, manifestOK: false, chunkAreaOK: false, entries: nil, issues: ["Header parse failed: \(error)"], fixed: false)
        }
        let layout = computeLayout(data, afterHeader: hdrLen)

        // Manifest verify
        let manBlob = data.subdata(in: layout.manRange)
        let manifest = try JSONDecoder().decode(Manifest.self, from: manBlob)
        #if REAL_CRYPTO
        let sig = Dilithium2()
        #else
        let sig = StubSig()
        #endif
        var manifestOK = ManifestBuilder.verify(manifest, signer: sig)
        if !manifestOK && fix, let pass = passphrase {
            // Try to re-sign
            let dek = try Exporter.deriveDEK(data: data, passphrase: pass)
            let aad = vaultAAD
            let idxBlob = data.subdata(in: layout.idxRange)
            let index = try IndexCrypto.decryptIndex(idxBlob, key: dek, aad: aad)
            let cmData = data.subdata(in: layout.chunkMapRange)
            // Build new manifest
            let newManifest = try ManifestBuilder.build(index: index, chunkMap: cmData, signer: sig, sk: try unwrapSignerSK(data: data, dek: dek), pk: head.pq_pubkeys.dilithium_pk)
            let newManBlob = try JSONEncoder().encode(newManifest)
            var d = data
            let newLenLE = withUnsafeBytes(of: UInt32(newManBlob.count).littleEndian) { Data($0) }
            d.replaceSubrange(layout.manLenPos..<(layout.manLenPos+4), with: newLenLE)
            d.replaceSubrange(layout.manRange, with: newManBlob)
            try d.write(to: vaultURL, options: .atomic)
            manifestOK = true
            fixed = true
        }

        // Chunk area check vs chunk map
        let cmData = data.subdata(in: layout.chunkMapRange)
        let chunks = (try? JSONDecoder().decode([ChunkInfo].self, from: cmData)) ?? []
        let chunkSum = chunks.reduce(0) { $0 + $1.length }
        let areaBytes = data.count - layout.chunkAreaStart
        var chunkAreaOK = (chunkSum == areaBytes)
        if !chunkAreaOK {
            issues.append("Chunk area length \(areaBytes) != sum of chunks \(chunkSum)")
        }

        // Entry checks if passphrase provided
        var entryCount: Int? = nil
        if let pass = passphrase {
            let dek = try Exporter.deriveDEK(data: data, passphrase: pass)
            let aad = vaultAAD
            let idxBlob = data.subdata(in: layout.idxRange)
            if let index = try? IndexCrypto.decryptIndex(idxBlob, key: dek, aad: aad) {
                entryCount = index.entries.count
                // Check each entry has chunk coverage
                for e in index.entries {
                    let cs = chunks.filter { $0.name == e.logicalPath }
                    if cs.isEmpty { issues.append("No chunks for \(e.logicalPath)") }
                    // Approximate ciphertext size check (plaintext + 28 per chunk)
                    let cipherSum = cs.reduce(0) { $0 + $1.length }
                    let expectedMin = Int(e.size) + cs.count * 28
                    if cipherSum < expectedMin {
                        issues.append("Ciphertext too small for \(e.logicalPath): \(cipherSum) < \(expectedMin)")
                    }
                }
            }
        }

        return DoctorReport(headerOK: true, manifestOK: manifestOK, chunkAreaOK: chunkAreaOK, entries: entryCount, issues: issues, fixed: fixed)
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
        #if REAL_CRYPTO
        let sig = Dilithium2()
        #else
        let sig = StubSig()
        #endif
        let chunkMap = d.subdata(in: layout.chunkMapRange)
        let manifest = try ManifestBuilder.build(index: index, chunkMap: chunkMap, signer: sig, sk: signerSk, pk: head.pq_pubkeys.dilithium_pk)
        let manBlob = try JSONEncoder().encode(manifest)
        let manLenLE = withUnsafeBytes(of: UInt32(manBlob.count).littleEndian) { Data($0) }
        d.replaceSubrange(layout.manLenPos..<(layout.manLenPos+4), with: manLenLE)
        d.replaceSubrange(layout.manRange, with: manBlob)

        try d.write(to: vaultURL, options: .atomic)
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

        for c in existingChunks where !targets.contains(c.name) {
            let start = Int(c.relOffset)
            let end = start + c.length
            guard start >= 0, end <= existingArea.count else { continue }
            let blob = existingArea.subdata(in: start..<end)
            let offset = UInt64(chunkArea.count)
            chunkArea.append(blob)
            chunkInfos.append(ChunkInfo(name: c.name, relOffset: offset, length: blob.count))
        }

        let chunkCounts = chunkInfos.reduce(into: [String: Int]()) { counts, chunk in
            counts[chunk.name, default: 0] += 1
        }
        for i in index.entries.indices {
            let logical = index.entries[i].logicalPath
            index.entries[i].chunkCount = chunkCounts[logical] ?? 0
            index.entries[i].sidecarName = nil
        }

        let newIdxBlob = try IndexCrypto.encryptIndex(index, key: dek, aad: aad)
        let chunkMap = try JSONEncoder().encode(chunkInfos)

        let signerWrap = data.subdata(in: layout.signerWrapRange)
        let signerSk = try AEAD.decrypt(key: dek, nonce: try AES.GCM.Nonce(data: signerWrap.prefix(12)), combined: signerWrap, aad: aad)
        #if REAL_CRYPTO
        let sig = Dilithium2()
        #else
        let sig = StubSig()
        #endif
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
        return removed
    }
}
