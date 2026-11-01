//
//  playlistRoute.swift
//  StarPlayrRadioApp
//
//  Created by Todd Bruss on 9/5/22.
//

import Foundation
import SwifterLite

var resetChTknId : String = ""
var tokenExpires : Int    = 0

func currentTimeInMiliseconds() -> Int {
    let currentDate = Date()
    let since1970 = currentDate.timeIntervalSince1970
    return Int(since1970 * 1000)
}

func playlistRoute() -> httpReq {{ request in
    autoreleasepool {
        var playlist = String()
        
        guard
            let channelid = request.params[":channelid"]
        else {
            return HttpResponse.notFound(.none)
        }
        
        if let channel = String?(String(channelid.split(separator: ".")[0])),
           let ch = userX.channels[channel] as? NSDictionary,
           let channelid = ch["channelId"] as? String {
            
            userX.channel = channelid
            
            // Reset token if we have a new channel or we paused over 8 minutes
            if resetChTknId != channelid {
                Session(channelid: channelid, updateToken: true, updateUser: true)
                resetChTknId = channelid
                tokenExpires = currentTimeInMiliseconds()
            }
                          
            // Refresh token every 480 seconds
            if (currentTimeInMiliseconds() - tokenExpires) >= 480000 {
                DispatchQueue.main.async {
                    Session(channelid: channelid, updateToken: true, updateUser: false)
                }
                tokenExpires = currentTimeInMiliseconds()
            }
            
            let source = Playlist(channelid: channelid)
            
            TextSync(endpoint: source) { (list) in
                guard
                    let list = list
                else {
                    return
                }
                
                func processPlaylist(_ list: String) -> String {
                    playlist = list
                    
                    //MARK: fix key path
                    playlist = playlist.replacingOccurrences(of: "key/1", with: "/api/v3/key")
                    
                    //MARK: add audio prefix
                    playlist = playlist.replacingOccurrences(of: channelid, with: "/api/v3/aac/" + channelid)
                    
                    // The Mac app needs true durations so the player's date matches the stream's PDT.
                    // It also starts 10 s behind live instead of AVPlayer's default three segments back.
                    if realSegmentDurations {
                        // Insert right after #EXTM3U so it works with both "\n" and "\r\n" line endings
                        // (Swift treats "\r\n" as one Character, so firstIndex(of: "\n") misses it).
                        if !playlist.contains("#EXT-X-START"), let header = playlist.range(of: "#EXTM3U") {
                            playlist.insert(contentsOf: "\n#EXT-X-START:TIME-OFFSET=-10", at: header.upperBound)
                        }
                        return playlist
                    }

                    //MARK: fix duration
                    playlist = playlist.replacingOccurrences(of: "#EXT-X-TARGETDURATION:10", with: "#EXT-X-TARGETDURATION:9")
                    
                    //MARK: this keeps the PDT in sync, go figure
                    playlist = playlist.replacingOccurrences(of: "#EXTINF:10,", with: "#EXTINF:1,")
                    
                    return playlist
                }

                playlist = processPlaylist(list)
            }
        }
        
        if !playlist.isEmpty {
            // Use the new hlsPlaylist response type for better HLS streaming support
            return HttpResponse.ok(.ping(playlist), [
                "X-Channel-ID": userX.channel,
                "X-Playlist-Version": "3"
            ])
        } else {
            return HttpResponse.notFound(.none)
        }
    }
}}
