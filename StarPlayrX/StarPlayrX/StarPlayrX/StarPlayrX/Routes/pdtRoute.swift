//
//  pdtRoute.swift
//  StarPlayrRadioApp
//
//  Created by Todd Bruss on 9/5/22.
//

import Foundation
import SwifterLite
import StarPlayrRadioKit

func pdtRoute() -> httpReq {{ request in
    autoreleasepool {
        var obj = [ String : Any]()
        
        if !userX.channel.isEmpty {
            let epoint = nowPlayingLive(channelid: userX.channel)
            
            nowPlayingLiveAsync(endpoint: epoint) { data in
                if let data = data {
                    processNPL(data: data)
                }
            }
        }
        
        func fallback() {
            var artist_song_data = [String : Any ]()
            if userX.channels.count > 1 {
                for ( key, value ) in userX.channels {
                    
                    let v = value as? [String: Any]
                    let name = v?["name"] as? String
                    
                    //Substitute text for when channel guide is offline
                    artist_song_data[key] = ["image": "", "artist": key, "song": name]
                }
            } else {
                for i in 0...1000 {
                    artist_song_data["\(i)"] = ["image": "", "artist": "StarPlayrX", "song": "iOS Best Sat Radio Player"]
                }
            }
            
            obj = ["data": artist_song_data, "message": "0000", "success": true] as [String : Any]
        }
        
        func runPDT() {
            let endpoint = PDTendpoint()
    
            GetPdtSync(endpoint: endpoint, method: "PDT") { pdt in
                if let pdt = pdt {
                    let artist_song_data = processPDT(data: pdt)
                    
                    if !artist_song_data.isEmpty {
                        obj = ["data": artist_song_data, "message": "0001", "success": true] as [String : Any]
                    } else {
                        fallback()
                    }
                } else {
                    fallback()
                }
            }
        }
        runPDT()
         
        return HttpResponse.ok(.json(obj, contentType: "application/json"))
    }
}}
