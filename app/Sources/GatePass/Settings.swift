import SwiftUI

/// UserDefaults keys shared by the app.
enum Pref {
    static let appearance = "appearance"      // "system" | "light" | "dark"
    static let autoRefresh = "autoRefresh"    // Bool, default true
    static let notifications = "notifications" // Bool, default true
    static let devMode = "devMode"            // Bool, default false
    static let didOnboard = "didOnboard"      // Bool
    static let keychain = "useKeychain"       // Bool, default false
    static let autoUpdate = "autoUpdate"      // Bool, default true

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

            UpdateSettings()

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

struct UpdateSettings: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var updater = Updater.shared
    @AppStorage(Pref.autoUpdate) private var autoUpdate = true

    var body: some View {
        Section("Updates") {
            Toggle("Update GatePass automatically", isOn: $autoUpdate)
            Text("GatePass checks for a new version every few hours and downloads it in the background. It installs when you click Restart to Update, or the next time GatePass quits.")
                .font(.caption).foregroundStyle(.secondary)
            HStack {
                Text(status).foregroundStyle(.secondary)
                Spacer()
                switch updater.state {
                case .ready:
                    Button("Restart to Update") { updater.installAndRelaunch() }.disabled(model.isBusy)
                case .manual(let r, _):
                    Button("Download…") { NSWorkspace.shared.open(r.pageURL) }
                case .checking, .downloading:
                    ProgressView().controlSize(.small)
                default:
                    Button("Check Now") { Task { await updater.check(userInitiated: true) } }
                }
            }
        }
    }

    private var status: String {
        switch updater.state {
        case .idle: return "Version \(updater.currentVersion)"
        case .checking: return "Checking…"
        case .upToDate: return "GatePass \(updater.currentVersion) is up to date."
        case .downloading(let r): return "Downloading \(r.version)…"
        case .ready(let r, _): return "GatePass \(r.version) is ready to install."
        case .manual(_, let reason): return reason
        case .failed(let message): return message
        }
    }
}
