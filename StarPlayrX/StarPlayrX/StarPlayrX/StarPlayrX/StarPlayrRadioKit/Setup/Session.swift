//
//  Cookies.swift
//  Camouflage
//
//  Created by Todd Bruss on 1/20/19.
//

import Foundation

@discardableResult
public func Session(channelid: String, updateToken: Bool, updateUser: Bool) -> String {
    var channelLineUpId = "350" //default to large channel and image set

    let timeInterval = NSDate().timeIntervalSince1970
    let convert = timeInterval * 1000 as NSNumber
    let intTime = Int(truncating: convert)
    let time = String(intTime)

    let endpoint = http + root + "/resume?channelId=" + channelid + "&contentType=live&timestamp=" + time + "&cacheBuster=" + time
    let request =
        ["moduleList":
            ["modules":
                [
                    ["moduleRequest":
                        ["resultTemplate": "web", "deviceInfo":
                            ["osVersion": "Mac",
                             "platform": "Web",
                             "clientDeviceType": "web",
                             "sxmAppVersion": "3.1802.10011.0",
                             "browser": "Safari",
                             "browserVersion": "11.0.3",
                             "appRegion": appRegion,
                             "deviceModel": "K2WebClient",
                             "player": "html5",
                             "clientDeviceId": "null"
                            ]
                        ]
                    ]
                ]
            ]
        ] as Dictionary
    
    guard let url = URL(string: endpoint) else { return "305" }

    //MARK: - for Sync
    let semaphore = DispatchSemaphore(value: 0)
    
    var urlReq = URLRequest(url: url)
    urlReq.httpBody = try? JSONSerialization.data(withJSONObject: request, options: .prettyPrinted)
    urlReq.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    urlReq.addValue("application/json", forHTTPHeaderField: "Content-Type")
    urlReq.httpMethod = "POST"
   // urlReq.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_14_2) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/12.0.2 Safari/605.1.15", forHTTPHeaderField: "User-Agent")
    urlReq.timeoutInterval = TimeInterval(60)
    
    let task = URLSession.shared.dataTask(with: urlReq ) { ( data, resp, error ) in
    
        if let r = resp as? HTTPURLResponse, let d = data {
            if r.statusCode == 200 {
                do { let result =
                    try JSONSerialization.jsonObject(with: d, options: JSONSerialization.ReadingOptions.mutableContainers) as? [String : Any]
                    
                    let getCookies = { () -> [HTTPCookie] in
                        
                    	 if let fields = r.allHeaderFields as? [String : String], let url = r.url {
                    	    let cookies = HTTPCookie.cookies(withResponseHeaderFields: fields, for: url)
                    	    HTTPCookieStorage.shared.setCookies(cookies, for: url, mainDocumentURL: URL(string:http + root))
                            return(cookies)
                    	}
                        
                        return [HTTPCookie()]
                    }
                    
                    if updateToken {
                        let cookies = getCookies()

                        for cookie in cookies {
                            //This token changes on every pull and expires in about 480 seconds or less
                            if cookie.name == "SXMAKTOKEN" {
                                let t = cookie.value as String
                                if t.count > 44 {
                                    let startIndex = t.index(t.startIndex, offsetBy: 3)
                                    let endIndex = t.index(t.startIndex, offsetBy: 45)
                                    
                                    userX.token = String(t[startIndex...endIndex])
                                    
                                    UserDefaults.standard.set(userX.token, forKey: "token")
                                    
                                    break
                                }
                            }
                        }
                    }
                   
                    if updateUser {
                        let dict = result as NSDictionary?
                        /* get patterns and encrpytion keys */
                        let s = dict?.value( forKeyPath: "ModuleListResponse.moduleList.modules" )
                        let p = s as? NSArray
                        let x = p?.firstObject as? NSDictionary
                        
                        //New return the channel lineup Id
                        if let cid = x?.value( forKeyPath: "clientConfiguration.channelLineupId" ) as? String {
                            channelLineUpId = String(cid)
                        }
                        
                        if let customAudioInfos = x?.value( forKeyPath: "moduleResponse.liveChannelData.customAudioInfos" ) as? NSArray,
                           let c = customAudioInfos[0] as? NSDictionary,
                           let chunk = c.value( forKeyPath: "chunks.chunks") as? NSArray,
                           let d = chunk[0] as? NSDictionary,
                           let key = d.value( forKeyPath: "key") as? String,
                           let keyurl = d.value( forKeyPath: "keyUrl") as? String,
                           let consumer = x?.value( forKeyPath: "moduleResponse.liveChannelData.hlsConsumptionInfo" ) as? String {
                           
                            userX.key = key
                            userX.keyurl = keyurl
                            userX.consumer = consumer
                        
                            UserDefaults.standard.set(userX.key, forKey: "key")
                            UserDefaults.standard.set(userX.keyurl, forKey: "keyurl")
                            UserDefaults.standard.set(userX.consumer, forKey: "consumer")
                        }
                    }
                } catch {
                    print("Session:", error)
                }
            }
        }
        
        //MARK - for Sync
        semaphore.signal()
    }
    
    task.resume()
    _ = semaphore.wait(timeout: .distantFuture)
        
    return String(channelLineUpId)
}
