//
//  PDT.swift
//
//  Created by Todd Bruss on 1/27/19.
//

import Foundation
import CommonCrypto

public func PDTendpoint() -> String {
    
    let timeInterval = Date().timeIntervalSince1970
    let convert = timeInterval * 1000 as NSNumber
    let intTime = (Int(truncating: convert))
    let time = String(intTime)
    
    let endpoint = "https://\(playerDomain)/rest/v2/experience/modules/get/discover-channel-list?type=2&batch-mode=true&format=json&request-option=discover-channel-list-withpdt&result-template=web&time=" + time
    
    return endpoint
}

//MARK: Process Artist and Song Data
public func processPDT(data: DiscoverChannelList) -> [String:Any] {
    var ArtistSongData = [String : Any ]()
    
    //let status = data.moduleListResponse.status //100
    if let live = data.moduleListResponse?.moduleList?.modules?.first?.moduleResponse?.moduleDetails?.liveChannelResponse?.liveChannelResponses {
        autoreleasepool {
            for i in live {
                
                let channelid = i.channelID
                let markerLists = i.markerLists
                let cutlayer = markerLists?.first
                
                if let markers = cutlayer?.markers, let item = markers.first, let song = item.cut?.title, let artist = item.cut?.artists?.first?.name, let getchannelbyId = userX.ids[channelid ?? ""] as? [String: Any], let channelNo = getchannelbyId["channelNumber"] as? String {
                    if let key = sha256(artist + song), let image = MemBase[key] {
                        ArtistSongData[channelNo] = ["image" : image, "artist" : artist, "song" : song]
                    } else {
                        ArtistSongData[channelNo] = ["image" : "", "artist" : artist, "song" : song]
                    }
                } else if let getchannelbyId = userX.ids[channelid ?? ""] as? [String: Any], let channelNo = getchannelbyId["channelNumber"] as? String {
                    ArtistSongData[channelNo] = ["image" : "", "artist" : "Don't be a Slacker", "song" : "Be a Star Player. StarPlayrX"]
                }
            }
        }
      
        
    } else {
        if userX.channels.count > 1 {
            for ( key, value ) in userX.channels {
                
                let v = value as? [String: Any]
                guard let name = v?["name"] as? String else { return ArtistSongData}
                
                ArtistSongData[key] = ["image" : "", "artist": key, "song" : name]
            }
        } else {
            for i in 0...1000 {
                ArtistSongData["\(i)"] = ["image" : "", "artist" : "StarPlayrX", "song" : "iOS Best Sat Radio Player"]
            }
        }
    }
    return ArtistSongData
}


