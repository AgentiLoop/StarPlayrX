//
//  PlayStream.swift
//  StarPlayr
//
//  Created by Todd on 3/1/19.
//  Copyright © 2019 Todd Bruss. All rights reserved.
//

import Foundation
import MediaPlayer
import UIKit

final class Player {
    static let shared = Player()
    
    let g = Global.obj
    let pdt = Global.obj.NowPlaying
    
    public let PlayerQueue = DispatchQueue(label: "PlayerQueue", qos: .userInitiated )
    public let PDTqueue = DispatchQueue(label: "PDT", qos: .userInteractive, attributes: .concurrent)
    
    var player = AVQueuePlayer()
    var port: UInt16 = 9999
    var everything = "All Channels"
    var allStars = "All Stars"
    var SPXPresets = [String]()
    var pdtCache = [String : Any]()
    var localChannelArt = ""
    var localAlbumArt = ""
    var preArtistSong = ""
    var setAlbumArt = false
    var maxAlbumAttempts = 3
    var state : PlayerState? = nil
    
    func resetAirPlayVolumeX() {
        if avSession.currentRoute.outputs.first?.portType == .airPlay {
            DispatchQueue.main.async {
                //AP2Volume.shared()?.setVolumeBy(0.0)
            }
        }
    }
    
    func spx(_ state: PlayerState?) {
        if state == .stream {
            if isMacCatalystApp {
                self.resetPlayer()
            }
            self.play()
            self.state = .buffering
        } else if player.rate == 1 || self.state == .playing {
            self.pause()
            self.state = .paused
        } else {
            self.play()
            self.state = .buffering
        }
    }
    
    func new(_ state: PlayerState?) {
        DispatchQueue.global().async { [self] in
            let pinpoint = "\(g.insecure)\(g.localhost):\(port)/api/v3/ping"
            Async.api.Text(endpoint: pinpoint, timeOut: 1 ) { [self] pong in
                guard let ping = pong else { launchServer(); return }
                ping == "pong" ? spx(state) : ( launchServer() )
            }
        }
      
    }
    
    //MARK: Update the screen
    func syncArt() {
        
        if let sha256 = sha256(String(CACurrentMediaTime().description)) {
            self.previousHash = sha256
        } else {
            let str = "Hello, Last Star Player X."
            self.previousHash = sha256(String(str)) ?? str
        }
        
        if let i = g.ChannelArray.firstIndex(where: {$0.channel == g.currentChannel}) {
            let item = g.ChannelArray[i].largeChannelArtUrl
            self.updateDisplay(key: g.currentChannel, cache: self.pdtCache, channelArt: item, false)
        }
    }
    
    //MARK: Launch Server and Stream
    func launchServer() {
        autoLaunchServer(){ success in
            success ? play() : stop()
        }
    }
    
    //MARK: Stop the player, we have an issue - this could show an interruption
    func stop() {
        self.player.pause()
        self.state = .paused
        NotificationCenter.default.post(name: .didUpdatePause, object: nil)
        self.resetPlayer()
        self.player = AVQueuePlayer()
    }
    
    func stream() {
        SPXCache()
        state = .playing
        NotificationCenter.default.post(name: .didUpdatePlay, object: nil)
        
        guard
            let url = URL(string: "\(g.insecure)\(g.localhost):\(port)/api/v3/m3u/\(g.currentChannel)\(g.m3u8)")
        else {
            return
        }
        
        let p = self.player
        p.volume = 0
        p.replaceCurrentItem(with: AVPlayerItem(asset:AVAsset(url: url)))
        
        print("stream and set session to active")
        try? avSession.setActive(true)
        
        p.playImmediately(atRate: 1.0)
        
        p.fadeVolume(from: 0, to: 1, duration: Float(2.5))
      
//        var spx = false

//        for i in 0...20 {
//            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i / 2)) { [self] in
//                if p.rate == 1 && !spx {
//
//                    NotificationCenter.default.post(name: .didUpdatePlay, object: nil)
//                    spx.toggle()
//                }
//            }
//
//            DispatchQueue.main.asyncAfter(deadline: .now() + Double(i / 2)) {
//                if p.rate == 1 { return }
//
//                if p.rate < 1 {
//                    p.playImmediately(atRate: 1.0)
//                }
//
//                if i >= 5 && p.volume < 1 {
//                    p.fadeVolume(from: p.volume, to: 1, duration: Float(0.5))
//                }
//            }
//        }
    }
    
    func play() {
        let p = self.player
        let currentItem = p.currentItem
        
        var wait = 0.25
        if currentItem == nil {
            wait = 0
        }
        
        p.fadeVolume(from: 1, to: 0, duration: Float(wait))
        state = .buffering
        
        p.currentItem?.automaticallyPreservesTimeOffsetFromLive = true
        p.currentItem?.preferredForwardBufferDuration = 0
        p.currentItem?.canUseNetworkResourcesForLiveStreamingWhilePaused = true
        p.automaticallyWaitsToMinimizeStalling = true
        p.appliesMediaSelectionCriteriaAutomatically = true
        p.allowsExternalPlayback = true
        
        DispatchQueue.main.asyncAfter(deadline: .now() + avSession.outputLatency * 2.0) { [weak self] in
            self?.player.currentItem?.preferredForwardBufferDuration = 1
        }
        
        DispatchQueue.main.asyncAfter(deadline: .now() + Double(wait)) {
            self.stream()
        }
    }
    
    func change() {
        let p = self.player
        
        p.currentItem?.preferredForwardBufferDuration = 0
        p.currentItem?.automaticallyPreservesTimeOffsetFromLive = true
        p.currentItem?.canUseNetworkResourcesForLiveStreamingWhilePaused = true
        p.automaticallyWaitsToMinimizeStalling = true
        p.appliesMediaSelectionCriteriaAutomatically = true
        p.allowsExternalPlayback = true
        
        DispatchQueue.main.asyncAfter(deadline: .now() + avSession.outputLatency * 2.0) { [weak self] in
            self?.player.currentItem?.preferredForwardBufferDuration = 1
        }
    }
    
    func runReset(starplayrx: AVPlayerItem) {
        player.replaceCurrentItem(with: nil)
        starplayrx.asset.cancelLoading()
        player.remove(starplayrx)
    }
    
    func resetPlayer() {
        for starplayrx in player.items() {
            runReset(starplayrx: starplayrx)
        }
    }
    
    func pause() {
        self.player.pause()
        self.state = .paused
        NotificationCenter.default.post(name: .didUpdatePause, object: nil)
        self.resetPlayer()
        self.player = AVQueuePlayer()
    }
    
    var previousHash = "reset"
    
    //MARK: Update our display
    func updateDisplay(key: String, cache: [String : Any], channelArt: String, _ animated: Bool = true) {
        if let value  = cache[key] as? [String: String],
           let artist = value["artist"] as String?,
           let song   = value["song"] as String?,
           let image  = value["image"] as String?,
           let hash = sha256(artist + song + key + channelArt + image),
           previousHash != hash
        {
            previousHash = hash
            g.NowPlaying = (channel:key,artist:artist,song:song,albumArt:image,channelArt:channelArt, image: nil ) as NowPlayingType
            updateNowPlayingX(animated)
        }
    }
    
    public func chooseFilter(fileName:String, values:[Float],filterKeys:[String],image:UIImage) -> UIImage {
        let context = CIContext()
        let filter = CIFilter(name: fileName)
        for i in 0..<filterKeys.count {
            filter?.setValue(values[i], forKey:filterKeys[i])
        }
        
        filter?.setValue(CIImage(image: image), forKey: kCIInputImageKey)
        
        if let result = filter?.outputImage, let cgimage = context.createCGImage(result, from: result.extent) {
            return UIImage(cgImage: cgimage)
        }
        return image
    }
    
    public func chooseFilterCategories(name:String,values:[Float],filterKeys:[String],image:UIImage) -> UIImage {
        let filters = CIFilter.filterNames(inCategory: name)
        for filter in filters {
            if filter == "CIUnsharpMask" {
                let newImage = self.chooseFilter(fileName: filter, values: values, filterKeys: filterKeys, image: image)
                return newImage
            }
        }
        return image
    }
    
    //loading the album art
    //MARK: Todd
    func updateNowPlayingX(_ animated: Bool = true) {
        let g = Global.obj
        
        func displayArt(image: UIImage?) {
            if var img = image {
                img = img.withBackground(color: UIColor(displayP3Red: 19 / 255, green: 20 / 255, blue: 36 / 255, alpha: 1.0))
                
                typealias stepperType = [ (dim: Int, low: Float, high: Float ) ]
                
                let stepper = [ (dim: 720,  low: 0.625, high: 0.125 ),
                                (dim: 1080, low: 0.125, high: 0.25 ),
                                (dim: 1440, low: 0.25,  high: 0.5 )] as stepperType
                
                for x in stepper {
                    //MARK: Resize image
                    img = self.resizeImage(image: img, targetSize: CGSize(width: x.dim, height: x.dim))
                    
                    //MARK: Sharpen image
                    img = self.chooseFilterCategories(name: kCICategorySharpen, values: [x.low,x.high], filterKeys: [kCIInputRadiusKey,kCIInputIntensityKey], image: img)
                }
                
                g.NowPlaying.image = img
                self.setnowPlayingInfo(channel: g.NowPlaying.channel, song: g.NowPlaying.song, artist: g.NowPlaying.artist, imageData:img)
            }
            
            if animated {
                DispatchQueue.main.async { NotificationCenter.default.post(name: .gotNowPlayingInfoAnimated, object: nil) }
            } else {
                DispatchQueue.main.async { NotificationCenter.default.post(name: .gotNowPlayingInfo, object: nil) }
            }
        }
        
        //Get album art
        if g.NowPlaying.albumArt.contains("http") {
            Async.api.Imagineer(endpoint: g.NowPlaying.albumArt, ImageHandler: { (img) -> Void in
                displayArt(image: img)
            })
        } else {
            //Fix image sizing
            Async.api.Imagineer(endpoint: g.NowPlaying.channelArt, ImageHandler: { (img) -> Void in
                displayArt(image: img?.addImagePadding(x: 20, y: 200))
            })
        }
    }

    func resizeImage(image: UIImage, targetSize: CGSize) -> UIImage {
        let rect = CGRect(x: 0, y: 0, width: targetSize.width, height: targetSize.height)
        UIGraphicsBeginImageContextWithOptions( targetSize, false, 1.0)
        image.draw(in: rect)
        
        if let newImage = UIGraphicsGetImageFromCurrentImageContext() {
            UIGraphicsEndImageContext()
            return newImage
        }
        return UIImage()
    }
    
    //MARK: Read Write Cache for the PDT (Artist / Song / Album Art)
    @objc func SPXCache() {
        let ps = self
        let gs = g.self
        
        ps.updatePDT() { success in
            if success {
                
                if let i = gs.ChannelArray.firstIndex(where: {$0.channel == gs.currentChannel}) {
                    let item = gs.ChannelArray[i].largeChannelArtUrl
                    ps.updateDisplay(key: gs.currentChannel, cache: ps.pdtCache, channelArt: item)
                }
                
                DispatchQueue.main.async {
                    NotificationCenter.default.post(name: .updateChannelsView, object: nil)
                }
            }
        }
    }
    
    //MARK: Update Artist Song Info
    func updatePDT(completionHandler: @escaping CompletionHandler) {
        let g = Global.obj
        let endpoint = g.insecure + g.local + ":" + String(self.port) + "/api/v3/pdt"
        
        Async.api.Get(endpoint: endpoint) { dict in
            if let p = dict as? [String : Any], !p.isEmpty, let cache = p["data"] as? [String : Any], !cache.isEmpty {
                self.pdtCache = cache
                
                g.ChannelArray = self.getPDTData(importData: g.ChannelArray)
                completionHandler(true)
            } else {
                completionHandler(false)
            }
        }
    }
    
    func getPDTData(importData: tableData) -> tableData {
        var nowPlayingData = importData
        
        for i in 0..<nowPlayingData.count {
            let key = nowPlayingData[i].channel
            
            if let value = pdtCache[key] as? [String: String], let artist = value["artist"] as String?, let song = value["song"]  as String?, let image = value["image"]  as String? {
                
                let setArtist = NSMutableAttributedString(string: artist + "\n" , attributes: [NSAttributedString.Key.font: UIFont.systemFont(ofSize: 14)]);
                let setSong = NSMutableAttributedString(string: song, attributes: [NSAttributedString.Key.font: UIFont.systemFont(ofSize: 14)]);
                
                setArtist.append(setSong)
                nowPlayingData[i].detail = setArtist
                nowPlayingData[i].largeAlbumUrl = image
                nowPlayingData[i].searchString = nowPlayingData[i].title.string
                nowPlayingData[i].searchString = nowPlayingData[i].searchString + " " + artist
                nowPlayingData[i].searchString = nowPlayingData[i].searchString + " " + song
                nowPlayingData[i].searchString = nowPlayingData[i].searchString.replacingOccurrences(of: "'", with: "")
                nowPlayingData[i].image        = nowPlayingData[i].channelImage
                nowPlayingData[i].albumUrl     =  nowPlayingData[i].largeChannelArtUrl
            }
        }
        return nowPlayingData
    }
    
    public func setnowPlayingInfo(channel:String, song:String, artist:String, imageData: UIImage) {
        let nowPlayingInfoCenter = MPNowPlayingInfoCenter.default()
        var nowPlayingInfo = nowPlayingInfoCenter.nowPlayingInfo ?? [String: Any]()
        let image = imageData.withBackground(color: UIColor(displayP3Red: 19 / 255, green: 20 / 255, blue: 36 / 255, alpha: 1.0))
        let artwork = MPMediaItemArtwork(boundsSize: image.size, requestHandler: {  (_) -> UIImage in
            return image
        })
        
        nowPlayingInfo[MPMediaItemPropertyTitle]                    = song
        nowPlayingInfo[MPMediaItemPropertyArtist]                   = artist
        nowPlayingInfo[MPMediaItemPropertyAlbumTitle]               = channel
        nowPlayingInfo[MPMediaItemPropertyPodcastTitle]             = song
        nowPlayingInfo[MPMediaItemPropertyArtwork]                  = artwork
        nowPlayingInfo[MPMediaItemPropertyMediaType]                = 1
        nowPlayingInfo[MPNowPlayingInfoPropertyIsLiveStream]        = true
        nowPlayingInfo[MPMediaItemPropertyAlbumArtist]              = artist
        nowPlayingInfo[MPMediaItemPropertyAlbumTitle]               = g.currentChannelName
        nowPlayingInfo[MPNowPlayingInfoPropertyDefaultPlaybackRate] = 1.0
        
        if self.player.rate == 1 {
            nowPlayingInfoCenter.playbackState = .playing
        } else {
            nowPlayingInfoCenter.playbackState = .paused
        }
        nowPlayingInfoCenter.nowPlayingInfo = nowPlayingInfo
    }
    
    public func autoLaunchServer(completionHandler: CompletionHandler) {
        print("Restarting Server...")
        
        if UIAccessibility.isVoiceOverRunning {
            let utterance = AVSpeechUtterance(string: "Buffering")
            utterance.voice = AVSpeechSynthesisVoice(language: "en-US")
            utterance.rate = 0.5
            
            let synthesizer = AVSpeechSynthesizer()
            synthesizer.speak(utterance)
        }
        
        //Find the first Open port
        for i in self.port..<65000 {
            if Network.ability.open(port: UInt16(i)) {
                self.port = UInt16(i)
                break
            }
        }
        startServer(self.port)
        jumpStart()
        
        completionHandler(true)
    }
    
    func magicTapped() {
        new(nil)
    }
    
    let avSession = AVAudioSession.sharedInstance()
    
    func endRemoteTransportControls() {
        print("End remote controls")
        try? avSession.setActive(false)
    }
    ///These are used on the iPhone's lock screen
    ///Command Center routines
    func setupRemoteTransportControls(application: UIApplication) {
        do {
            print("Setup remote controls")
            avSession.accessibilityPerformMagicTap()
            avSession.accessibilityActivate()
            try avSession.setPreferredIOBufferDuration(0)
            try avSession.setCategory(.playback, mode: .default, policy: .longFormAudio, options: [])
            try avSession.setActive(false)
            
        } catch {
            print(error)
        }
        
        // Get the shared MPRemoteCommandCenter
        let commandCenter = MPRemoteCommandCenter.shared()
        commandCenter.accessibilityActivate()
        commandCenter.playCommand.addTarget(handler: { (event) in
            //print("1")
            self.new(.stream)
            return MPRemoteCommandHandlerStatus.success}
        )
        commandCenter.pauseCommand.addTarget(handler: { (event) in
            //print("2")
            self.new(.playing)
            return MPRemoteCommandHandlerStatus.success}
        )
        commandCenter.togglePlayPauseCommand.addTarget(handler: { (event) in
            self.new(.playing)
            return MPRemoteCommandHandlerStatus.success}
        )
    }
}

func jumpStart() {
    let net = Network.ability
    net.start()
    let locale = Locale.current
    
    if locale.regionCode == "CA" || locale.regionCode == "CAN" {
        preflightConfig(location: "CA")
    } else {
        preflightConfig(location: "US")
    }
}
