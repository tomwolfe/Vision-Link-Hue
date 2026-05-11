//
//  VisionLinkHueApp.swift
//  Vision-Link Hue
//  Copyright © 2026 Thomas Wolfe. All rights reserved.
//

import SwiftUI
import UIKit

@main
struct VisionLinkHueApp: App {
    
    init() {
        // Register app lifecycle observers for SSE stream pause/resume.
        // This ensures the SSE stream is paused when the app enters the
        // background and resumed when it returns to the foreground.
        AppContainer.shared.hueClient.registerLifecycleObservers()
        
        // Register for app lifecycle notifications to flush telemetry
        // and stop local sync when the app enters the background.
        let center = NotificationCenter.default
        center.addObserver(
            forName: UIApplication.willResignActiveNotification,
            object: nil,
            queue: .main
        ) { [weak container = AppContainer.shared] _ in
            guard let container else { return }
            Task { @MainActor in
                container.telemetryService.flush()
            }
        }
        
        center.addObserver(
            forName: UIApplication.didEnterBackgroundNotification,
            object: nil,
            queue: .main
        ) { [weak container = AppContainer.shared] _ in
            guard let container else { return }
            // Stop telemetry when the app enters the background.
            Task { @MainActor in
                container.telemetryService.flush()
            }
        }
        
        center.addObserver(
            forName: UIApplication.willEnterForegroundNotification,
            object: nil,
            queue: .main
        ) { [weak container = AppContainer.shared] _ in
            guard let container else { return }
            // Restart telemetry when returning to foreground.
            Task { @MainActor in
                container.telemetryService.flush()
            }
        }
    }
    
    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(AppContainer.shared.stateStream)
                .environment(AppContainer.shared.hueClient)
                .environment(AppContainer.shared.detectionEngine)
                .environment(AppContainer.shared.arSessionManager)
                .environment(AppContainer.shared.spatialProjector)
                .environment(AppContainer.shared.gestureManager)
                .environment(AppContainer.shared.detectionSettings)
        }
    }
}
