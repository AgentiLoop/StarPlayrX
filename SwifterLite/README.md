![Platform](https://img.shields.io/badge/Platform-iOS%20macOS%20tvOS-4BC51D.svg?style=flat)
![Swift](https://img.shields.io/badge/Swift-5.6-4BC51D.svg?style=flat)
![Protocols](https://img.shields.io/badge/Protocols-HTTP%201.1-4BC51D.svg?style=flat)

### What is SwifterLite?

Unofficial fork of Swifter written in [Swift](https://developer.apple.com/swift/) programming language, designed to be an embedded REST API server for iOS macOS and tvOS. This fork focuses on speed and reliability with the ability to stream audio and video seamlessly on or to any Apple device. SwifterLite can also become a REST api middleware and use it as an abstraction layer making it easier to update the middleware instead if your main app. 

Supports data, json, ping (text), bytes, audio and video streaming over HLS, over HTTP 1.1 protocol via http://localhost, ipv4 tcp ip

SwifterLite is used in StarPlayrX and future IPTVee works by AgentiLoop. This library uses a subset of features available in Swifter. Please do not attempt to merge it into http/Swifter as there are many changes and some pieces will not be available. SwifterLite is approximately 50% the size of the original Swifter repo. 

SwifterLite is one of the most reliable server side swift frameworks to date. It is also lean & mean. If you want https compability, you can easily combine it with nginx and cloudflare https.

### Branches
`mustang`

#### To Do REST API examples to be expanded


### Swift Package Manager
```swift
import PackageDescription

let package = Package(
    name: "YourServerName",
    products: [
        .library(
            name: "YourServerName",
            targets: ["YourServerName"]),
    ],
    dependencies: [
        .package(url: "https://github.com/StarPlayrX/SwifterLite", branch: "mustang")
    ],
    targets: [
        .target(
            name: "YourServerName",
            dependencies: [.product(name: "SwifterLite", package: "SwifterLite")]
        ),
    ]
)
```

### import SwifterLite
```swift
import SwifterLite
```

### How to start server with 1 route and select its port
```swift
let server = HttpServer()
server.get["/api/v3/ping"] = { request in
    return HttpResponse.ok(.ping("pong"))
}
let port = 8080
try? server.start(port)
```

### Data Route
```swift
func dataRoute(_ data: Data) -> httpReq {{ request in
    return HttpResponse.ok(.data(data, contentType: "application/octet-stream"))
}}

let data = Data("commanderData".utf8)
server.get["/commander/data"] = dataRoute(data: data)
```

For more examples please see StarPlayrRadioKit which uses SwifterLite
