//
//  AppDelegate.swift
//  StarPlayrX
//
//  Created by Todd Bruss on 4/19/20.
//  Modified by Todd Bruss on 5/18/25.
//  Copyright © 2020 Todd Bruss. All rights reserved.
//

import UIKit

@UIApplicationMain
class AppDelegate: UIResponder, UIApplicationDelegate {
    
    @available(iOS 12.0, *)
    var window: UIWindow?

    @available(iOS 12.0, *)
    var preferredStatusBarStyle: UIStatusBarStyle {
        return .lightContent // .default
    }
    
    @available(iOS 12.0, *)
    func application(_ application: UIApplication, didFinishLaunchingWithOptions launchOptions: [UIApplication.LaunchOptionsKey: Any]?) -> Bool {
        net.start()
    
        // Override point for customization after application launch.
        let selectedView = UIView()
        selectedView.backgroundColor = UIColor(displayP3Red: 20 / 255, green: 22 / 255, blue: 24 / 255, alpha: 1.0)
        UITableViewCell.appearance().selectedBackgroundView = selectedView
        
        Player.shared.setupRemoteTransportControls(application: application)
        application.beginReceivingRemoteControlEvents()

        return true
    }

    func application(_ application: UIApplication, configurationForConnecting connectingSceneSession: UISceneSession, options: UIScene.ConnectionOptions) -> UISceneConfiguration {
        return UISceneConfiguration(name: "Default Configuration", sessionRole: connectingSceneSession.role)
    }
    
    func applicationWillTerminate(_ application: UIApplication) {
        Player.shared.endRemoteTransportControls()
        application.endReceivingRemoteControlEvents()
    }
}
