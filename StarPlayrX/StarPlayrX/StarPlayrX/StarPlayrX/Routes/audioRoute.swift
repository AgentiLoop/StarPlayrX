//
//  audioRoute.swift
//  StarPlayrRadioApp
//
//  Created by Todd Bruss on 9/6/22.
//  Modified by Todd Bruss on 11/2/26.
//

import Foundation

func audioRoute() -> httpReq {{ request in
    autoreleasepool {
        
        guard
            let aac = request.params[":aac"]
        else {
            return HttpResponse.notFound(.none)
        }
        
        let endpoint = AudioX(data: aac, channelId: userX.channel)
        
        var audio = Data()
        
        dataSync(endpoint: endpoint, method: audioFormat) { (data) in
            autoreleasepool {
                guard
                    let data = data
                else {
                    return
                }
                audio = data
            }
        }
        
        // One quick retry: a single failed download used to leave a 10 s hole in the audio.
        if audio.isEmpty {
            dataSync(endpoint: endpoint, method: audioFormat) { data in
                if let data { audio = data }
            }
        }
        
        if audio.isEmpty {
            liveSegmentObserver?(aac, Data(), nil)
            return HttpResponse.notFound(.none)
        }
        
        liveSegmentObserver?(aac, audio, Data(base64Encoded: userX.key))
        
        // Use the optimized audioStream response type for better streaming performance
        return HttpResponse.ok(.data(audio, contentType: audioFormat), [
            "X-Channel-ID": userX.channel,
            "X-Content-Length": String(audio.count)
        ])
    }
}}
