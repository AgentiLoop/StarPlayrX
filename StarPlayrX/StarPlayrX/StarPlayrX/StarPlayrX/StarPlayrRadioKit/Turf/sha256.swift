//
//  sha256.swift
//  
//
//  Created by Todd Bruss on 9/9/22.
//

import Foundation
import CommonCrypto

//MARK: New and Improved MD5
public func sha256(_ str: String) -> String? {
    guard let data = str.data(using: .utf8) else { return nil }
    return Checksum.hash(data: data, using: .sha256)
}

struct Checksum {
    private init() {}

    static func hash(data: Data, using algorithm: HashAlgorithm) -> String {
        /// Creates an array of unsigned 8 bit integers that contains zeros equal in amount to the digest length
        var digest = [UInt8](repeating: 0, count: algorithm.digestLength())

        /// Call corresponding digest calculation
        data.withUnsafeBytes {
            guard let base = $0.baseAddress else { return }
            algorithm.digestCalculation(data: base, len: UInt32(data.count), digestArray: &digest)
        }

        var hashString = ""
        /// Unpack each byte in the digest array and add them to the hashString
        for byte in digest {
            hashString += String(format:"%02x", UInt8(byte))
        }

        return hashString
    }

    /**
    * Hash using CommonCrypto
    * API exposed from CommonCrypto-60118.50.1:
    * https://opensource.apple.com/source/CommonCrypto/CommonCrypto-60118.50.1/include/CommonDigest.h.auto.html
    **/
    enum HashAlgorithm {
        case sha256

        func digestLength() -> Int {
            switch self {
            case .sha256:
                return Int(CC_SHA256_DIGEST_LENGTH)
            }
        }

        /// CC_[HashAlgorithm] performs a digest calculation and places the result in the caller-supplied buffer for digest
        /// Calls the given closure with a pointer to the underlying unsafe bytes of the data's contiguous storage.
        func digestCalculation(data: UnsafeRawPointer, len: UInt32, digestArray: UnsafeMutablePointer<UInt8>) {
            switch self {
            case .sha256:
                CC_SHA256(data, len, digestArray)
            }
        }
    }
}
