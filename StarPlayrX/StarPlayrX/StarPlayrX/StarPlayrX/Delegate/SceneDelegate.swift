//
//  SceneDelegate.swift
//  StarPlayrX
//
//  Created by Todd Bruss on 4/19/20.
//  Modified by Todd Bruss on 5/18/25.
//  Copyright © 2020 Todd Bruss. All rights reserved.
//

import UIKit

class SceneDelegate: UIResponder, UIWindowSceneDelegate  {
    
    var window: UIWindow?

    func scene(_ scene: UIScene, willConnectTo session: UISceneSession, options connectionOptions: UIScene.ConnectionOptions) {
        // Use this method to optionally configure and attach the UIWindow `window` to the provided UIWindowScene `scene`.
        // If using a storyboard, the `window` property will automatically be initialized and attached to the scene.
        // This delegate does not imply the connecting scene or session are new (see `application:configurationForConnectingSceneSession` instead).
        
        if ProcessInfo.processInfo.isMacCatalystApp {
            isMacCatalystApp = true
            UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }.forEach { windowScene in
                windowScene.sizeRestrictions?.minimumSize = CGSize(width: 400, height: 800)
                windowScene.sizeRestrictions?.maximumSize = CGSize(width: 400, height: 800)
           }
        }

        #if targetEnvironment(macCatalyst)
           guard let windowScene = (scene as? UIWindowScene) else { return }
           if let titlebar = windowScene.titlebar {
               titlebar.titleVisibility = .hidden
               titlebar.toolbar = nil
           }
        #endif
    }
}
