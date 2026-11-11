import ServiceManagement
import SwiftUI

@main
struct GatePassApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var delegate
    @StateObject private var model = AppModel()

    var body: some Scene {
        Window("GatePass", id: "main") {
            ContentView()
                .environmentObject(model)
                .environmentObject(model.library)
                .frame(minWidth: 860, minHeight: 600)
                .onAppear {
                    Appearance.apply(UserDefaults.standard.string(forKey: Pref.appearance) ?? "system")
                    model.start()
                }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 980, height: 660)

        Settings {
            SettingsView()
                .environmentObject(model)
        }

        MenuBarExtra {
            MenuBarContent()
                .environmentObject(model)
        } label: {
            Image(systemName: model.isBusy ? "arrow.triangle.2.circlepath.circle.fill" : "arrow.triangle.2.circlepath.circle")
                .onAppear { model.start() }
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        Appearance.apply(UserDefaults.standard.string(forKey: Pref.appearance) ?? "system")
    }

    /// Keep running in the menu bar after the window closes, so auto-refresh keeps working.
    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { false }
}

enum LaunchAtLogin {
    static var isEnabled: Bool { SMAppService.mainApp.status == .enabled }
    static func set(_ on: Bool) {
        do {
            if on { try SMAppService.mainApp.register() } else { try SMAppService.mainApp.unregister() }
        } catch {
            NSLog("Launch at login failed: \(error)")
        }
    }
}
