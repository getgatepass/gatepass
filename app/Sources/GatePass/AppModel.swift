import Foundation
import SwiftUI
import UserNotifications

/// A question the engine is waiting on (2FA code, confirmation).
struct PendingPrompt: Identifiable {
    enum Kind { case twoFactor(method: String, phones: [(id: Int, lastTwo: String)]), confirm(title: String, message: String) }
    let id = UUID()
    let kind: Kind
    let respond: (String) -> Void
}

struct Activity: Equatable {
    var title: String
    var stage: String
    var percent: Double
    var cancellable = true
}

@MainActor
final class AppModel: ObservableObject {
    @Published var account: Account?
    @Published var devices: [Device] = []
    @Published var selectedDeviceID: String?
    @Published var trackedApps: [TrackedApp] = []
    @Published var activity: Activity?
    @Published var prompt: PendingPrompt?
    @Published var errorMessage: String?
    @Published var toast: String?
    @Published var showLogin = false
    @Published var advancedFile: IPAFile?
    @Published var lastAutoCheck: Date?
    @Published var quota: Quota?
    @Published var quotaLoading = false
    @Published var quotaError: String?

    let library = Library()

    private var pollTask: Task<Void, Never>?
    /// Engine jobs that touch a device or the account run strictly one at a time.
    private var busy = false
    private var currentRun: EngineHandle?
    private var queueCancelled = false
    /// IPAs dropped/picked but not installed yet (the user presses Install).
    @Published var staged: [IPAFile] = []

    var selectedDevice: Device? {
        devices.first { $0.udid == selectedDeviceID } ?? devices.first
    }

    var isBusy: Bool { activity != nil }

    // MARK: Lifecycle

    func start() {
        guard pollTask == nil else { return }
        UNUserNotificationCenter.current().requestAuthorization(options: [.alert, .sound]) { _, _ in }
        pollTask = Task { [weak self] in
            await self?.reloadAccount()
            Task { await self?.loadQuota() }
            while !Task.isCancelled {
                await self?.tick()
                try? await Task.sleep(nanoseconds: 30 * 1_000_000_000)
            }
        }
    }

    /// Every 30 s: refresh the device list, then auto-refresh anything that's due on a device that's here.
    private func tick() async {
        await reloadDevices()
        await reloadApps()
        await autoRefreshIfNeeded()
    }

    // MARK: Loading

    func reloadAccount() async {
        guard let result = try? await Engine.run(["accounts"]),
              let list = result["accounts"] as? [JSON] else { return }
        let selected = list.first { ($0["selected"] as? Bool) == true } ?? list.first
        account = selected.map {
            Account(email: $0["email"] as? String ?? "", firstName: $0["firstName"] as? String ?? "")
        }
    }

    func reloadDevices() async {
        guard !busy else { return }
        guard let result = try? await Engine.run(["devices"]),
              let list = result["devices"] as? [JSON] else { return }
        let fresh = list.compactMap(Device.init(json:))
        if fresh != devices {
            withAnimation(.snappy) { devices = fresh }
        }
        if selectedDeviceID == nil || !fresh.contains(where: { $0.udid == selectedDeviceID }) {
            selectedDeviceID = fresh.first?.udid
        }
    }

    func reloadApps() async {
        guard let result = try? await Engine.run(["apps"]),
              let list = result["devices"] as? [JSON] else { return }
        var apps: [TrackedApp] = []
        for dev in list {
            let udid = dev["udid"] as? String ?? ""
            let devName = dev["name"] as? String ?? ""
            for a in (dev["apps"] as? [JSON]) ?? [] {
                apps.append(TrackedApp(
                    deviceUDID: udid,
                    deviceName: devName,
                    name: a["name"] as? String ?? "App",
                    bundleId: a["bundleId"] as? String ?? "",
                    expiresAt: DateParsing.parse(a["expiresAt"]),
                    refreshAt: DateParsing.parse(a["refreshAt"]),
                    due: a["due"] as? Bool ?? false
                ))
            }
        }
        apps.sort { ($0.expiresAt ?? .distantFuture) < ($1.expiresAt ?? .distantFuture) }
        if apps != trackedApps { trackedApps = apps }
    }

    // MARK: Account

    /// Shown inside the login sheet (alerts can't appear on top of an open sheet).
    @Published var loginError: String?

    func login(email: String, password: String) async -> Bool {
        loginError = nil
        let creds = try! JSONSerialization.data(withJSONObject: ["email": email, "password": password])
        let ok = await perform(title: "Signing in", args: ["login"], input: String(decoding: creds, as: UTF8.self))
        if ok {
            await reloadAccount()
            showLogin = false
            Task { await loadQuota() }
            showToast("Signed in ✓")
        } else {
            loginError = errorMessage ?? "Sign-in failed."
            errorMessage = nil
        }
        return ok
    }

    func loadQuota() async {
        guard account != nil, !quotaLoading else { return }
        quotaLoading = true
        defer { quotaLoading = false }
        do {
            let r = try await Engine.run(["quota"])
            quota = Quota(json: r)
            quotaError = nil
        } catch {
            quotaError = error.localizedDescription
        }
    }

    func logout() async {
        guard let account else { return }
        _ = await perform(title: "Signing out", args: ["logout", "--email", account.email])
        self.account = nil
        quota = nil
    }

    // MARK: Install / refresh

    @discardableResult
    func install(_ ipa: IPAFile, on device: Device? = nil, options: InstallOptions = InstallOptions(), position: String? = nil) async -> Bool {
        let exporting = options.mode == .export
        let device = device ?? selectedDevice
        if device == nil && !exporting {
            errorMessage = "No device connected. Connect your iPhone by cable or keep it on the same Wi-Fi network."
            return false
        }
        guard account != nil || options.mode == .adhoc else { showLogin = true; return false }
        library.markRecent(ipa.url)
        let label = library.displayName(ipa)
        var args = ["install", "--ipa", ipa.url.path]
        if let device, !exporting { args += ["--udid", device.udid] }
        args += options.engineArgs
        let ok = await perform(
            title: (exporting ? "Exporting \(label)" : "Installing \(label) on \(device!.name)") + (position.map { " · \($0)" } ?? ""),
            args: args
        )
        if ok, exporting, let out = options.exportURL {
            showToast("Signed IPA saved ✓")
            NSWorkspace.shared.activateFileViewerSelecting([out])
            await loadQuota()
        } else if ok, let device {
            notify("Installed", "\(label) is now on \(device.name).")
            showToast("\(label) installed ✓")
            await reloadApps()
            await loadQuota()
        }
        return ok
    }

    /// Stops the running command (and any queued installs). Safe: the engine reports moments
    /// when stopping would cause damage and the Stop button is hidden then.
    func cancelCurrent() {
        guard let run = currentRun, activity?.cancellable != false else { return }
        queueCancelled = true
        prompt?.respond("no")
        run.cancel()
    }

    func stage(_ urls: [URL]) async {
        for url in urls where ["ipa", "tipa"].contains(url.pathExtension.lowercased()) {
            guard !staged.contains(where: { $0.url == url }) else { continue }
            let file = await library.info(for: url)
            withAnimation(.snappy) { staged.append(file) }
        }
    }

    func unstage(_ file: IPAFile) {
        withAnimation(.snappy) { staged.removeAll { $0.url == file.url } }
    }

    /// Installs the staged IPAs one after another.
    func installStaged() async {
        let files = staged
        guard !files.isEmpty else { return }
        queueCancelled = false
        for (i, file) in files.enumerated() {
            if queueCancelled { break }
            let ok = await install(file, position: files.count > 1 ? "\(i + 1)/\(files.count)" : nil)
            if ok { unstage(file) } else { break }
        }
    }

    func refresh(_ app: TrackedApp) async {
        let ok = await perform(
            title: "Refreshing \(app.name)",
            args: ["refresh", "--udid", app.deviceUDID, "--force", "--bundle-id", app.bundleId]
        )
        if ok {
            showToast("\(app.name) refreshed for 7 more days ✓")
            await reloadApps()
        }
    }

    func refreshAll(on udid: String) async {
        let ok = await perform(title: "Refreshing all apps", args: ["refresh", "--udid", udid, "--force"])
        if ok { showToast("All apps refreshed ✓"); await reloadApps() }
    }

    func forget(_ app: TrackedApp) async {
        _ = try? await Engine.run(["forget", "--udid", app.deviceUDID, "--bundle-id", app.bundleId])
        await reloadApps()
    }

    func isConnected(_ udid: String) -> Bool { devices.contains { $0.udid == udid } }

    private func autoRefreshIfNeeded() async {
        guard !busy, account != nil, Pref.bool(Pref.autoRefresh, default: true) else { return }
        lastAutoCheck = .now
        let dueDevices = Set(trackedApps.filter { $0.due && isConnected($0.deviceUDID) }.map(\.deviceUDID))
        for udid in dueDevices {
            let names = trackedApps.filter { $0.deviceUDID == udid && $0.due }.map(\.name)
            let deviceName = devices.first { $0.udid == udid }?.name ?? "device"
            let ok = await perform(title: "Auto-refresh on \(deviceName)", args: ["refresh", "--udid", udid], quiet: true)
            if ok {
                notify("Refreshed", "\(names.joined(separator: ", ")) will keep working for 7 more days on \(deviceName).")
            }
        }
        if !dueDevices.isEmpty { await reloadApps() }
    }

    // MARK: Plumbing

    /// Runs an engine job with progress UI and prompt handling. Returns success.
    private func perform(title: String, args: [String], input: String? = nil, quiet: Bool = false) async -> Bool {
        guard !busy else {
            if !quiet { errorMessage = "Already working on something — wait a moment." }
            return false
        }
        busy = true
        let handle = EngineHandle()
        currentRun = handle
        withAnimation(.snappy) { activity = Activity(title: title, stage: "Starting…", percent: 0) }
        defer {
            busy = false
            currentRun = nil
            withAnimation(.snappy) { activity = nil }
        }
        do {
            try await Engine.run(
                args,
                input: input,
                handle: handle,
                onEvent: { [weak self] event in
                    guard let self, var act = self.activity else { return }
                    if event["type"] as? String == "cancellable" {
                        act.cancellable = event["value"] as? Bool ?? true
                    } else {
                        act.stage = event["stage"] as? String ?? act.stage
                        act.percent = Double(event["percent"] as? Int ?? Int(act.percent))
                    }
                    withAnimation(.smooth) { self.activity = act }
                },
                onPrompt: { [weak self] event in
                    await self?.ask(event) ?? ""
                }
            )
            return true
        } catch is CancellationError {
            showToast("Stopped")
            return false
        } catch {
            if quiet {
                notify("Refresh failed", error.localizedDescription)
            } else {
                errorMessage = error.localizedDescription
            }
            return false
        }
    }

    private func ask(_ event: JSON) async -> String {
        await withCheckedContinuation { continuation in
            let respond: (String) -> Void = { [weak self] answer in
                self?.prompt = nil
                continuation.resume(returning: answer)
            }
            switch event["kind"] as? String {
            case "two_factor":
                let phones = ((event["phones"] as? [JSON]) ?? []).map {
                    (id: $0["id"] as? Int ?? 0, lastTwo: $0["lastTwo"] as? String ?? "")
                }
                prompt = PendingPrompt(kind: .twoFactor(method: event["method"] as? String ?? "device", phones: phones), respond: respond)
            default:
                prompt = PendingPrompt(
                    kind: .confirm(title: event["title"] as? String ?? "Confirm", message: event["message"] as? String ?? ""),
                    respond: respond
                )
            }
        }
    }

    func showToast(_ text: String) {
        withAnimation(.snappy) { toast = text }
        Task {
            try? await Task.sleep(nanoseconds: 3_000_000_000)
            withAnimation(.snappy) { if toast == text { toast = nil } }
        }
    }

    private func notify(_ title: String, _ body: String) {
        guard Pref.bool(Pref.notifications, default: true) else { return }
        let content = UNMutableNotificationContent()
        content.title = title
        content.body = body
        UNUserNotificationCenter.current().add(UNNotificationRequest(identifier: UUID().uuidString, content: content, trigger: nil))
    }
}
