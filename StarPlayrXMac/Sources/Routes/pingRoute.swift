//
//  File.swift
//  
//
//  Created by Todd Bruss on 9/11/22.
//  Modified by Todd Bruss on 11/2/26.
//  Copyright © 2022 Todd Bruss. All rights reserved.
//

import Foundation

func pingRoute(pong: String) -> httpReq {{ request in    
    // reset the stream's token id
    resetChTknId = pong

    // Refresh token every 480 seconds
    if (currentTimeInMiliseconds() - tokenExpires) >= 480000 {
        DispatchQueue.main.async {
            Session(channelid: userX.channel, updateToken: true, updateUser: false)
        }
        tokenExpires = currentTimeInMiliseconds()
    }
    
    return HttpResponse.ok(.ping(pong, contentType: "text/plain"))
}}
