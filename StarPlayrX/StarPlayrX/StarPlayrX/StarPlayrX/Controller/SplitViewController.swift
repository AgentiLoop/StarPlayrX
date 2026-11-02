//
//  SplitViewController.swift
//  StarPlayrX
//
//  Created by Todd Bruss on 4/11/20.
//  Modified by Todd Bruss on 5/18/25.
//  Copyright © 2020 Todd Bruss. All rights reserved.
//

import UIKit

class SplitViewController: UISplitViewController, UISplitViewControllerDelegate {
    override var preferredScreenEdgesDeferringSystemGestures: UIRectEdge { .bottom }
    override var prefersHomeIndicatorAutoHidden : Bool { return true }
    
    override func viewDidLoad() {
        self.delegate = self
        self.preferredDisplayMode = UISplitViewController.DisplayMode.oneBesideSecondary
        
        if let appearance = navigationController?.navigationBar.standardAppearance {
            appearance.shadowImage = .none
            appearance.shadowColor = UIColor(displayP3Red: 20 / 255, green: 22 / 255, blue: 24 / 255, alpha: 1.0)
            appearance.backgroundColor = UIColor(displayP3Red: 20 / 255, green: 22 / 255, blue: 24 / 255, alpha: 1.0)
            appearance.titleTextAttributes =  [ .foregroundColor : UIColor.white ]
            navigationController?.navigationBar.standardAppearance = appearance
            navigationController?.navigationBar.layer.borderWidth = 0.0
        }
        self.view.backgroundColor = UIColor(displayP3Red: 35 / 255, green: 37 / 255, blue: 39 / 255, alpha: 1.0)
    }
    
    func splitViewController(
        _ splitViewController: UISplitViewController,
        collapseSecondary secondaryViewController: UIViewController,
        onto primaryViewController: UIViewController) -> Bool {
        // Return true to prevent UIKit from applying its default behavior
        return true
    }
}
