//
//  HttpRespBodyWriter.swift
//  Swifter
//
//  Copyright (c) 2014-2016 Damian Kołakowski. All rights reserved.
//
//  SwifterLite
//  Copyright (c) 2022 Todd Bruss. All rights reserved.
//

import Foundation

public enum HttpResponse {
    case ok(HttpResponseBody, [String: String] = [:])
    case notFound(HttpResponseBody? = nil)
    
    public var statusCode: Int {
        switch self {
        case .ok                      : return 200
        case .notFound                : return 404
        }
    }
    
    public var reasonPhrase: String {
        switch self {
        case .ok                       : return "OK"
        case .notFound                 : return "Not Found"
        }
    }
    
    public func headers() -> [String: String] {
        var headers = ["Server": "SwifterLite \(HttpServer.version)"]
        switch self {
        case .ok(let body, let customHeaders):
            for (key, value) in customHeaders {
                headers.updateValue(value, forKey: key)
            }
            switch body {
            case .json(_, let contentType): headers["Content-Type"] = contentType
            case .ping(_, let contentType): headers["Content-Type"] = contentType
            case .data(_, let contentType): headers["Content-Type"] = contentType
            case .byts(_, let contentType): headers["Content-Type"] = contentType
            }
        case .notFound(_):
            ()
        }
        return headers
    }
    
    func content() -> (length: Int, write: ((HttpResponseBodyWriter) throws -> Void)?) {
        switch self {
        case .ok(let body, _)          : return body.content()
        case .notFound(let body)       : return body?.content() ?? (-1, nil)
        }
    }
}
