
//
//  AVPlayerExtensions.swift
//  AVPlayerFade
//
//  Created by Evandro Harrison Hoffmann on 21/05/2020.
//  Copyright © 2020 It's Day Off. All rights reserved.
//

import AVFoundation

public extension AVPlayer {
    
    /// Fades player volume FROM any volume TO any volume
    /// - Parameters:
    ///   - from: initial volume
    ///   - to: target volume
    ///   - duration: duration in seconds for the fade
    ///   - completion: callback indicating completion
    /// - Returns: Timer?
    ///
    ///
    @discardableResult
    func fadeVolume(from: Float, to: Float, duration: Float, completion: (() -> Void)? = nil) -> Timer? {
        
        volume = from
        
        guard from != to else { return nil }
        
        let interval: Float = 0.1
        let range = to-from
        let step = (range*interval)/duration
        
        func reachedTarget() -> Bool {
            // volume passed max/min
            guard volume >= 0, volume <= 1 else {
                volume = to
                return true
            }
            
            if to > from {
                return volume >= to
            }
            return volume <= to
        }
        
        return Timer.scheduledTimer(withTimeInterval: Double(interval), repeats: true, block: { [weak self] (timer) in
            guard let self = self else { return }
            
            DispatchQueue.main.async {
                if !reachedTarget() {
                    self.volume += step
                } else {
                    timer.invalidate()
                    completion?()
                }
            }
        })
    }
}
