//
//  Async.swift
//  StarPlayrX
//
//  Created by Todd Bruss on 5/7/20.
//  Copyright © 2020 Todd Bruss. All rights reserved.
//

import Foundation
import UIKit

//MARK: Async
internal class Async {
    static let api = Async()
    
    let g = Global.obj
    
    //MARK: Data
    internal func CommanderData(endpoint: String, method: String, DataHandler: @escaping DataHandler )  {
        guard let url = URL(string: endpoint) else { DataHandler(.none); return}
        
        var urlReq = URLRequest(url: url)
        urlReq.httpMethod = "GET"
        urlReq.timeoutInterval = TimeInterval(60)
        urlReq.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        
        let task = URLSession.shared.dataTask(with: urlReq ) { ( data, _, _ ) in
            
            guard
                let d = data
            else {
                DataHandler(.none); return
            }
           
            DataHandler(d)
        }
        
        task.resume()
    }

	//MARK: Text
    internal func Text(endpoint: String, timeOut: Double = 5, TextHandler: @escaping TextHandler) {
        
        
        guard let url = URL(string: endpoint) else { TextHandler("error"); return}
        
        var urlReq = URLRequest(url: url)
        urlReq.httpMethod = "GET"
        urlReq.timeoutInterval = TimeInterval(timeOut)
        urlReq.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        
        let task = URLSession.shared.dataTask(with: urlReq ) { ( data, _, _ ) in
            
            guard
                let d = data,
                let text = String(data: d, encoding: .utf8)
            else {
                TextHandler("error"); return
            }
            
            TextHandler(text)
        }
        
        task.resume()
    }
    
    //MARK: Get
    internal func Get(endpoint: String, DictionaryHandler: @escaping DictionaryHandler)  {
        guard let url = URL(string: endpoint) else { DictionaryHandler(.none); return}
        
        var urlReq = URLRequest(url: url)
        urlReq.httpMethod = "GET"
        urlReq.timeoutInterval = TimeInterval(60)
        urlReq.cachePolicy = .reloadIgnoringLocalAndRemoteCacheData
        
        let task = URLSession.shared.dataTask(with: urlReq ) { ( returndata, response, _ ) in
            if let r = returndata {
                let dict = try? JSONSerialization.jsonObject(with: r, options: JSONSerialization.ReadingOptions.mutableContainers) as? NSDictionary
                DictionaryHandler(dict)
            } else {
                DictionaryHandler(nil)
            }
        }
        
        task.resume()
    }
    
    //MARK: Post
    internal func Post(request: Dictionary<String, Any>, endpoint: String, method: String, TupleHandler: @escaping TupleHandler ) {
        guard let url = URL(string: endpoint) else { TupleHandler(.none); return }

        var urlReq = URLRequest(url: url)
        urlReq.httpBody = try? JSONSerialization.data(withJSONObject: request, options: .prettyPrinted)
        let userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/27.0.1 Safari/605.1.15"
        urlReq.setValue(userAgent, forHTTPHeaderField: "User-Agent")
        urlReq.addValue("application/json", forHTTPHeaderField: "Content-Type")
        urlReq.httpMethod = "POST"
        urlReq.timeoutInterval = TimeInterval(60)
        //urlReq.setValue("Mozilla/5.0 (Macintosh; Intel Mac OS X 10_14_2) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/12.0.2 Safari/605.1.15", forHTTPHeaderField: "User-Agent")

      
        let task = URLSession.shared.dataTask(with: urlReq ) { ( returndata, resp, error ) in
            
            guard let rdata = returndata else { TupleHandler( (message: method + " was failed.", success: false, data: Data(), response: resp as? HTTPURLResponse ) as? PostReturnTuple ); return }
                
                let result = try? JSONSerialization.jsonObject(with: rdata, options: JSONSerialization.ReadingOptions.mutableContainers) as? NSDictionary
                            
                if method == "channels" {
                    var localCats = Array<String>()
                    
                    if let cats = result?["categories"] as? Array<String> {
                        localCats = cats
                        localCats = localCats.sorted()
                    }
                    
                    let Popular: Array<String> = [Player.shared.allStars,Player.shared.everything]
                    var sportsTalk : Array<String> = ["Sports Talk"]
                    var musicArray : Array<String> = ["Pop","Rock","Hip-Hop/R&B"]
                    var talkArray = Array<String>()
                    var miscArray = Array<String>()
                    
                    if !localCats.isEmpty {
                        for i in 0..<localCats.count {
                            
                            switch localCats[i] {
                                case "Rock","Pop","Sports Talk","Hip-Hop/R&B":
                                    ()
                                
                                case "Dance/Electronic","Country","Jazz","Punk","Oldies","Family","Christian","Classical","Metal","Alternative","Artists":
                                    //add to musicArray
                                    musicArray.append(localCats[i])
                                
                                case "More Talk","Canada Talk","Canada Music", "Latin Music", "Latin Talk":
                                    miscArray.append(localCats[i])
                                
                                case "Comedy","Entertainment","Howard Stern","News/Public Radio","Politics/Issues", "Religion":
                                    talkArray.append(localCats[i])
                                
                                case "MLB","NBA","NFL","NHL","Play-by-Play":
                                    sportsTalk.append(localCats[i])
                                
                                default:
                                    //default to music as a catch all
                                    musicArray.append(localCats[i])
                            }
                        }
                    }
                    
                    if !Popular.isEmpty {
                        self.g.PopularCategories = Popular
                    }
                    
                    if !sportsTalk.isEmpty {
                        self.g.SportsCategories = sportsTalk
                    }
                    
                    if !musicArray.isEmpty {
                        self.g.MusicCategories = musicArray
                    }
                    
                    if !talkArray.isEmpty {
                        self.g.TalkCategories = talkArray
                    }
                    
                    if !miscArray.isEmpty {
                        self.g.MiscCategories = miscArray
                    }
                }
                TupleHandler( (message: method + " was successful.", success: true, data: result, response: resp as? HTTPURLResponse ) as PostReturnTuple )
        }
        task.resume()
    }
    
    //MARK: Imagineer
    internal func Imagineer(endpoint: String, ImageHandler: @escaping ImageHandler ) {
        guard let url = URL(string: endpoint) else { ImageHandler(.none); return }
        
        var urlReq = URLRequest(url: url)
        urlReq.httpMethod = "GET"
        urlReq.timeoutInterval = TimeInterval(60)
        urlReq.cachePolicy = .returnCacheDataElseLoad
        
        let task = URLSession.shared.dataTask(with: urlReq ) { ( data, _, _ ) in
            
            guard
                let d = data
            else {
                ImageHandler(.none); return
            }
            
            ImageHandler(UIImage(data: d))
        }
        
        task.resume()
    }    
}
