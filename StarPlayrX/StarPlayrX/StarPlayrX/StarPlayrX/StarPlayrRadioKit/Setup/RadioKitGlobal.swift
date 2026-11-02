//
//  RadioKitGlobal.swift
//  StarPlayrX
//
//  Created by Todd Bruss on 11/2/26.
//  Modified by Todd Bruss on 11/2/26.
//  Copyright © 2026 Todd Bruss. All rights reserved.
//

import Foundation

//source
public var usePrime: Bool = false
public let http: String = "https://"

public var root: String = "player.siriusxm.com/rest/v2/experience/modules"
public var playerDomain = "player.siriusxm.com"
public var userAgent = "Mozilla/5.0 (Macintosh; Intel Mac OS X 10_15_7) AppleWebKit/605.1.15 (KHTML, like Gecko) Version/27.0.1 Safari/605.1.15"
public var appRegion = "US"
/// Serve live playlists with their real segment durations, so AVPlayerItem.currentDate() is the
/// stream's true EXT-X-PROGRAM-DATE-TIME (the Mac app matches it against the cut timeline).
public var realSegmentDurations = false
/// The Mac app's spectrum bars: each live playlist, and each audio segment (still encrypted, with
/// its AES key), as the server hands them to the player, so the bars are worked out before playback.
public var livePlaylistObserver: ((_ playlist: String) -> Void)?
public var liveSegmentObserver: ((_ name: String, _ data: Data, _ key: Data?) -> Void)?

public var hls_sources = Dictionary<String, String>()

internal var MemBase = Dictionary<String?, String?>()
public let audioFormat = "audio/aac"

public typealias LoginData = ( email:String, pass:String, channels:  Dictionary<String, Any>,
    ids:  Dictionary<String, Any>, channel: String, token: String, loggedin: Bool,  gupid: String, consumer: String, key: String, keyurl: String )
public var userX = ( email:"", pass:"", channels: [:], ids: [:], channel: "", token: "", loggedin: false, gupid: "", consumer: "", key: "", keyurl: "" ) as LoginData

public typealias RadioKitPostReturnTuple = (message: String, success: Bool, data: Dictionary<String, Any>, response: HTTPURLResponse? )

//Completion Handlers
public typealias PostTupleHandler  = (_ tuple:RadioKitPostReturnTuple?) 	   -> Void
public typealias PdtHandler        = (_ struct:DiscoverChannelList?)  -> Void
public typealias LiveHandler 		= (_ struct:NowPlayingLiveStruct?) -> Void

