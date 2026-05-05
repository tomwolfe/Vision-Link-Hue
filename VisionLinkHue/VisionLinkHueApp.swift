//
//  VisionLinkHueApp.swift
//  Vision-Link Hue
//  Copyright © 2026 Thomas Wolfe. All rights reserved.
//

import SwiftUI

@main
struct VisionLinkHueApp: App {
    
    init() {
        // Register app lifecycle observers for SSE stream pause/resume.
        // This ensures the SSE stream is paused when the app enters the
        // background and resumed when it returns to the foreground.
        AppContainer.shared.hueClient.registerLifecycleObservers()
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(AppContainer.shared.stateStream)
                .environment(AppContainer.shared.hueClient)
                .environment(AppContainer.shared.detectionEngine)
                .environment(AppContainer.shared.arSessionManager)
                .environment(AppContainer.shared.spatialProjector)
                .environment(AppContainer.shared.detectionSettings)
        }
    }
}
