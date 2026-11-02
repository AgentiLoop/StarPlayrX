//
//  nowPlayingLive.swift
//  COpenSSL
//
//  Created by Todd Bruss on 4/5/20.
//  Modified by Todd Bruss on 11/2/26.
//

import Foundation

//MARK: After
public func nowPlayingLiveAsync(endpoint: String, LiveHandler: @escaping LiveHandler) {
    guard let url = URL(string: endpoint) else { LiveHandler(.none); return }
    let decoder = JSONDecoder()
    var urlReq = URLRequest(url: url)
    urlReq.httpMethod = "GET"
    urlReq.setValue(userAgent, forHTTPHeaderField: "User-Agent")
    urlReq.addValue("application/json", forHTTPHeaderField: "Content-Type")
    urlReq.timeoutInterval = TimeInterval(60)
    
    let task = URLSession.shared.dataTask(with: urlReq ) { data, r, e  in
        guard let data = data else { LiveHandler(.none); return }
        do { let nowPlayingLive = try decoder.decode(NowPlayingLiveStruct.self, from: data)
            LiveHandler(nowPlayingLive)
            
        } catch {
            //print(error) [ Talk stations are producing an error, no data ]
            LiveHandler(.none)
        }
    }
    
    task.resume()
}

public func nowPlayingLive(channelid: String) -> String {
    
    let timeInterval = Date().timeIntervalSince1970
    let convert = timeInterval * 1000000 as NSNumber
    let intTime = Int(truncating: convert) / 1000
    let time = String(intTime)
    let endpoint = "https://\(playerDomain)/rest/v4/experience/modules/tune/now-playing-live?channelId=\(channelid)&hls_output_mode=none&marker_mode=all_separate_cue_points&ccRequestType=AUDIO_VIDEO&result-template=web&time=" + time
    
    return endpoint
}

public func processNPL(data: NowPlayingLiveStruct) {
    autoreleasepool {
        guard
            let markers = data.moduleListResponse.moduleList.modules.first?.moduleResponse.liveChannelData.markerLists
        else {
            return
        }
        
        MemBase = [:]
        
        for m in markers {
            
            for i in m.markers {
                let cut = i.cut
                
                if let artist = cut?.artists.first?.name, let song = cut?.title, let art = cut?.album?.creativeArts {

                    for albumart in art.reversed() where albumart.relativeURL.contains("_m.") {
                       
                        guard
                            let key = sha256(artist + song)
                        else {
                            return
                        }
                        
                        MemBase[key] = albumart.relativeURL.replacingOccurrences(of: "%Album_Art%", with: "http://albumart.siriusxm.com")
                    }
                }
            }
        }
    }
}

// MARK: - NowPlayingLiveStruct
public struct NowPlayingLiveStruct: Codable {
    let moduleListResponse: ModuleListResponse
    
    enum CodingKeys: String, CodingKey {
        case moduleListResponse = "ModuleListResponse"
    }
    
    
    // MARK: - ModuleListResponse
    struct ModuleListResponse: Codable {
        let messages: [Message]
        let status: Int
        let moduleList: ModuleList
    }
    
    // MARK: - Message
    struct Message: Codable {
        let code: Int
        let message: String
    }
    
    // MARK: - ModuleList
    struct ModuleList: Codable {
        let modules: [Module]
    }
    
    // MARK: - Module
    struct Module: Codable {
        let moduleResponse: ModuleResponse
        let moduleArea, moduleType: String
        let updateFrequency: Int
        let wallClockRenderTime: String
    }
    
    // MARK: - ModuleResponse
    struct ModuleResponse: Codable {
        let liveChannelData: LiveChannelData
    }
    
    // MARK: - LiveChannelData
    struct LiveChannelData: Codable {
        let channelID: String?
        let liveDelay, aodEpisodeCount: Int?
        let markerLists: [MarkerList]?
        let cuePointList: CuePointList?
        let hlsConsumptionInfo: String?
        let connectInfo: ConnectInfo?
        let inactivityTimeOut: Int?
        
        enum CodingKeys: String, CodingKey {
            case channelID = "channelId"
            case liveDelay, aodEpisodeCount, markerLists, cuePointList, hlsConsumptionInfo, connectInfo, inactivityTimeOut
        }
    }
    
    // MARK: - ConnectInfo
    struct ConnectInfo: Codable {
        let phone, email, twitter: String?
        let twitterLink: String?
        let facebook: String?
        let facebookLink: String?
    }
    
    // MARK: - CuePointList
    struct CuePointList: Codable {
        let cuePoints: [CuePoint]
    }
    
    // MARK: - CuePoint
    struct CuePoint: Codable {
        let assetGUID: String
        let layer: Layer
        let time: Int
        let timestamp: Timestamp
        let event: Event
        let markerGUID: String?
        let active: Bool?
        
        enum CodingKeys: String, CodingKey {
            case assetGUID, layer, time, timestamp, event
            case markerGUID = "markerGuid"
            case active
        }
    }
    
    enum Event: String, Codable {
        case end = "END"
        case instantaneous = "INSTANTANEOUS"
        case start = "START"
    }
    
    enum Layer: String, Codable {
        case cut = "cut"
        case episode = "episode"
        case livepoint = "livepoint"
        case segment = "segment"
        case show = "show"
    }
    
    // MARK: - Timestamp
    struct Timestamp: Codable {
        let absolute: String
    }
    
    // MARK: - MarkerList
    struct MarkerList: Codable {
        let layer: String
        let markers: [Marker]
    }
    
    // MARK: - Marker
    struct Marker: Codable {
        let assetGUID: String
        let layer: Layer
        let time: Int
        let timestamp: Timestamp
        let containerGUID: String
        let duration: Double
        let episode: Episode?
        let pandoraSegmentGUID: String?
        let segment: Segment?
        let consumptionInfo, pandoraCutGUID: String?
        let cut: Cut?
        let pivotStation: String?
        let gameInProgress: Bool?
    }
    
    // MARK: - Cut
    struct Cut: Codable {
        let legacyIDS: CutLegacyIDS
        let title: String?
        let artists: [Artist]
        let album: Album?
        let clipGUID: String?
        let galaxyAssetID: String?
        let cutContentType: CutContentType?
        let mref: String?
        let memberOfSpotBlock: Bool?
        let pandoraClipGUID, pandoraMrefGUID: String?
        let externalIDS: [ExternalID]?
        
        enum CodingKeys: String, CodingKey {
            case legacyIDS = "legacyIds"
            case title, artists, album, clipGUID
            case galaxyAssetID = "galaxyAssetId"
            case cutContentType, mref, memberOfSpotBlock
            case pandoraClipGUID = "pandoraClipGuid"
            case pandoraMrefGUID = "pandoraMrefGuid"
            case externalIDS = "externalIds"
        }
    }
    
    // MARK: - Album
    struct Album: Codable {
        let title: String?
        let creativeArts: [AlbumCreativeArt]?
    }
    
    // MARK: - AlbumCreativeArt
    struct AlbumCreativeArt: Codable {
        let url: String
        let relativeURL: String
        let size: Size
        let type: TypeEnum
        
        enum CodingKeys: String, CodingKey {
            case url
            case relativeURL = "relativeUrl"
            case size, type
        }
    }
    
    enum Size: String, Codable {
        case medium = "MEDIUM"
        case small = "SMALL"
        case thumbnail = "THUMBNAIL"
    }
    
    enum TypeEnum: String, Codable {
        case image = "IMAGE"
    }
    
    // MARK: - Artist
    struct Artist: Codable {
        let name: String
    }
    
    enum CutContentType: String, Codable {
        case exp = "Exp"
        case link = "Link"
        case song = "Song"
    }
    
    // MARK: - ExternalID
    struct ExternalID: Codable {
        let id, value: String
    }
    
    // MARK: - CutLegacyIDS
    struct CutLegacyIDS: Codable {
        let siriusXMID: String
        let pid: String?
        
        enum CodingKeys: String, CodingKey {
            case siriusXMID = "siriusXMId"
            case pid
        }
    }
    
    // MARK: - Episode
    struct Episode: Codable {
        let legacyIDS: EpisodeLegacyIDS?
        let mediumTitle, longTitle, shortDescription, longDescription: String?
        let keywords: Entities?
        let episodeGUID: String?
        let originalAirDate: String?
        let valuable: Bool?
        let show: Show?
        let hot, highlighted: Bool?
        let dmcaInfo: DMCAInfo?
        let entities, topics: Entities?
        let live, episodeRepeat: Bool?
        let dataSiftFilterName: String?
        let featuredTweetCoordinate: FeaturedTweetCoordinate?
        let mref, pandoraLiveEpisodeGUID: String?
        let host: [String]?
        
        enum CodingKeys: String, CodingKey {
            case legacyIDS = "legacyIds"
            case mediumTitle, longTitle, shortDescription, longDescription, keywords, episodeGUID, originalAirDate, valuable, show, hot, highlighted, dmcaInfo, entities, topics, live
            case episodeRepeat = "repeat"
            case dataSiftFilterName, featuredTweetCoordinate, mref
            case pandoraLiveEpisodeGUID = "pandoraLiveEpisodeGuid"
            case host
        }
    }
    
    // MARK: - DMCAInfo
    struct DMCAInfo: Codable {
        let maxBackSkips, maxTotalSkips, maxSkipDur: Int
        let irNavClass, playOnSelect, channelContentType: String
        let fwdSkipDur, backSkipDur, maxFwdSkips: Int
    }
    
    // MARK: - Entities
    struct Entities: Codable {
    }
    
    // MARK: - FeaturedTweetCoordinate
    struct FeaturedTweetCoordinate: Codable {
        let handle, hashtag: String
    }
    
    // MARK: - EpisodeLegacyIDS
    struct EpisodeLegacyIDS: Codable {
        let shortID: String
        
        enum CodingKeys: String, CodingKey {
            case shortID = "shortId"
        }
    }
    
    // MARK: - Show
    struct Show: Codable {
        let legacyIDS: EpisodeLegacyIDS?
        let mediumTitle, longTitle, shortDescription, longDescription: String?
        let isLiveVideoEligible: Bool?
        let guid: String
        let creativeArts: [ShowCreativeArt]?
        let showGUID: String
        let connectInfo: ConnectInfo?
        let disableRecommendations: [String]?
        let futureAirings: [FutureAiring]?
        let pandoraShowGUID, programType: String?
        let isPlaceholderShow: Bool?
        
        enum CodingKeys: String, CodingKey {
            case legacyIDS = "legacyIds"
            case mediumTitle, longTitle, shortDescription, longDescription, isLiveVideoEligible, guid, creativeArts, showGUID, connectInfo, disableRecommendations, futureAirings, pandoraShowGUID, programType, isPlaceholderShow
        }
    }
    
    // MARK: - ShowCreativeArt
    struct ShowCreativeArt: Codable {
        let name: String
        let url: String
        let relativeURL: String
        let height, width: Int
        let type: TypeEnum
        
        enum CodingKeys: String, CodingKey {
            case name, url
            case relativeURL = "relativeUrl"
            case height, width, type
        }
    }
    
    // MARK: - FutureAiring
    struct FutureAiring: Codable {
        let channelID: String
        let satelliteOnlyChannel: Bool
        let timestamp: String
        let duration: Int
        
        enum CodingKeys: String, CodingKey {
            case channelID = "channelId"
            case satelliteOnlyChannel, timestamp, duration
        }
    }
    
    // MARK: - Segment
    struct Segment: Codable {
        let legacyIDS: EpisodeLegacyIDS
        let segmentType: SegmentType
        
        enum CodingKeys: String, CodingKey {
            case legacyIDS = "legacyIds"
            case segmentType
        }
    }
    
    enum SegmentType: String, Codable {
        case soft = "SOFT"
    }
}
