//
//  Login.swift
//  Camouflage
//
//  Created by Todd on 1/20/19.
//  Modified by Todd Bruss on 11/2/26.
//

import Foundation

public func LoginX(username: String, pass: String) -> (request: Dictionary<String, Any>, endpoint: String, method: String) {
    // /rest/v2/experience/modules/modify/authentication
    let endpoint = http + root + "/modify/authentication"
    let method = "login"
    let loginReq = ["moduleList": ["modules": [["moduleRequest": ["resultTemplate": "web", "deviceInfo": ["osVersion": "Mac", "platform": "Web", "sxmAppVersion": "3.1802.10011.0", "browser": "Safari", "browserVersion": "27.0.1", "appRegion": "US", "deviceModel": "K2WebClient", "clientDeviceId": "3c611482-9604-4872-8994-0074e0e18e84", "player": "html5", "clientDeviceType": "web"], "standardAuth": ["username": username, "password": pass]]]]]] as Dictionary


    return (request: loginReq, endpoint: endpoint, method: method)
	
}

public func processLogin(username: String, pass: String, result: RadioKitPostReturnTuple) -> (success: Bool, message: String, data: String) {
    
    var email = ""
    var success = false
    var message = "Username or password is incorrect."
    
    if (result.response?.statusCode) == 403 {
        success = false
        message = "Too many incorrect logins, Sirius XM has blocked your IP for 24 hours."
        return (success: success, message: message, data: "")
    }
    
    if result.success {
        
        let login = { () -> (code: Int, msg: String) in
            if let r = result.data as NSDictionary?,
                let d = r.value(forKeyPath: "ModuleListResponse.messages"),
                let a = d as? NSArray,
                let cm = a[0] as? NSDictionary,
                let code = cm.value(forKeyPath: "code") as? Int,
                let msg = cm.value(forKeyPath: "message") as? String {
                
                return (code: code, msg: msg)
            } else {
                return (code: 101, msg: "Bad username/password")
            }
        }
        
        let loginRef = login() //Use Reference so this runs once not twice
        
        let code = loginRef.code
        let msg = loginRef.msg
        
        if code == 101 || msg == "Bad username/password" {
            success = false
            message = "Bad username or password."
            return (success: success, message: message, data: "")
            
        } else {
            success = true
            message = "Login successful"
            
            if  let r = result.data as NSDictionary?,
                let s = r.value(forKeyPath: "ModuleListResponse.moduleList.modules"),
                let p = s as? NSArray,
                let x = p[0] as? NSDictionary,
                let y = x.value(forKeyPath: "moduleResponse.authenticationData.username") as? String {
                
                //Get Email
                email = y
            }
            
            if let fields = result.response?.allHeaderFields as? [String : String],
                let url = result.response?.url {
                let cookies = HTTPCookie.cookies(withResponseHeaderFields: fields, for: url)
                HTTPCookieStorage.shared.setCookies(cookies, for: url, mainDocumentURL: URL(string:http + root) )
                
                //SiriusXM changed this key
                if let gupid = fields["gupid"] {
                    userX.gupid = gupid
                } else if let gupid = fields["GupId"] {
                    userX.gupid = gupid
                }
            }
        
            userX.email = email
            
            /*saveKeys for AutoLogin */
            UserDefaults.standard.set(username, forKey: "user")
            UserDefaults.standard.set(pass, forKey: "pass")
            UserDefaults.standard.set(email, forKey: "email")
            UserDefaults.standard.set(userX.gupid, forKey: "gupid")
            UserDefaults.standard.set(true, forKey: "loggedin")
            
            return (success: success, message: message, data: userX.gupid )
            
        }
    }
    
    return (success: false, message: "To err is human. We had a login failure.", data: "")
}
