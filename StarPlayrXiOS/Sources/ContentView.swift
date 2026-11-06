//
//  ContentView.swift
//  StarPlayrX (iOS / iPadOS)
//
//  Copyright © 2026 Todd Bruss. All rights reserved.
//

import SwiftUI
import StarPlayrKit

struct ContentView: View {
    var body: some View {
        VStack(spacing: 8) {
            Text("StarPlayrX").font(.largeTitle.bold())
            Text(AppVersion.string).foregroundStyle(.secondary)
        }
    }
}
