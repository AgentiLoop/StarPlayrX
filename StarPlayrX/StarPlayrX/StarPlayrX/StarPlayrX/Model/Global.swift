//
//  Global.swift
//  StarPlayr
//
//  Created by Todd on 1/26/19.
//  Modified by Todd Bruss on 5/18/25.
//  Copyright © 2019 Todd Bruss. All rights reserved.
//

import Foundation
import UIKit


internal class Global  {
    static let obj = Global()
    
	//MARK: Constants
    let local = "127.0.0.1"
    let localhost = "localhost"
    let domain = "starplayrx.com"
    let secureport = "443"
    let binbytes = "19008675309"
    let websitedown = "403"
    let secure = "https://"
    let insecure = "http://"
    let m3u8 = ".m3u8"
    let Server = "boss"
    let voiceOverQueue = "VoiceOverQueue"

    //MARK: Variables
    var imagechecksum = ""
    var Username = ""
    var Password = ""
    var localeIsCA = true
    var lastCategory = "Init Cat"
    var categoryTitle = ""
    var currentChannel = "0"
    var lastchannel = ""
    var currentChannelName = ""
    var userid : String? = ""
    
    internal var tabBarHeight = CGFloat(65.0)
    internal var navBarWidth = CGFloat(375.0)

    internal var PopularCategories  = Array<String>()
    internal var MusicCategories    = Array<String>()
    internal var TalkCategories     = Array<String>()
    internal var SportsCategories   = Array<String>()
    internal var MiscCategories     = Array<String>()
    
    internal var ChannelList : Dictionary? = Dictionary<String, Any>()
    internal var ChannelData : Dictionary? = Dictionary<String, Data>()
    internal var ChannelArray = tableData()
    internal var FilterData 		: tableData? = tableData()
    internal var ColdFilteredData 	: tableData? = tableData()
    
    internal var NowPlaying = (channel:"",artist:"",song:"",albumArt:"",channelArt:"", image: nil ) as NowPlayingType

    internal var SelectedRow : IndexPath? = nil
    internal var SearchText = ""
}

//MARK: TypeAliases
typealias NowPlayingType = (channel:String,artist:String,song:String,albumArt:String,channelArt:String, image: UIImage?)

typealias tableData = [(searchString:String,name:String,channel:String,title:NSMutableAttributedString,detail:NSMutableAttributedString, image:UIImage, channelImage:UIImage, albumUrl:String, largeAlbumUrl: String, largeChannelArtUrl: String, category:String, preset: Bool)]

//Completion Handlers
typealias CompletionHandler 	= (_ success:Bool) -> Void
typealias ImageHandler 			= (_ image:UIImage?) -> Void
typealias TupleHandler 			= (_ tuple:PostReturnTuple?) -> Void
typealias DictionaryHandler 	= (_ dict:NSDictionary?) -> Void
typealias DataHandler 			= (_ data:Data?) -> Void
typealias TextHandler 			= (_ text:String?) -> Void

typealias PostReturnTuple = (message: String, success: Bool, data: NSDictionary? , response: HTTPURLResponse? )

//MARK: Eums
enum PlayerState {
    case playing
    case paused
    case buffering
    case interrupted
    case stream
    case unknown
}

enum Speakers : String {
    case speaker0  = "speaker0"
    case speaker1  = "speaker1"
    case speaker2  = "speaker2"
    case speaker3  = "speaker3"
    case speaker4  = "speaker4"
    case speaker5  = "speaker5"
    case speaker6  = "speaker6"
    case speaker7  = "speaker7"
    case speaker8  = "speaker8"
    case speaker9  = "speaker9"
    case speaker10 = "speaker10"
}

let net = Network.ability
var isMacCatalystApp = false
