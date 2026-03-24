/// SonosControllerApp.swift — App entry point.
///
/// Creates the SonosManager singleton and injects it into the SwiftUI environment.
/// Discovery begins immediately on appear so speakers populate while the window loads.
/// Applies the user's appearance preference. Accent color is applied per-view,
/// not on the whole window, to avoid tinting toolbar icons.
import SwiftUI
import SonosKit

@main
struct SonosControllerApp: App {
    @StateObject private var sonosManager = SonosManager()

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environmentObject(sonosManager)
                .onAppear {
                    sonosManager.startDiscovery()
                }
                .frame(minWidth: 700, minHeight: 450)
                .preferredColorScheme(colorScheme)
        }
        .windowStyle(.titleBar)
        .defaultSize(width: 900, height: 550)
    }

    private var colorScheme: ColorScheme? {
        switch sonosManager.appearanceMode {
        case .system: return nil
        case .light: return .light
        case .dark: return .dark
        }
    }
}
