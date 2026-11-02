import Foundation

//MARK: GetAsync
internal func GetAsync(endpoint: String, DictionaryHandler: @escaping DictionaryHandler) {
    
    guard let url = URL(string: endpoint) else { DictionaryHandler(.none); return}
    
    var urlReq = URLRequest(url: url)
    urlReq.httpMethod = "GET"
    urlReq.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    urlReq.addValue("application/json", forHTTPHeaderField: "Content-Type")
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

//MARK: - GetPdtAsyc
public func GetPdtSync(endpoint: String, method: String, PdtHandler: @escaping PdtHandler) {

    guard let url = URL(string: endpoint) else { PdtHandler(nil); return }
    
    let semaphore = DispatchSemaphore(value: 0)
    let decoder = JSONDecoder()
    
    var urlReq = URLRequest(url: url)
    urlReq.httpMethod = "GET"
    urlReq.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    urlReq.addValue("application/json", forHTTPHeaderField: "Content-Type")
    urlReq.timeoutInterval = TimeInterval(60)
    
    let task = URLSession.shared.dataTask(with: urlReq ) { ( data, response, error ) in

        if let data = data {
            do { let pdtData = try decoder.decode(DiscoverChannelList.self, from: data)
                
                PdtHandler(pdtData)
            } catch {
                PdtHandler(nil)
                print("1")
                print(error)
            }
        }
        
        //MARK - for Sync
        semaphore.signal()
    }
    
    task.resume()
    _ = semaphore.wait(timeout: .distantFuture)
}

