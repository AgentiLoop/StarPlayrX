//
//  Login.swift
//  StarPlayrRadioApp
//
//  Created by Todd Bruss on 9/5/22.
//  Modified by Todd Bruss on 11/2/26.
//  Copyright © 2022 Todd Bruss. All rights reserved.
//

import Foundation

func sessionRoute() -> httpReq {{ request in
    autoreleasepool {
        let json = try? JSONSerialization.jsonObject(with: Data(request.body), options: JSONSerialization.ReadingOptions.fragmentsAllowed) as? [String:String]
        
        guard
            let channelid = json?["channelid"]
        else {
            return HttpResponse.notFound(.none)
        }

        let returnData = Session(channelid: channelid, updateToken: true, updateUser: true)
        if !returnData.isEmpty { storeCookiesX() }
        
        let obj = ["data": returnData, "message": "coolbeans", "success": true] as [String : Any]
        
        return HttpResponse.ok(.json(obj, contentType: "application/json"))
    }
}}
