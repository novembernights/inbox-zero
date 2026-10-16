import AppKit
import SwiftUI

@main
struct ActionMailApp: App {
    @NSApplicationDelegateAdaptor(FloatingPanelDelegate.self) private var appDelegate
    @State private var store = WorkflowStore()

    var body: some Scene {
        WindowGroup {
            DashboardView(store: store)
                .frame(width: 500, height: 380)
                .scaleEffect(0.84)
                .frame(width: 420, height: 319)
        }
        .windowStyle(.hiddenTitleBar)
        .windowResizability(.contentSize)
    }
}

final class FloatingPanelDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.regular)
        DispatchQueue.main.async { self.configureWindows() }
    }

    func applicationDidBecomeActive(_ notification: Notification) {
        configureWindows()
    }

    private func configureWindows() {
        for window in NSApp.windows {
            window.level = .floating
            window.collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
            window.isMovableByWindowBackground = true
            window.titleVisibility = .hidden
            window.titlebarAppearsTransparent = true
            window.backgroundColor = .clear
            window.isOpaque = false
            window.hasShadow = false
            window.standardWindowButton(.closeButton)?.isHidden = true
            window.standardWindowButton(.miniaturizeButton)?.isHidden = true
            window.standardWindowButton(.zoomButton)?.isHidden = true
        }
    }
}
