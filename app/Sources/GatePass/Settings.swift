import SwiftUI

/// UserDefaults keys shared by the app.
enum Pref {
    static let appearance = "appearance"      // "system" | "light" | "dark"
    static let autoRefresh = "autoRefresh"    // Bool, default true
    static let notifications = "notifications" // Bool, default true
    static let devMode = "devMode"            // Bool, default false
    static let didOnboard = "didOnboard"      // Bool
    static let keychain = "useKeychain"       // Bool, default false

    static func bool(_ key: String, default value: Bool) -> Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? value
    }
}

enum Appearance {
    static func apply(_ value: String) {
        switch value {
        case "light": NSApp.appearance = NSAppearance(named: .aqua)
        case "dark": NSApp.appearance = NSAppearance(named: .darkAqua)
        default: NSApp.appearance = nil // follow macOS
        }
    }
}

struct SettingsView: View {
    var body: some View {
        TabView {
            GeneralSettings().tabItem { Label("General", systemImage: "gearshape") }
            AdvancedSettings().tabItem { Label("Advanced", systemImage: "wrench.and.screwdriver") }
            AboutSettings().tabItem { Label("About", systemImage: "info.circle") }
        }
        .frame(width: 480)
        .padding(.vertical, 8)
    }
}

struct GeneralSettings: View {
    @EnvironmentObject var model: AppModel
    @AppStorage(Pref.appearance) private var appearance = "system"
    @AppStorage(Pref.autoRefresh) private var autoRefresh = true
    @AppStorage(Pref.notifications) private var notifications = true
    @AppStorage(Pref.didOnboard) private var didOnboard = false
    @AppStorage(Pref.keychain) private var useKeychain = false
    @State private var launchAtLogin = LaunchAtLogin.isEnabled

    var body: some View {
        Form {
            Picker("Appearance", selection: $appearance) {
                Text("System").tag("system")
                Text("Light").tag("light")
                Text("Dark").tag("dark")
            }
            .pickerStyle(.segmented)
            .onChange(of: appearance) { _, v in Appearance.apply(v) }

            Section {
                Toggle("Refresh apps automatically", isOn: $autoRefresh)
                Text("When a device shows up (USB or Wi-Fi), GatePass refreshes apps that expire within 2 days.")
                    .font(.caption).foregroundStyle(.secondary)
                Toggle("Notifications", isOn: $notifications)
                Toggle("Open GatePass at login", isOn: $launchAtLogin)
                    .onChange(of: launchAtLogin) { _, v in LaunchAtLogin.set(v) }
            }

            Section("Security") {
                Toggle("Store sign-in in Keychain", isOn: $useKeychain)
                    .onChange(of: useKeychain) { Task { await model.reloadAccount() } }
                Text(useKeychain
                     ? "Your Apple session token is kept in the macOS Keychain. macOS may ask for your Mac password (“gatepass-engine wants to use…”) after GatePass updates — click Always Allow. If you turn this off later, you'll need to sign in again."
                     : "Your Apple session token is kept in a file only your Mac user account can read, like Sideloadly does. No password prompts. Your Apple ID password is never saved either way.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                Button("Show Welcome Again") { didOnboard = false }
            }
        }
        .formStyle(.grouped)
    }
}

struct AdvancedSettings: View {
    @AppStorage(Pref.devMode) private var devMode = false

    var body: some View {
        Form {
            Section {
                Toggle("Developer mode", isOn: $devMode)
                Text("Adds an “Advanced…” button for installs: custom name, bundle ID and version, tweaks, removing extensions, ad-hoc signing and IPA export.")
                    .font(.caption).foregroundStyle(.secondary)
            }

            if devMode {
                Section("Troubleshooting") {
                    Button("Open Log (engine.log)") { NSWorkspace.shared.open(EngineLog.url) }
                    Button("Open Data Folder") {
                        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
                            .appendingPathComponent("GatePass")
                        NSWorkspace.shared.open(dir)
                    }
                }
            }
        }
        .formStyle(.grouped)
    }
}

struct AboutSettings: View {
    private var version: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "dev"
    }

    var body: some View {
        VStack(spacing: 10) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 84, height: 84)
            Text("GatePass").font(.system(size: 20, weight: .bold, design: .rounded))
            Text("Version \(version)").foregroundStyle(.secondary)
            Text("Open source (MIT). The engine is based on the Impactor project.\nYour password goes only to Apple and is never saved.")
                .font(.caption)
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
        }
        .frame(maxWidth: .infinity)
        .padding(24)
    }
}
