//
//  VisionLinkHueApp.swift
//  Vision-Link Hue
//  Copyright © 2026 Thomas Wolfe. All rights reserved.
//

import SwiftUI

@main
struct VisionLinkHueApp: App {
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(AppContainer.shared.stateStream)
                .environment(AppContainer.shared.hueClient)
                .environment(AppContainer.shared.detectionEngine)
                .environment(AppContainer.shared.arSessionManager)
                .environment(AppContainer.shared.spatialProjector)
        }
    }
}
