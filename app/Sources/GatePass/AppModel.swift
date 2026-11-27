import Foundation
import SwiftUI
import UserNotifications

/// A question the engine is waiting on (2FA code, Apple TV code, confirmation).
struct PendingPrompt: Identifiable {
    enum Kind { case twoFactor(method: String, phones: [(id: Int, lastTwo: String)]), confirm(title: String, message: String), pin }
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
    /// Every signed-in Apple ID; `account` is the one new installs use.
    @Published var accounts: [Account] = []
    /// The app the "Refresh with another Apple ID" sheet is open for.
    @Published var resignApp: TrackedApp?
    /// After signing in from that sheet, it opens again for this app.
    private var resignAfterLogin: TrackedApp?
    /// Prefilled in the sign-in sheet ("Sign in again" for a signed-out Apple ID).
    @Published var loginEmail = ""
    /// Apps already announced as "Apple ID signed out", so the notification comes once.
    private var announcedSignedOut = Set<String>()
    @Published var devices: [Device] = []
    @Published var selectedDeviceID: String?
    @Published var trackedApps: [TrackedApp] = []
    @Published var activity: Activity?
    @Published var prompt: PendingPrompt?
    @Published var errorMessage: String?
    @Published var toast: String?
    @Published var showLogin = false
    @Published var showPairTV = false
    /// Shown inside the Add Apple TV sheet (alerts can't appear on top of an open sheet).
    @Published var pairError: String?
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
        let all = list.map {
            Account(email: $0["email"] as? String ?? "", firstName: $0["firstName"] as? String ?? "",
                    teamId: $0["teamId"] as? String ?? "", selected: ($0["selected"] as? Bool) == true)
        }.sorted { $0.email < $1.email }
        if all != accounts { withAnimation(.snappy) { accounts = all } }
        let selected = all.first { $0.selected } ?? all.first
        if selected != account { account = selected }
    }

    func reloadDevices() async {
        guard !busy else { return }
        guard let result = try? await Engine.run(["devices"]),
              let list = result["devices"] as? [JSON] else { return }
        var seen = Set<String>()
        let fresh = list.compactMap(Device.init(json:)).filter {
            seen.insert($0.udid.replacingOccurrences(of: "-", with: "").uppercased()).inserted
        }
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
                    due: a["due"] as? Bool ?? false,
                    account: a["account"] as? String,
                    accountSignedIn: a["accountSignedIn"] as? Bool ?? true
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
            await reloadApps()
            showLogin = false
            loginEmail = ""
            Task { await loadQuota() }
            showToast("Signed in ✓")
            if let app = resignAfterLogin {
                resignAfterLogin = nil
                resignApp = trackedApps.first { $0.id == app.id } ?? app
            }
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

    /// Quota of any signed-in Apple ID (for the sheet that picks one).
    func quota(for email: String) async -> Quota? {
        guard let r = try? await Engine.run(["quota", "--email", email]) else { return nil }
        return Quota(json: r)
    }

    /// Makes another signed-in Apple ID the one new installs use. Apps keep their own Apple ID.
    func switchAccount(to target: Account) async {
        guard target.email != account?.email else { return }
        guard !busy else { errorMessage = "Already working on something — wait a moment."; return }
        do {
            _ = try await Engine.run(["select", "--email", target.email])
        } catch {
            errorMessage = error.localizedDescription
            return
        }
        quota = nil
        await reloadAccount()
        showToast("New installs now use \(target.email)")
        await loadQuota()
    }

    /// Opens the sign-in sheet for another Apple ID (the current ones stay signed in).
    func addAccount(email: String = "", thenResign app: TrackedApp? = nil) {
        loginError = nil
        loginEmail = email
        resignAfterLogin = app
        showLogin = true
    }

    /// Apps on this Mac that refresh with this Apple ID.
    func apps(of email: String) -> [TrackedApp] {
        trackedApps.filter { $0.account == email }
    }

    func logout(_ target: Account? = nil) async {
        guard let target = target ?? account else { return }
        _ = await perform(title: "Signing out", args: ["logout", "--email", target.email])
        quota = nil
        account = nil
        await reloadAccount()
        await reloadApps()
        if account != nil { await loadQuota() }
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

    /// Refreshes with the app's own Apple ID. If that one is signed out, asks which to use.
    func refresh(_ app: TrackedApp) async {
        guard app.accountSignedIn else { resignApp = app; return }
        let ok = await perform(
            title: "Refreshing \(app.name)",
            args: ["refresh", "--udid", app.deviceUDID, "--force", "--bundle-id", app.bundleId]
        )
        if ok {
            showToast("\(app.name) refreshed for 7 more days ✓")
            await reloadApps()
        }
    }

    /// Signs the app with another Apple ID. Another team means new identifiers, so iOS gets
    /// a different app: the old one is removed (with its data) and the new one installed.
    @discardableResult
    func refresh(_ app: TrackedApp, with target: Account) async -> Bool {
        let ok = await perform(
            title: "Moving \(app.name) to \(target.email)",
            args: ["refresh", "--udid", app.deviceUDID, "--force", "--bundle-id", app.bundleId, "--account", target.email]
        )
        if ok {
            notify("Moved", "\(app.name) is now signed with \(target.email) on \(app.deviceName).")
            showToast("\(app.name) now uses \(target.email) ✓")
            announcedSignedOut.remove(app.id)
            await reloadApps()
            if target.email == account?.email { await loadQuota() }
        }
        return ok
    }

    func refreshAll(on udid: String) async {
        var skipped = 0
        let ok = await perform(title: "Refreshing all apps", args: ["refresh", "--udid", udid, "--force"]) {
            skipped = ($0["skipped"] as? [Any])?.count ?? 0
        }
        guard ok else { return }
        await reloadApps()
        if skipped > 0 {
            showToast("Refreshed — \(skipped) app\(skipped == 1 ? "" : "s") skipped: Apple ID signed out")
        } else {
            showToast("All apps refreshed ✓")
        }
    }

    func forget(_ app: TrackedApp) async {
        _ = try? await Engine.run(["forget", "--udid", app.deviceUDID, "--bundle-id", app.bundleId])
        await reloadApps()
    }

    // MARK: Apple TV pairing

    /// Pairs an Apple TV with the code on its screen. Afterwards it shows up like any Wi-Fi device.
    func pairAppleTV(_ tv: PairableTV) async -> Bool {
        pairError = nil
        var result: JSON?
        let ok = await perform(
            title: "Pairing \(tv.name)",
            args: ["pair", "--host", tv.host, "--port", String(tv.port)],
            onDone: { result = $0 }
        )
        guard ok else {
            pairError = errorMessage ?? "Pairing failed."
            errorMessage = nil
            return false
        }
        let device = result?["device"] as? JSON
        let udid = device?["udid"] as? String
        let name = device?["name"] as? String ?? tv.name
        await reloadDevices()
        if let udid, devices.contains(where: { $0.udid == udid }) {
            selectedDeviceID = udid
            showToast("\(name) paired ✓")
        } else {
            showToast("\(name) paired ✓ — it will appear in a moment")
            Task {
                for _ in 0..<6 {
                    try? await Task.sleep(nanoseconds: 5_000_000_000)
                    await reloadDevices()
                    if let udid, devices.contains(where: { $0.udid == udid }) { selectedDeviceID = udid; break }
                }
            }
        }
        return true
    }

    func isConnected(_ udid: String) -> Bool { devices.contains { $0.udid == udid } }

    private func autoRefreshIfNeeded() async {
        guard !busy, account != nil, Pref.bool(Pref.autoRefresh, default: true) else { return }
        lastAutoCheck = .now
        // Apps whose Apple ID is signed out wait for the person: moving them deletes their data.
        for app in trackedApps where app.due && !app.accountSignedIn && !announcedSignedOut.contains(app.id) {
            announcedSignedOut.insert(app.id)
            notify("\(app.name) can't refresh",
                   "\(app.account ?? "Its Apple ID") isn't signed in. Open GatePass to sign in again or pick another Apple ID.")
        }
        let dueApps = trackedApps.filter { $0.due && $0.accountSignedIn && isConnected($0.deviceUDID) }
        let dueDevices = Set(dueApps.map(\.deviceUDID))
        for udid in dueDevices {
            let names = dueApps.filter { $0.deviceUDID == udid }.map(\.name)
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
    private func perform(title: String, args: [String], input: String? = nil, quiet: Bool = false, onDone: ((JSON) -> Void)? = nil) async -> Bool {
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
            let final = try await Engine.run(
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
            onDone?(final)
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
            // One-shot: SwiftUI can fire the answer twice (onChange re-runs after the code field
            // normalizes pasted "123 456", or Return hits Confirm after auto-submit). Resuming a
            // checked continuation twice is a fatal error, so later answers are ignored.
            var answered = false
            let respond: (String) -> Void = { [weak self] answer in
                guard !answered else { return }
                answered = true
                self?.prompt = nil
                continuation.resume(returning: answer)
            }
            switch event["kind"] as? String {
            case "two_factor":
                let phones = ((event["phones"] as? [JSON]) ?? []).map {
                    (id: $0["id"] as? Int ?? 0, lastTwo: $0["lastTwo"] as? String ?? "")
                }
                prompt = PendingPrompt(kind: .twoFactor(method: event["method"] as? String ?? "device", phones: phones), respond: respond)
            case "pin":
                prompt = PendingPrompt(kind: .pin, respond: respond)
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
