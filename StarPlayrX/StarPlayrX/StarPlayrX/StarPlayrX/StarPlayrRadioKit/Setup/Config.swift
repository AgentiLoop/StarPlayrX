import Foundation

public func Config()  {
    
    let endpoint = http + root + "/get/configuration?result-template=html5&app-region=US"
    let sources_key = "hls_sources"
    let relative_urls = "relativeUrls"
    var success = false
    
    GetAsync(endpoint: endpoint) { (config) in
        guard let config = config else { return }
        configuration(config: config)
    }
    
    func readCache() {
        if let hls = UserDefaults.standard.dictionary(forKey: sources_key ) as? Dictionary<String, String> {
            hls_sources = hls
            success = true
        }
    }
    
    /* get patterns and encrpytion keys */
    func configuration(config: NSDictionary) {
        guard
            let s = config.value( forKeyPath: "ModuleListResponse.moduleList.modules" ),
            let p = s as? NSArray, let x = p[0] as? NSDictionary,
            let customAudioInfos = x.value( forKeyPath: "moduleResponse.configuration.components" ) as? NSArray
            else { readCache(); return }
        
        for i in customAudioInfos {
            if let a = i as? NSDictionary, let name = a["name"] as? String, name == relative_urls, let streamUrls = a.value( forKeyPath: "settings.relativeUrls" ) as? NSArray, let streamRoots = (streamUrls[0]) as? NSArray {
                
                for j in streamRoots {
                    if let b = j as? NSDictionary, let streamName = b["name"] as? String, let streamUrl = b["url"] as? String {
                        hls_sources[streamName] = streamUrl
                        success = true
                    }
                }
            }
        }
        
        success ? UserDefaults.standard.set(hls_sources, forKey: sources_key ) : readCache()
    }
}
