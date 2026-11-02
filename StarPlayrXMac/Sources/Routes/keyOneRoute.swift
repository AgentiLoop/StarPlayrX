//
//  keyOneRoute.swift
//  StarPlayrRadioApp
//
//  Created by Todd Bruss on 9/5/22.
//  Modified by Todd Bruss on 11/2/26.
//  Copyright © 2022 Todd Bruss. All rights reserved.
//

import Foundation

func keyOneRoute() -> httpReq {{ request in
    guard let data = Data(base64Encoded: userX.key) else {
        return HttpResponse.notFound(.none)
    }
    
    return HttpResponse.ok(.data(data, contentType: "application/octet-stream"))
}}
