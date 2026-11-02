//
//  Middleware.swift
//  StarPlayrRadioApp
//
//  Created by Todd Bruss on 9/5/22.
//

import Foundation
import SwifterLite
import StarPlayrRadioKit

public func startServer(_ port: UInt16) {
    let server = streamingServer()
    
    Task {
        try? server.start(port)
        print("Server has started on port \(port)")
    }

}

//MARK: Swifter Embedded Web Server Routes
public func streamingServer() -> HttpServer {
    let server = HttpServer()
    
    autoreleasepool {
        server.get ["/api/v3/ping"]           = pingRoute(pong: "pong")
        server.get ["/api/v3/us"]             = regionRoute(region: "us")
        server.get ["/api/v3/ca"]             = regionRoute(region: "ca")
        server.post["/api/v3/login"]          = loginRoute()
        server.post["/api/v3/session"]        = sessionRoute()
        server.post["/api/v3/channels"]       = channelsRoute()
        server.get ["/api/v3/pdt"]            = pdtRoute()
        server.get ["/api/v3/key"]            = keyOneRoute()
        server.get ["/api/v3/m3u/:channelid"] = playlistRoute()
        server.get ["/api/v3/aac/:aac"]       = audioRoute()
        server.get ["/api/v3/routes"]         = checkRoute(server: server)
    }

    return server
}
