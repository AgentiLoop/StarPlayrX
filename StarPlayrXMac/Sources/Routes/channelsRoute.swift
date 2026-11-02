//
//  channelsRoute.swift
//  StarPlayrRadioApp
//
//  Created by Todd Bruss on 9/5/22.
//  Modified by Todd Bruss on 11/2/26.
//

import Foundation

func channelsRoute() -> httpReq {{ request in
    autoreleasepool {
        let api = Channels()
        var obj = [String : Any]()

        PostSync(request: api.request, endpoint: api.endpoint, method: api.method) { (result) in
        
            if let result = result {
                let returnData = processChannels(result: result)
                if returnData.success { storeCookiesX() }
                
               /// print("returnData", returnData)
            
                obj = ["data": returnData.data, "message": returnData.message, "success": returnData.success, "categories": returnData.categories] as [String : Any]
                
            } else {
                obj = ["data": [:], "message": "Login failure.", "success": false] as [String : Any]
            }
        }
        return HttpResponse.ok(.json(obj, contentType: "application/json"))
    }
}}

