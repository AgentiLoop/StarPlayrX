//
//  regionRoute.swift
//  
//
//  Created by Todd Bruss on 9/11/22.
//  Modified by Todd Bruss on 11/2/26.
//

import Foundation

func regionRoute(region: String) -> httpReq {{ request in
    playerDomain = region == "ca" ? "player.siriusxm.ca" : "player.siriusxm.com"
    root = "\(playerDomain)/rest/v2/experience/modules"
    appRegion = region.uppercased()
    
    return HttpResponse.ok(.ping(appRegion, contentType: "text/plain"))
}}
