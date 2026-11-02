//
//  Extensions.swift
//  StarPlayr
//
//  Created by Todd on 3/2/19.
//  Modified by Todd Bruss on 5/18/25.
//  Copyright © 2019 Todd Bruss. All rights reserved.
//

import Foundation
import UIKit
import AVFoundation
import MediaPlayer

extension UIImage {
    func withBackground(color: UIColor, opaque: Bool = true) -> UIImage {
        UIGraphicsBeginImageContextWithOptions(size, opaque, scale)
        guard let ctx = UIGraphicsGetCurrentContext() else { return self }
        
        defer { UIGraphicsEndImageContext() }
        
        let rect = CGRect(origin: .zero, size: size)
        
        if let cgImage = cgImage {
            ctx.setFillColor(color.cgColor)
            ctx.fill(rect)
            ctx.concatenate(CGAffineTransform(a: 1, b: 0, c: 0, d: -1, tx: 0, ty: size.height))
            ctx.draw(cgImage, in: rect)
        }
        
        return UIGraphicsGetImageFromCurrentImageContext() ?? self
    }
    
    func maskWithColor(color: UIColor) -> UIImage? {
        guard let maskImage = cgImage else { return self }
        
        let width = size.width
        let height = size.height
        let bounds = CGRect(x: 0, y: 0, width: width, height: height)
        
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedLast.rawValue)
        
        if let context = CGContext(data: nil, width: Int(width), height: Int(height),
                                   bitsPerComponent: 8, bytesPerRow: 0, space: colorSpace,
                                   bitmapInfo: bitmapInfo.rawValue),
            let cgImage = context.makeImage() {
            context.clip(to: bounds, mask: maskImage)
            context.setFillColor(color.cgColor)
            context.fill(bounds)
            
            let coloredImage = UIImage(cgImage: cgImage)
            return coloredImage
        } else {
            return self
        }
    }
}

//Some extra variables, so we can check the status of our AVPlayer
extension AVQueuePlayer {
    var isDead: Bool {
        return rate == 0
    }
    
    var isBusy: Bool {
        return rate == 1
    }
}

extension Notification.Name {
    static let didUpdatePlay = Notification.Name("didUpdatePlay")
    static let didUpdatePause = Notification.Name("didUpdatePause")
    static let updateChannelsView = Notification.Name("updateChannelsView")
    static let gotNowPlayingInfo = Notification.Name("gotNowPlayingInfo")
    static let gotNowPlayingInfoAnimated = Notification.Name("gotNowPlayingInfoAnimated")
    static let gotSessionInterruption = AVAudioSession.interruptionNotification
    static let gotRouteChangeNotification = AVAudioSession.routeChangeNotification
    static let willEnterForegroundNotification = UIApplication.willEnterForegroundNotification
}

extension UIImage {
    func addImagePadding(x: CGFloat, y: CGFloat) -> UIImage? {
        let width: CGFloat = size.width + x
        let height: CGFloat = size.height + y
        UIGraphicsBeginImageContextWithOptions(CGSize(width: width, height: height), false, 0)
        let origin: CGPoint = CGPoint(x: (width - size.width) / 2, y: (height - size.height) / 2)
        draw(at: origin)
        let imageWithPadding = UIGraphicsGetImageFromCurrentImageContext()
        UIGraphicsEndImageContext()
        
        return imageWithPadding
    }
}
