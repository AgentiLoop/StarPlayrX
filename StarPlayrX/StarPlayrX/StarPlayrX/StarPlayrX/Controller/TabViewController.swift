//
//  TabViewController.swift
//  StarPlayr
//
//  Created by Todd Bruss on 2/10/19.
//  Modified by Todd Bruss on 5/18/25.
//  Copyright © 2019 Todd Bruss. All rights reserved.
//

import UIKit


class TabController: UITabBarController {
    
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .bottom }
    override var prefersHomeIndicatorAutoHidden : Bool { return true }

    override func viewDidLoad() {
        super.viewDidLoad()
 		
        let appearance = tabBar.standardAppearance
        appearance.shadowImage = nil
        appearance.shadowColor = UIColor(displayP3Red: 20 / 255, green: 22 / 255, blue: 24 / 255, alpha: 1.0)
        appearance.backgroundColor = UIColor(displayP3Red: 20 / 255, green: 22 / 255, blue: 24 / 255, alpha: 1.0)
        tabBar.standardAppearance = appearance
      
        tabBar.layer.borderWidth = 0.0
        tabBar.clipsToBounds = true
       
        delegate = self
    }
    
    //MARK: Determine if we still need this
   // override open var supportedInterfaceOrientations : UIInterfaceOrientationMask {
        /*let deviceType = UIDevice().type
        
        // iPhoneX which is portrait only
        if deviceType == .iPhoneX || deviceType == .iPhoneXSMax {
            return .portrait
        }
        
        // All other iPhone screen sizes
        if deviceType == .iPhone8 || deviceType == .iPhone8Plus || deviceType == .iPhoneSE {
            return [.portrait,.portraitUpsideDown] //brings back upsidedown on non-iPhoneX's
            
        } else if deviceType == .iPad {
            return .landscape
        } else {
            return .all // don't know what device that have, but it will still work just not optimized
        }*/
    //}
}

//TabViewController
extension TabController: UITabBarControllerDelegate  {
    func tabBarController(_ tabBarController: UITabBarController, shouldSelect viewController: UIViewController) -> Bool {
        guard let fromView = selectedViewController?.view, let toView = viewController.view else {
            return false // Make sure you want this as false
        }
        
        if fromView != toView {
            UIView.transition(from: fromView, to: toView, duration: 0.3, options: [.transitionCrossDissolve], completion: nil)           
        }
        return true
    }
}
