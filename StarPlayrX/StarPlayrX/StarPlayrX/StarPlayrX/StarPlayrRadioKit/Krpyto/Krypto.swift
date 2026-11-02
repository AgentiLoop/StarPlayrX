//
//  KryptoClass.swift
//  Emoji Pass X
//
//  Created by Todd Bruss on 3/27/21.
//
import Foundation
import CommonCrypto

protocol KryptoProtocol {
//    func encrypt(string: String, key: Data, encoding: String.Encoding) -> Data
    func decrypt(data: Data, key: Data, encoding: String.Encoding) -> String
    func krypt(operation: Int, algorithm: Int, options: Int, key: Data, initializationVector: Data, dataIn: Data) -> Data?
}

struct Krypto: KryptoProtocol {
//    func encrypt(string: String, key: Data, encoding: String.Encoding) -> Data {
//        guard !string.isEmpty,
//              let secret = string.data(using: encoding),
//              let encrypted = secret.encrypt(key: key)
//        else {
//            return Data()
//        }
//
//        return encrypted
//    }
    
    func decrypt(data: Data, key: Data, encoding: String.Encoding) -> String {
        guard !data.isEmpty,
              let secret = data.decrypt(key: key),
              let decrypted = String(data: secret, encoding: encoding)
        else {
            return String()
        }
        
        return decrypted
    }
    
    // https://www.splinter.com.au/2019/06/09/pure-swift-common-crypto-aes-encryption/ Chris Hulbert
    func krypt(operation: Int, algorithm: Int, options: Int, key: Data, initializationVector: Data, dataIn: Data) -> Data? {
        
        key.withUnsafeBytes { keyUnsafeRawBufferPointer in
            dataIn.withUnsafeBytes { dataInUnsafeRawBufferPointer in
                initializationVector.withUnsafeBytes { ivUnsafeRawBufferPointer in
                    
                    let dataOutSize: Int = dataIn.count + kCCBlockSizeAES128 * 2
                    
                    let dataOut = UnsafeMutableRawPointer.allocate(
                        byteCount: dataOutSize,
                        alignment: 1)
                    defer {dataOut.deallocate()}
                    
                    var dataOutMoved: Int = 0
                    
                    guard
                        let success =
                            Optional(
                                CCCrypt(
                                    CCOperation(operation),
                                    CCAlgorithm(algorithm),
                                    CCOptions(options),
                                    keyUnsafeRawBufferPointer.baseAddress,
                                    key.count,
                                    ivUnsafeRawBufferPointer.baseAddress,
                                    dataInUnsafeRawBufferPointer.baseAddress,
                                    dataIn.count,
                                    dataOut,
                                    dataOutSize,
                                    &dataOutMoved)),
                        success == kCCSuccess
                    else {
                        return nil
                    }
                    
                    return Data(bytes: dataOut, count: dataOutMoved)
                }
            }
        }
    }
}
