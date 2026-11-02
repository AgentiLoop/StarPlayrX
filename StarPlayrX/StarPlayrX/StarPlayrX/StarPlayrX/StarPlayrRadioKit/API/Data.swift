//
//  DataAsync.swift
//
//  Created by Todd on 4/18/20.
//

import Foundation

//MARK: Data Sync
func dataSync(endpoint: String, method: String, DataHandler: @escaping DataHandler ) {
 
    guard let url = URL(string: endpoint) else { DataHandler(.none); return}
    
    let semaphore = DispatchSemaphore(value: 0)

    var urlReq = URLRequest(url: url)
    urlReq.httpMethod = "GET"
    urlReq.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    urlReq.addValue("application/json", forHTTPHeaderField: "Content-Type")
    // A segment that takes longer than this is useless to the player anyway; fail fast so it can retry.
    urlReq.timeoutInterval = TimeInterval(15)
    urlReq.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
    
    let task = URLSession.shared.dataTask(with: urlReq ) { ( data, response, _ ) in
        // Always release the waiting server thread, or a failed download hangs that request forever.
        defer { semaphore.signal() }
        
        guard
            let d = data,
            (response as? HTTPURLResponse)?.statusCode ?? 200 < 400
        else { DataHandler(.none); return
        }
        
        DataHandler(d)
    }
    
    task.resume()
    _ = semaphore.wait(timeout: .now() + 20)
}
