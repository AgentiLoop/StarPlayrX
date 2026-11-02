//
//  SocketClient.swift
//  Swifter
//
//  Copyright (c) 2014-2016 Damian Kołakowski. All rights reserved.
//
//  SwifterLite
//  Copyright (c) 2022 Todd Bruss. All rights reserved.
//

import Foundation

extension Socket {
    public func acceptClientSocket() throws -> Socket {
        try autoreleasepool {
            var addr = sockaddr()
            var len: socklen_t = 0
            let clientSocket = accept(self.socketFileDescriptor, &addr, &len)
            
            if clientSocket != -1 {
                Socket.setNoSigPipe(clientSocket)
                
                // Set SO_REUSEPORT to allow port reuse
                var value: Int32 = 1
                setsockopt(clientSocket, SOL_SOCKET, SO_REUSEPORT, &value, socklen_t(MemoryLayout<Int32>.size))
                
                // Set SO_LINGER to ensure ports are freed immediately
                var l = linger(l_onoff: 1, l_linger: 0)
                setsockopt(clientSocket, SOL_SOCKET, SO_LINGER, &l, socklen_t(MemoryLayout<linger>.size))
                
                return Socket(socketFileDescriptor: clientSocket)
            } else {
                throw SocketError.acceptFailed(ErrNumString.description())
            }
        }
    }
}
