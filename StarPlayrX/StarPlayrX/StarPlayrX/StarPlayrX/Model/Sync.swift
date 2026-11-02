//
//  readLocalDataFile.swift
//  StarPlayrX
//
//  Created by Todd Bruss on 7/29/19.
//  Modified by Todd Bruss on 5/18/25.
//  Copyright © 2019 Todd Bruss. All rights reserved.
//

import Foundation

class Sync {
    static let io = Sync()
    
    //MARK: Read a data file Synchronously
    func readLocalDataFile(filename:String) -> Data?  {
        try? NSData(contentsOfFile: Bundle.main.path(forResource: filename, ofType: "dms") ?? "") as Data
    }
    
    //MARK: Text Sync
    internal func Text(endpoint: String, TextHandler: @escaping TextHandler) {
        guard let url = URL(string: endpoint) else { TextHandler("error"); return}
        
        let semaphore = DispatchSemaphore(value: 0)

        var urlReq = URLRequest(url: url)
        urlReq.httpMethod = "GET"
        urlReq.timeoutInterval = TimeInterval(60)
        urlReq.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        
        let task = URLSession.shared.dataTask(with: urlReq ) { ( data, _, _ ) in
            
            guard
                let d = data,
                let text = String(data: d, encoding: .utf8)
                else { TextHandler("error"); return }
            
            TextHandler(text)
            
            semaphore.signal()

        }
        
        task.resume()
        
        _ = semaphore.wait(timeout: .distantFuture)
    }
}

//How to programically change audio but follows the same rules as MPVolumeView which does not cover AirPlay2

/* Any one of these will work. applicationMusicPlayer is preferred
 
 let strV = String(describing: 0.25 )
 var mpc = MPMusicPlayerController.systemMusicPlayer
 mpc.setValue(strV, forKey: "volume" )
 
 var mpc2 = MPMusicPlayerController.applicationMusicPlayer
 mpc2.setValue(strV, forKey: "volume" )
 
 var mpc3 = MPMusicPlayerController.applicationQueuePlayer
 mpc3.setValue(strV, forKey: "volume" )
 
 var mpc4 = MPMusicPlayerController.iPodMusicPlayer
 mpc4.setValue(strV, forKey: "volume" )
 
 */
