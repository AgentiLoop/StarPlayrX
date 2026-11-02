//
//  TypeAliases.swift
//  
//
//  Created by Todd Bruss on 9/26/22.
//  Modified by Todd Bruss on 11/2/26.
//

import Foundation

public typealias httpReq = ((HttpRequest) -> HttpResponse)
public typealias dispatchHttpReq = ([String: String], (HttpRequest) -> HttpResponse)
public typealias httpWriter = (Int, ((HttpResponseBodyWriter) throws -> Void)?)
