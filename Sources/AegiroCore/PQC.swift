
import Foundation

public protocol PQKEM {
    func keypair() throws -> (pk: Data, sk: Data)
    func encap(_ pk: Data) throws -> (ss: Data, ct: Data)
    func decap(_ ct: Data, sk: Data) throws -> Data
}

public protocol PQSig {
    func keypair() throws -> (pk: Data, sk: Data)
    func sign(message: Data, sk: Data) throws -> Data
    func verify(message: Data, sig: Data, pk: Data) -> Bool
}

import OQSWrapper
import OpenSSLShim // ensure libcrypto links in crypto builds
public struct Kyber512: PQKEM {
    public init() {}
    public func keypair() throws -> (pk: Data, sk: Data) {
        guard let kem = OQS_KEM_new(OQS_KEM_alg_kyber_512) else {
            throw AEGError.crypto("OQS_KEM_new(kyber_512) failed")
        }
        defer { OQS_KEM_free(kem) }

        let pkLen = Int(kem.pointee.length_public_key)
        let skLen = Int(kem.pointee.length_secret_key)
        var pk = Data(count: pkLen)
        var sk = Data(count: skLen)

        let rc = pk.withUnsafeMutableBytes { pkRaw in
            sk.withUnsafeMutableBytes { skRaw in
                OQS_KEM_keypair(kem,
                                pkRaw.bindMemory(to: UInt8.self).baseAddress,
                                skRaw.bindMemory(to: UInt8.self).baseAddress)
            }
        }
        if rc != OQS_SUCCESS {
            throw AEGError.crypto("OQS_KEM_keypair failed: \(rc)")
        }
        return (pk, sk)
    }

    public func encap(_ pk: Data) throws -> (ss: Data, ct: Data) {
        guard let kem = OQS_KEM_new(OQS_KEM_alg_kyber_512) else {
            throw AEGError.crypto("OQS_KEM_new(kyber_512) failed")
        }
        defer { OQS_KEM_free(kem) }

        let ctLen = Int(kem.pointee.length_ciphertext)
        let ssLen = Int(kem.pointee.length_shared_secret)
        var ct = Data(count: ctLen)
        var ss = Data(count: ssLen)

        let rc = pk.withUnsafeBytes { pkRaw in
            ct.withUnsafeMutableBytes { ctRaw in
                ss.withUnsafeMutableBytes { ssRaw in
                    OQS_KEM_encaps(kem,
                                   ctRaw.bindMemory(to: UInt8.self).baseAddress,
                                   ssRaw.bindMemory(to: UInt8.self).baseAddress,
                                   pkRaw.bindMemory(to: UInt8.self).baseAddress)
                }
            }
        }
        if rc != OQS_SUCCESS {
            throw AEGError.crypto("OQS_KEM_encaps failed: \(rc)")
        }
        return (ss, ct)
    }

    public func decap(_ ct: Data, sk: Data) throws -> Data {
        guard let kem = OQS_KEM_new(OQS_KEM_alg_kyber_512) else {
            throw AEGError.crypto("OQS_KEM_new(kyber_512) failed")
        }
        defer { OQS_KEM_free(kem) }

        let ssLen = Int(kem.pointee.length_shared_secret)
        var ss = Data(count: ssLen)
        let rc = ct.withUnsafeBytes { ctRaw in
            sk.withUnsafeBytes { skRaw in
                ss.withUnsafeMutableBytes { ssRaw in
                    OQS_KEM_decaps(kem,
                                   ssRaw.bindMemory(to: UInt8.self).baseAddress,
                                   ctRaw.bindMemory(to: UInt8.self).baseAddress,
                                   skRaw.bindMemory(to: UInt8.self).baseAddress)
                }
            }
        }
        if rc != OQS_SUCCESS {
            throw AEGError.crypto("OQS_KEM_decaps failed: \(rc)")
        }
        return ss
    }
}
public struct Dilithium2: PQSig {
    public init() {}
    public func keypair() throws -> (pk: Data, sk: Data) {
        guard let sig = OQS_SIG_new(OQS_SIG_alg_dilithium_2) else {
            throw AEGError.crypto("OQS_SIG_new(dilithium_2) failed")
        }
        defer { OQS_SIG_free(sig) }

        let pkLen = Int(sig.pointee.length_public_key)
        let skLen = Int(sig.pointee.length_secret_key)
        var pk = Data(count: pkLen)
        var sk = Data(count: skLen)
        let rc = pk.withUnsafeMutableBytes { pkRaw in
            sk.withUnsafeMutableBytes { skRaw in
                OQS_SIG_keypair(sig,
                                pkRaw.bindMemory(to: UInt8.self).baseAddress,
                                skRaw.bindMemory(to: UInt8.self).baseAddress)
            }
        }
        if rc != OQS_SUCCESS {
            throw AEGError.crypto("OQS_SIG_keypair failed: \(rc)")
        }
        return (pk, sk)
    }

    public func sign(message: Data, sk: Data) throws -> Data {
        guard let sig = OQS_SIG_new(OQS_SIG_alg_dilithium_2) else {
            throw AEGError.crypto("OQS_SIG_new(dilithium_2) failed")
        }
        defer { OQS_SIG_free(sig) }

        // Allocate worst-case signature buffer
        let sigCap = Int(sig.pointee.length_signature)
        var sigBuf = Data(count: sigCap)
        var sigLen: Int = 0
        var rc: OQS_STATUS = OQS_ERROR
        message.withUnsafeBytes { msgRaw in
            sk.withUnsafeBytes { skRaw in
                sigBuf.withUnsafeMutableBytes { outRaw in
                    var outLen: size_t = 0
                    rc = OQS_SIG_sign(sig,
                                       outRaw.bindMemory(to: UInt8.self).baseAddress,
                                       &outLen,
                                       msgRaw.bindMemory(to: UInt8.self).baseAddress,
                                       message.count,
                                       skRaw.bindMemory(to: UInt8.self).baseAddress)
                    sigLen = Int(outLen)
                }
            }
        }
        if rc != OQS_SUCCESS { throw AEGError.crypto("OQS_SIG_sign failed: \(rc)") }
        return sigBuf.prefix(sigLen)
    }

    public func verify(message: Data, sig: Data, pk: Data) -> Bool {
        guard let s = OQS_SIG_new(OQS_SIG_alg_dilithium_2) else { return false }
        defer { OQS_SIG_free(s) }
        var rc: OQS_STATUS = OQS_ERROR
        message.withUnsafeBytes { msgRaw in
            sig.withUnsafeBytes { sigRaw in
                pk.withUnsafeBytes { pkRaw in
                    rc = OQS_SIG_verify(s,
                                        msgRaw.bindMemory(to: UInt8.self).baseAddress,
                                        message.count,
                                        sigRaw.bindMemory(to: UInt8.self).baseAddress,
                                        sig.count,
                                        pkRaw.bindMemory(to: UInt8.self).baseAddress)
                }
            }
        }
        return rc == OQS_SUCCESS
    }
}
