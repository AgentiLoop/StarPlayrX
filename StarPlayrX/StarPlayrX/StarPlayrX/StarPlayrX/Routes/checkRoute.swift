//
//  File.swift
//  
//
//  Created by Todd Bruss on 9/11/22.
//  Modified by Todd Bruss on 11/2/26.
//  Copyright © 2022 Todd Bruss. All rights reserved.
//

import Foundation

func checkRoute(server: HttpServer) -> httpReq {{ request in
    print("\r\n\(server.routes)\r\n")
    return HttpResponse.notFound(.none) //don't return anything
}}

