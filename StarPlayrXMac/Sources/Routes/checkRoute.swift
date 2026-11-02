//
//  File.swift
//  
//
//  Created by Todd Bruss on 9/11/22.
//

import Foundation
import SwifterLite
import StarPlayrRadioKit

func checkRoute(server: HttpServer) -> httpReq {{ request in
    print("\r\n\(server.routes)\r\n")
    return HttpResponse.notFound(.none) //don't return anything
}}

