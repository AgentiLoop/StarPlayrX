//
//  Networkabilty.swift
//  StarPlayr
//
//  Created by Todd on 5/2/19.
//  Copyright © 2019 Todd Bruss. All rights reserved.
//

import Network
import Foundation

public class Network {
    static var ability = Network()
    
    let monitor = NWPathMonitor()
    let monitorString = "Monitor"
    var networkIsConnected = Bool()
    var networkIsCellular = Bool()
    
    func start() {
        monitor.pathUpdateHandler = { [self] path in
            networkIsCellular = path.usesInterfaceType(.cellular)
        }
        
        let queue = DispatchQueue(label: monitorString)
        monitor.start(queue: queue)
    }
}
