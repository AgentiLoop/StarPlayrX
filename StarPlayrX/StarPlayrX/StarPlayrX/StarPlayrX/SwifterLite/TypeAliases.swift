//
//  TypeAliases.swift
//  
//
//  Created by Todd Bruss on 9/26/22.
//

import Foundation

public typealias httpReq = ((HttpRequest) -> HttpResponse)
public typealias dispatchHttpReq = ([String: String], (HttpRequest) -> HttpResponse)
public typealias httpWriter = (Int, ((HttpResponseBodyWriter) throws -> Void)?)
