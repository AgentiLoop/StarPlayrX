//
//  Extensions.swift
//  StarPlayrXMac
//
//  Created by Todd Bruss on 11/2/26.
//  Copyright © 2026 Todd Bruss. All rights reserved.
//
//  Small extensions and helpers on standard types, shared across the app.

import Foundation
import CommonCrypto

// MARK: Data: AES-128 HLS segments

extension Data {
    public init(sequenceIV n: Int) {
        var bytes = [UInt8](repeating: 0, count: 16)
        var v = UInt64(n)
        for i in (8..<16).reversed() { bytes[i] = UInt8(v & 0xff); v >>= 8 }
        self.init(bytes)
    }

    public init?(hex: String) {
        guard hex.count == 32 else { return nil }
        var bytes = [UInt8]()
        var i = hex.startIndex
        while i < hex.endIndex {
            let j = hex.index(i, offsetBy: 2)
            guard let b = UInt8(hex[i..<j], radix: 16) else { return nil }
            bytes.append(b)
            i = j
        }
        self.init(bytes)
    }
}

// MARK: Decryption helpers

public func aes128Decrypt(_ data: Data, key: Data, iv: Data) -> Data? {
    var out = Data(count: data.count + kCCBlockSizeAES128)
    var moved = 0
    let outCount = out.count
    let status = out.withUnsafeMutableBytes { o in
        data.withUnsafeBytes { d in
            key.withUnsafeBytes { k in
                iv.withUnsafeBytes { v in
                    CCCrypt(CCOperation(kCCDecrypt), CCAlgorithm(kCCAlgorithmAES), CCOptions(kCCOptionPKCS7Padding),
                            k.baseAddress, key.count, v.baseAddress, d.baseAddress, data.count,
                            o.baseAddress, outCount, &moved)
                }
            }
        }
    }
    guard status == kCCSuccess else { return nil }
    return out.prefix(moved)
}

/// Each HLS audio segment starts with an ID3 timestamp tag; drop it so the segments join into one clean AAC stream.
public func stripID3(_ data: Data) -> Data {
    let b = [UInt8](data.prefix(10))
    guard b.count == 10, b[0] == 0x49, b[1] == 0x44, b[2] == 0x33 else { return data }
    let size = Int(b[6] & 0x7f) << 21 | Int(b[7] & 0x7f) << 14 | Int(b[8] & 0x7f) << 7 | Int(b[9] & 0x7f)
    let header = 10 + size + (b[5] & 0x10 != 0 ? 10 : 0)
    return header < data.count ? data.subdata(in: data.startIndex + header ..< data.endIndex) : data
}

// MARK: Double

extension Double {
    public var clamped: Double { Swift.min(1, Swift.max(0, self)) }
}
