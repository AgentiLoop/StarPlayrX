//
//  Socket.swift
//  Swifter
//
//  Copyright (c) 2014-2016 Damian Kołakowski. All rights reserved.
//
//  SwifterLite
//  Copyright (c) 2022 Todd Bruss. All rights reserved.
//

import Foundation

open class Socket: Hashable, Equatable {
    
    let socketFileDescriptor: Int32
    static let kBufferLength = 1024
    
    private var shutdown = false
    private var isClosed = false
    private let closeLock = NSLock()
    static let CR: UInt8 = 13
    static let NL: UInt8 = 10
    
    public init(socketFileDescriptor: Int32) {
        self.socketFileDescriptor = socketFileDescriptor
    }
    
    deinit {
        close()
    }
    
    public func hash(into hasher: inout Hasher) {
        hasher.combine(self.socketFileDescriptor)
    }
    
    public func close() {
        closeLock.lock()
        defer { closeLock.unlock() }
        
        // Only close the socket if it hasn't been closed already
        if !isClosed && socketFileDescriptor != -1 {
            Socket.close(self.socketFileDescriptor)
            isClosed = true
        }
    }
    
    // SO_REUSEPORT - Allow socket port reuse
    @discardableResult
    func setReusePort(_ value: Bool) -> Bool {
        var optval: Int32 = value ? 1 : 0
        if setsockopt(socketFileDescriptor, SOL_SOCKET, SO_REUSEPORT, &optval, socklen_t(MemoryLayout<Int32>.size)) == -1 {
            return false
        }
        return true
    }
    
    // Set SO_LINGER option - helps free port immediately on socket close
    @discardableResult
    func setLinger(enabled: Bool, timeout: Int32 = 0) -> Bool {
        var l = linger(l_onoff: enabled ? 1 : 0, l_linger: timeout)
        if setsockopt(socketFileDescriptor, SOL_SOCKET, SO_LINGER, &l, socklen_t(MemoryLayout<linger>.size)) == -1 {
            return false
        }
        return true
    }
    
    public class func setNoSigPipe(_ socket: Int32) {
        // Prevents crashes when blocking calls are pending and the app is paused ( via Home button ).
        var no_sig_pipe: Int32 = 1
        setsockopt(socket, SOL_SOCKET, SO_NOSIGPIPE, &no_sig_pipe, socklen_t(MemoryLayout<Int32>.size))
    }
    
    public class func close(_ socket: Int32) {
        if socket != -1 {
            _ = Darwin.close(socket)
        }
    }
}

public func == (socket1: Socket, socket2: Socket) -> Bool {
    socket1.socketFileDescriptor == socket2.socketFileDescriptor
}
