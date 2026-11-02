// This file was generated from JSON Schema using quicktype, do not modify it directly.
// To parse the JSON, add this file to your project and do:
//

// CutContentType has been removed because parsing it is too unpredictable and we are currently not using it

import Foundation

// MARK: - DiscoverChannelList
public struct DiscoverChannelList: Codable {
    var moduleListResponse: ModuleListResponse?
    
    enum CodingKeys: String, CodingKey {
        case moduleListResponse = "ModuleListResponse"
    }
}

// MARK: - ModuleListResponse
struct ModuleListResponse: Codable {
    var messages: [Message]?
    var status: Int?
    var moduleList: ModuleList?
}

// MARK: - Message
struct Message: Codable {
    var code: Int?
    var message: String?
}

// MARK: - ModuleList
struct ModuleList: Codable {
    var modules: [Module]?
}

// MARK: - Module
struct Module: Codable {
    var moduleResponse: ModuleResponse?
}

// MARK: - ModuleResponse
struct ModuleResponse: Codable {
    var moduleDetails: ModuleDetails?
}

// MARK: - ModuleDetails
struct ModuleDetails: Codable {
    var liveChannelResponse: ModuleDetailsLiveChannelResponse?
}

// MARK: - ModuleDetailsLiveChannelResponse
struct ModuleDetailsLiveChannelResponse: Codable {
    var liveChannelResponses: [LiveChannelResponseElement]?
}

// MARK: - LiveChannelResponseElement
struct LiveChannelResponseElement: Codable {
    var channelID: String?
    var markerLists: [MarkerList]?
    
    enum CodingKeys: String, CodingKey {
        case channelID = "channelId"
        case markerLists
    }
}

// MARK: - MarkerList
struct MarkerList: Codable {
    var layer: Layer?
    var markers: [Marker]?
}

enum Layer: String, Codable {
    case cut = "cut"
    case episode = "episode"
}

// MARK: - Marker
struct Marker: Codable {
    var assetGUID, consumptionInfo: String?
    var layer: Layer?
    var time: Int?
    var timestamp: Timestamp?
    var containerGUID: String?
    var liveGame: Bool?
    var cut: Cut?
    var duration: Double?
    var episode: Episode?
}

// MARK: - Cut
struct Cut: Codable {
    var legacyIDS: LegacyIDS?
    var title: String?
    var artists: [Artist]?
    var album: Album?
    var clipGUID, galaxyAssetID: String?
    var memberOfSpotBlock: Bool?
    var mref: String?
    var externalIDS: [ExternalID]?
    var spotBlockID: String?
    var firstCutOfSpotBlock: Bool?
    var contentInfo: String?
    
    enum CodingKeys: String, CodingKey {
        case legacyIDS = "legacyIds"
        case title, artists, album, clipGUID
        case galaxyAssetID = "galaxyAssetId"
        case memberOfSpotBlock, mref
        case externalIDS = "externalIds"
        case spotBlockID = "spotBlockId"
        case firstCutOfSpotBlock, contentInfo
    }
}

// MARK: - Album
struct Album: Codable {
    var title: String?
}

// MARK: - Artist
struct Artist: Codable {
    var name: String?
}

// MARK: - ExternalID
struct ExternalID: Codable {
    var id: ID?
    var value: String?
}

enum ID: String, Codable {
    case iTunes = "iTunes"
}

// MARK: - LegacyIDS
struct LegacyIDS: Codable {
    var siriusXMID, pid: String?
    
    enum CodingKeys: String, CodingKey {
        case siriusXMID = "siriusXMId"
        case pid
    }
}

// MARK: - Episode
struct Episode: Codable {
    var isLiveVideoEligible: Bool?
}

// MARK: - Timestamp
struct Timestamp: Codable {
    var absolute: String?
}
