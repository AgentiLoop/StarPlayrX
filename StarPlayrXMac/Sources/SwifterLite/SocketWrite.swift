//
//  SocketWrite.swift
//  Swifter
//
//  Copyright (c) 2014-2016 Damian Kołakowski. All rights reserved.
//
//  SwifterLite
//  Copyright (c) 2022 Todd Bruss. All rights reserved.
//

import Foundation

extension Socket {
    public func writeUtf8(_ string: String) throws {
        try writeBuffer([UInt8](string.utf8), length: (string.utf8).count)
    }
    
    public func writeUInt8(_ data: [UInt8]) throws {
        try writeBuffer([UInt8](data), length: data.count)
    }

    public func writeData(_ data: Data) throws {
        try writeBuffer([UInt8](data), length: data.count)
    }

    private func writeBuffer(_ pointer: UnsafeRawPointer, length: Int) throws {
        var sent = 0
        
        while sent < length {
            let result = write(self.socketFileDescriptor, pointer + sent, Int(length - sent))

            if result > 0 {
                sent += result
            } else {
                throw SocketError.writeFailed(ErrNumString.description())
            }
        }
        
    }
}

//                let bufferSize = 1024
//                let stream = InputStream(data: audio)
//                var buf = [UInt8](repeating: 0, count: bufferSize)
//
//                stream.open()
//                while case let amount = stream.read(&buf, maxLength: bufferSize), amount > 0 {
//                    try writer.write(byts: [UInt8](buf[..<amount]))
//                }
//                stream.close()
