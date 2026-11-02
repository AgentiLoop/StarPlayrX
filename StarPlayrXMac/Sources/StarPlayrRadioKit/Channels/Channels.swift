//
//  Channels.swift
//  StarPlayrXMac
//
//  Created by Todd Bruss on 11/2/26.
//  Modified by Todd Bruss on 11/2/26.
//  Copyright © 2026 Todd Bruss. All rights reserved.
//

import Foundation

typealias ChannelsTuple = (success: Bool, message: String, data: Dictionary<String, Any>, categories: Array<String> )

public func Channels() -> (request: [String : [String : [[String : Any]]]], endpoint: String, method: String) {
    let endpoint = "https://\(playerDomain)/rest/v4/experience/modules/get?type=2"
    let method = "channels"
    let request =  ["moduleList":["modules":[["moduleArea":"Discovery","moduleType":"ChannelListing","moduleRequest":["resultTemplate":""]]]]] as Dictionary

    return (request: request, endpoint: endpoint, method: method)
}

public func processChannels(result: PostReturnTuple) -> (success: Bool, message: String, data: Dictionary<String,Any>, categories: Array<String>) {
    
    var recordCategories = Array<String>()
    var success : Bool = false
    var message : String = "Something's not right."
    
    guard let responseCode = result.response?.statusCode else { return  (success: false, message: "Bad JuJu", data: [:], categories: []) }
    
    if responseCode > 300 {
        success = false
        message = "Too many incorrect logins, your Sat Radio provider has blocked your IP for 24 hours."
    }
    
    if result.success {
        let result = result.data as NSDictionary
        
        if let r = result.value(forKeyPath: "ModuleListResponse.moduleList.modules"),
           let m = r as? NSArray,
           let o = m[0] as? NSDictionary,
           let d = o.value( forKeyPath: "moduleResponse.contentData.channelListing.channels") as? NSArray {
            
            var ChannelDict : Dictionary = Dictionary<String, Any>()
            var ChannelIdDict : Dictionary = Dictionary<String, Any>()
            
            for i in d {
                autoreleasepool {
                    if
                        let dict          = i as? NSDictionary,
                        let channelId     = dict.value( forKeyPath: "channelId") as? String,
                        let categories    = dict.value( forKeyPath: "categories.categories") as? NSArray,
                        let cats          = categories.firstObject as? NSDictionary,
                        let channelNumber = dict.value( forKeyPath: "channelNumber") as? String,
                        var category      = cats.value( forKeyPath: "name") as? String
                    {
                        
                        switch category {
                            
                        case "Latino Talk":
                            category = "Latin Talk"
                            
                        case "Latino Music":
                            category = "Latin Music"
                            
                        case "Latino":
                            category = "Latin Music"
                            
                        case "Canadian Talk":
                            category = "Canada Talk"
                            
                        case "Canada & More":
                            category = "Canada Music"
                            
                        case "Sports":
                            category = "Sports Talk"
                            
                        case "MLB Play-by-Play":
                            category = "MLB"
                            
                        case "NBA Play-by-Play":
                            category = "NBA"
                            
                        case "NFL Play-by-Play":
                            category = "NFL"
                            
                        case "NHL Play-by-Play":
                            category = "NHL"
                            
                        case "Sports Play-by-Play":
                            category = "Play-by-Play"
                            
                        case "Other Play-by-Play":
                            category = "Play-by-Play"
                        default:
                            _ = category
                        }
                        
                        let chNumber = Int(channelNumber)
                        
                        switch chNumber {
                            
                        case 20,18,19,22,23,24,29,30,31,32,38,42,75,104,105,176,333,504,505,700,709,711,717,721:
                            category = "Artists"
                            
                        case 4,11,14,769:
                            category = "Pop"
                            
                        case 7,8,12,17,27,28,35,301:
                            category = "Rock"
                            
                        case 13,718:
                            category = "Dance/Electronic"
                            
                        case 9,33,34,36,173,309,716:
                            category = "Alternative"
                            
                        case 37,39,40,41,714:
                            category = "Metal"
                            
                        case 5,6,701,703,776:
                            category = "Oldies"
                            
                        case 314,712,713:
                            category = "Punk"
                            
                        case 48,68,330,708:
                            category = "Love Songs"
                            
                        case 302:
                            category = "Family"
                            
                        case 165:
                            category = "Canada Music"
                            
                        case 172:
                            category = "Sports Talk"
                            
                        case 171:
                            category = "Country"
                            
                        case 141, 142, 706:
                            category = "Jazz/Standards/Classical"
                            
                        case 169:
                            category = "Canada Talk"
                            
                        case 152,158:
                            category = "Latin Music"
                            
                        case 501,502,503,506,507,508,509,510,511:
                            category = "X Info"
                            
                        case 21:
                            category = "Oldies"
                            
                        default:
                            _ = category
                            //category = category
                        }
                        
                        // append it to the categorieshit
                        if !recordCategories.contains(category) {
                            recordCategories.append(category)
                        }
                        
                        var mediumImage = ""
                        
                        if let images = dict.value( forKeyPath: "images.images") as? NSArray,
                           let name = dict.value( forKeyPath: "name") as? String {
                            
                            for img in images.reversed() {
                                if let g = img as? NSDictionary, let height = g["height"] as? Int, let name = g["name"] as? String {
                                    
                                    if height == 720 && name == "color channel logo (on dark)" {
                                        if let mi = g["url"] as? String {
                                            mediumImage = mi
                                            break
                                        }
                                    }
                                }
                            }
                            
                            let cl = [
                                "channelId": channelId,
                                "channelNumber": channelNumber,
                                "name": name,
                                "mediumImage": mediumImage,
                                "category": category,
                                "preset": false
                            ] as [String : Any]
                            
                            let ids = ["channelNumber": channelNumber] as [String : String]
                            
                            ChannelDict[channelNumber] = cl
                            ChannelIdDict[channelId] = ids
                        }
                    }
                }
            }
            
            userX.channels = ChannelDict
            userX.ids = ChannelIdDict
            
            if !userX.channels.isEmpty {
                
                UserDefaults.standard.set(ChannelDict, forKey: "channels")
                UserDefaults.standard.set(ChannelIdDict, forKey: "ids")
                
                success = true
                message = "Read the channels in."
                
                return (success: success, message: message, data: ChannelDict, recordCategories)
            }
        }
    }
    
    return (success: success, message: message, data: Dictionary<String, Any>(), categories: recordCategories)
}
