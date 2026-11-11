import SwiftUI
import UniformTypeIdentifiers

struct ContentView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage(Pref.didOnboard) private var didOnboard = false

    var body: some View {
        VStack(spacing: 0) {
            HeaderBar()
            DeviceStrip()
                .padding(.horizontal, 24)
                .padding(.bottom, 18)

            HStack(alignment: .top, spacing: 20) {
                VStack(spacing: 18) {
                    DropZone()
                    LibraryPanel()
                }
                .frame(maxWidth: .infinity)

                MyAppsPanel()
                    .frame(width: 330)
            }
            .padding(.horizontal, 24)
            .padding(.bottom, 24)
        }
        .background(Theme.background)
        .overlay(alignment: .bottom) { ActivityBar() }
        .overlay(alignment: .top) { ToastView() }
        .sheet(isPresented: $model.showLogin) { LoginSheet() }
        .sheet(isPresented: Binding(get: { !didOnboard }, set: { if !$0 { didOnboard = true } })) { WelcomeView() }
        .sheet(item: $model.advancedFile) { file in AdvancedInstallSheet(file: file) }
        .sheet(item: twoFactorBinding) { prompt in TwoFactorSheet(prompt: prompt) }
        .alert(confirmTitle, isPresented: confirmPresented, presenting: model.prompt) { prompt in
            Button("Continue", role: .destructive) { prompt.respond("yes") }
            Button("Cancel", role: .cancel) { prompt.respond("no") }
        } message: { prompt in
            if case .confirm(_, let message) = prompt.kind { Text(message) }
        }
        .alert("Something went wrong", isPresented: Binding(
            get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } }
        )) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }

    private var twoFactorBinding: Binding<PendingPrompt?> {
        Binding(
            // During login the code is entered inside the login sheet itself.
            get: {
                if !model.showLogin, case .twoFactor = model.prompt?.kind { return model.prompt }
                return nil
            },
            set: { _ in }
        )
    }

    private var confirmPresented: Binding<Bool> {
        Binding(
            get: { if case .confirm = model.prompt?.kind { return true } else { return false } },
            set: { _ in }
        )
    }

    private var confirmTitle: String {
        if case .confirm(let title, _) = model.prompt?.kind { return title }
        return ""
    }
}

// MARK: - Header

struct HeaderBar: View {
    @EnvironmentObject var model: AppModel
    @State private var showAccount = false

    var body: some View {
        HStack(spacing: 12) {
            Image(nsImage: NSApp.applicationIconImage)
                .resizable()
                .frame(width: 40, height: 40)
            Text("GatePass")
                .font(.system(size: 20, weight: .bold, design: .rounded))

            Spacer()

            SettingsLink {
                Image(systemName: "gearshape")
                    .font(.system(size: 15, weight: .medium))
                    .foregroundStyle(.secondary)
                    .frame(width: 34, height: 34)
                    .background(Circle().fill(Theme.card))
                    .contentShape(Circle())
            }
            .buttonStyle(.plain)
            .help("Settings (⌘,)")

            if let account = model.account {
                Button { showAccount.toggle() } label: {
                    HStack(spacing: 10) {
                        Avatar(account: account, size: 34)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(account.firstName.isEmpty ? "Apple ID" : account.firstName)
                                .font(.system(size: 13, weight: .semibold))
                            Text(account.email)
                                .font(.system(size: 11))
                                .foregroundStyle(.secondary)
                        }
                        QuotaChip()
                    }
                    .padding(.leading, 5)
                    .padding(.trailing, 6)
                    .padding(.vertical, 5)
                    .background(Capsule().fill(Theme.card))
                    .overlay(Capsule().strokeBorder(Color.primary.opacity(showAccount ? 0.18 : 0.06)))
                    .contentShape(Capsule())
                }
                .buttonStyle(.plain)
                .popover(isPresented: $showAccount, arrowEdge: .bottom) {
                    AccountPopover().environmentObject(model)
                }
                .onChange(of: showAccount) { _, v in if v { Task { await model.loadQuota() } } }
            } else {
                Button {
                    model.showLogin = true
                } label: {
                    Label("Sign in with Apple ID", systemImage: "person.crop.circle")
                }
                .buttonStyle(PillButtonStyle())
            }
        }
        .padding(.horizontal, 24)
        .padding(.top, 30)
        .padding(.bottom, 18)
    }
}

struct Avatar: View {
    let account: Account
    let size: CGFloat

    var body: some View {
        Circle()
            .fill(Theme.accentGradient)
            .frame(width: size, height: size)
            .overlay(
                Text(account.initials)
                    .font(.system(size: size * 0.42, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            )
    }
}

/// Bold pill on the right of the profile: how many App IDs are left this week.
struct QuotaChip: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        HStack(spacing: 5) {
            Image(systemName: "signature")
                .font(.system(size: 12, weight: .bold))
            if let q = model.quota {
                Text("\(q.available)/\(q.max)")
                    .font(.system(size: 12, weight: .bold, design: .rounded))
                    .monospacedDigit()
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 10)
        .frame(height: 30)
        .background(Capsule().fill(chipFill))
        .help("Signatures (App IDs) left this week")
    }

    private var chipFill: AnyShapeStyle {
        guard let q = model.quota else { return AnyShapeStyle(Theme.accentGradient) }
        if q.available == 0 { return AnyShapeStyle(Color.red) }
        if q.available <= 2 { return AnyShapeStyle(Color.orange) }
        return AnyShapeStyle(Theme.accentGradient)
    }
}

struct AccountPopover: View {
    @EnvironmentObject var model: AppModel
    @State private var launchAtLogin = LaunchAtLogin.isEnabled

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            if let account = model.account {
                HStack(spacing: 12) {
                    Avatar(account: account, size: 46)
                    VStack(alignment: .leading, spacing: 2) {
                        Text(account.firstName.isEmpty ? "Apple ID" : account.firstName)
                            .font(.system(size: 15, weight: .bold))
                        Text(account.email).font(.system(size: 12)).foregroundStyle(.secondary)
                        Text("Free account").font(.system(size: 11)).foregroundStyle(.tertiary)
                    }
                }
            }

            VStack(alignment: .leading, spacing: 10) {
                HStack {
                    Text("Signatures this week").font(.system(size: 13, weight: .semibold))
                    Spacer()
                    if model.quotaLoading { ProgressView().controlSize(.mini) }
                }
                if let q = model.quota {
                    HStack(alignment: .firstTextBaseline, spacing: 4) {
                        Text("\(q.available)")
                            .font(.system(size: 34, weight: .bold, design: .rounded))
                            .foregroundStyle(q.available == 0 ? AnyShapeStyle(Color.red) : AnyShapeStyle(Theme.accentGradient))
                        Text("of \(q.max) available\(q.exact ? "" : " (estimate)")")
                            .font(.system(size: 13))
                            .foregroundStyle(.secondary)
                    }
                    ProgressView(value: Double(q.max - q.available), total: Double(max(q.max, 1)))
                        .tint(q.available <= 2 ? .orange : Theme.accent)
                    Text("Each new app uses one App ID (extensions use extra ones). A slot frees up 7 days after the App ID was created. Refreshing existing apps uses nothing.")
                        .font(.system(size: 11))
                        .foregroundStyle(.secondary)
                        .fixedSize(horizontal: false, vertical: true)

                    if !q.devices.isEmpty {
                        Divider()
                        Text("Active apps per device").font(.system(size: 13, weight: .semibold))
                        ForEach(q.devices, id: \.udid) { d in
                            HStack {
                                Text(d.name).font(.system(size: 12))
                                Spacer()
                                Text("\(d.active) / \(d.limit)")
                                    .font(.system(size: 12, weight: .semibold, design: .rounded))
                                    .foregroundStyle(d.active >= d.limit ? .orange : .secondary)
                            }
                        }
                    }
                } else if let err = model.quotaError {
                    Text(err).font(.system(size: 11)).foregroundStyle(.orange)
                        .fixedSize(horizontal: false, vertical: true)
                } else {
                    Text("Loading…").font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }
            .padding(14)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.card))

            Toggle("Open GatePass at login", isOn: $launchAtLogin)
                .font(.system(size: 12))
                .onChange(of: launchAtLogin) { _, v in LaunchAtLogin.set(v) }

            HStack {
                Button("Sign Out", role: .destructive) { Task { await model.logout() } }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.red)
                Spacer()
                Button { Task { await model.loadQuota() } } label: { Label("Refresh", systemImage: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .disabled(model.quotaLoading)
            }
            .font(.system(size: 12))
        }
        .padding(18)
        .frame(width: 320)
    }
}

// MARK: - Devices

struct DeviceStrip: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if model.devices.isEmpty {
            HStack(spacing: 14) {
                Image(systemName: "cable.connector")
                    .font(.system(size: 20))
                    .foregroundStyle(.secondary)
                VStack(alignment: .leading, spacing: 2) {
                    Text("No devices").font(.system(size: 14, weight: .semibold))
                    Text("Connect your iPhone by cable, or keep it unlocked on the same Wi-Fi network.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                }
                Spacer()
                ProgressView().controlSize(.small)
            }
            .padding(16)
            .background(RoundedRectangle(cornerRadius: 14, style: .continuous).fill(Theme.card))
        } else {
            ScrollView(.horizontal, showsIndicators: false) {
                HStack(spacing: 12) {
                    ForEach(model.devices) { device in
                        DeviceCard(device: device, selected: device.udid == model.selectedDevice?.udid)
                            .onTapGesture { withAnimation(.snappy) { model.selectedDeviceID = device.udid } }
                    }
                }
            }
        }
    }
}

struct DeviceCard: View {
    let device: Device
    let selected: Bool

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: device.symbol)
                .font(.system(size: 22, weight: .regular))
                .frame(width: 30)
                .foregroundStyle(selected ? .white : .primary)
            VStack(alignment: .leading, spacing: 2) {
                Text(device.name)
                    .font(.system(size: 13, weight: .semibold))
                    .foregroundStyle(selected ? .white : .primary)
                HStack(spacing: 4) {
                    Image(systemName: device.isWireless ? "wifi" : "cable.connector.horizontal")
                        .font(.system(size: 9, weight: .bold))
                    Text(device.subtitle)
                }
                .font(.system(size: 11))
                .foregroundStyle(selected ? .white.opacity(0.8) : .secondary)
            }
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 11)
        .background(
            RoundedRectangle(cornerRadius: 14, style: .continuous)
                .fill(selected ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Theme.card))
        )
        .contentShape(Rectangle())
    }
}

// MARK: - Drop zone

struct DropZone: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var library: Library
    @AppStorage(Pref.devMode) private var devMode = false
    @State private var targeted = false

    var body: some View {
        VStack(spacing: 0) {
            if model.staged.isEmpty {
                emptyState
            } else {
                stagedList
                Divider().opacity(0.5)
                bottomBar
            }
        }
        .frame(maxWidth: .infinity)
        .frame(minHeight: 150)
        .background(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .fill(targeted ? Theme.accent.opacity(0.10) : Theme.card)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 18, style: .continuous)
                .strokeBorder(targeted ? Theme.accent : Color.secondary.opacity(0.25),
                              style: StrokeStyle(lineWidth: 1.5, dash: [7, 5]))
                .allowsHitTesting(false)
        )
        .overlay(alignment: .topTrailing) {
            if devMode && model.staged.isEmpty { advancedButton.padding(12) }
        }
        .animation(.snappy, value: targeted)
        .animation(.snappy, value: model.staged.count)
        .onDrop(of: [.fileURL], isTargeted: $targeted) { providers in
            Task { @MainActor in
                var urls: [URL] = []
                for provider in providers {
                    if let url = await loadURL(provider) { urls.append(url) }
                }
                await model.stage(urls)
            }
            return true
        }
    }

    // Nothing chosen yet: the whole area is a click target.
    private var emptyState: some View {
        VStack(spacing: 10) {
            Image(systemName: "arrow.down.doc.fill")
                .font(.system(size: 30, weight: .medium))
                .foregroundStyle(Theme.accentGradient)
                .scaleEffect(targeted ? 1.15 : 1)
            Text(targeted ? "Drop here" : "Drop IPA files here")
                .font(.system(size: 15, weight: .semibold))
            Text("or click to choose · several at once is fine")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
        }
        .frame(maxWidth: .infinity, minHeight: 150)
        .contentShape(Rectangle())
        .onTapGesture { pickFiles() }
    }

    private var stagedList: some View {
        ScrollView {
            VStack(spacing: 2) {
                ForEach(model.staged) { file in
                    HStack(spacing: 10) {
                        AppIcon(url: file.iconURL, name: file.name, size: 30)
                        VStack(alignment: .leading, spacing: 1) {
                            Text(library.displayName(file)).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                            Text([file.version.map { "v\($0)" }, file.fileSize].compactMap { $0 }.joined(separator: " · "))
                                .font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Button { model.unstage(file) } label: {
                            Image(systemName: "xmark.circle.fill").foregroundStyle(.secondary)
                        }
                        .buttonStyle(.borderless)
                        .disabled(model.isBusy)
                        .help("Remove")
                    }
                    .padding(.horizontal, 14)
                    .padding(.vertical, 6)
                }
            }
            .padding(.vertical, 8)
        }
        .frame(maxHeight: 190)
        .fixedSize(horizontal: false, vertical: model.staged.count <= 4)
    }

    private var bottomBar: some View {
        HStack(spacing: 14) {
            Button { pickFiles() } label: {
                Label("Add more", systemImage: "plus").font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.borderless)
            .disabled(model.isBusy)
            if devMode { advancedButton }
            Spacer()
            if let d = model.selectedDevice {
                Text("on \(d.name)").font(.system(size: 12)).foregroundStyle(.secondary)
            }
            Button(model.staged.count > 1 ? "Install All (\(model.staged.count))" : "Install") {
                Task { await model.installStaged() }
            }
            .buttonStyle(PillButtonStyle())
            .disabled(model.isBusy || model.selectedDevice == nil)
        }
        .padding(.horizontal, 14)
        .padding(.vertical, 10)
    }

    private var advancedButton: some View {
        Button {
            if let only = model.staged.first, model.staged.count == 1 {
                model.advancedFile = only
            } else {
                pickFiles(advanced: true)
            }
        } label: {
            Label("Advanced…", systemImage: "slider.horizontal.3").font(.system(size: 12, weight: .medium))
        }
        .buttonStyle(.borderless)
        .foregroundStyle(.secondary)
        .disabled(model.isBusy || model.staged.count > 1)
        .help(model.staged.count > 1 ? "Advanced options work with one IPA at a time" : "Install with advanced options")
    }

    private func pickFiles(advanced: Bool = false) {
        let panel = NSOpenPanel()
        panel.allowedContentTypes = [UTType(filenameExtension: "ipa"), UTType(filenameExtension: "tipa")].compactMap { $0 }
        panel.allowsMultipleSelection = !advanced
        guard panel.runModal() == .OK else { return }
        let urls = panel.urls
        Task {
            if advanced, let url = urls.first {
                model.advancedFile = await model.library.info(for: url)
            } else {
                await model.stage(urls)
            }
        }
    }

    private func loadURL(_ provider: NSItemProvider) async -> URL? {
        await withCheckedContinuation { cont in
            _ = provider.loadObject(ofClass: URL.self) { url, _ in cont.resume(returning: url) }
        }
    }
}

// MARK: - Library

struct LibraryPanel: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var library: Library
    @State private var tab = 0

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Picker("", selection: $tab) {
                    Text("Recent").tag(0)
                    Text("My Folder").tag(1)
                }
                .pickerStyle(.segmented)
                .labelsHidden()
                .frame(width: 220)
                Spacer()
                if tab == 1 {
                    if let folder = library.folder {
                        Text(folder.lastPathComponent)
                            .font(.system(size: 12))
                            .foregroundStyle(.secondary)
                    }
                    Button(library.folder == nil ? "Choose Folder" : "Change") { chooseFolder() }
                        .buttonStyle(.link)
                        .font(.system(size: 12))
                    Button { library.reload() } label: { Image(systemName: "arrow.clockwise") }
                        .buttonStyle(.borderless)
                        .help("Refresh")
                }
            }

            let files = tab == 0 ? library.recent : library.folderFiles
            if files.isEmpty {
                EmptyLibrary(tab: tab, choose: chooseFolder)
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(files) { file in
                            IPARow(file: file, canRemove: tab == 0, canDelete: tab == 1)
                        }
                    }
                }
            }
        }
        .padding(16)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.card))
    }

    private func chooseFolder() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.prompt = "Choose"
        if panel.runModal() == .OK, let url = panel.url { library.setFolder(url) }
    }
}

struct EmptyLibrary: View {
    let tab: Int
    let choose: () -> Void

    var body: some View {
        VStack(spacing: 8) {
            Image(systemName: tab == 0 ? "clock" : "folder")
                .font(.system(size: 22))
                .foregroundStyle(.tertiary)
            Text(tab == 0 ? "IPA files you install will show up here." : "Choose the folder where you keep your IPA files.")
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .multilineTextAlignment(.center)
            if tab == 1 {
                Button("Choose Folder", action: choose).buttonStyle(PillButtonStyle())
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .padding(.vertical, 24)
    }
}

struct IPARow: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var library: Library
    @AppStorage(Pref.devMode) private var devMode = false
    let file: IPAFile
    let canRemove: Bool
    var canDelete = false
    @State private var confirmDelete = false
    @State private var hover = false
    @State private var editing = false
    @State private var draft = ""
    @FocusState private var fieldFocused: Bool

    var body: some View {
        HStack(spacing: 12) {
            AppIcon(url: file.iconURL, name: library.displayName(file), size: 38)
            VStack(alignment: .leading, spacing: 2) {
                if editing {
                    TextField(file.name, text: $draft)
                        .textFieldStyle(.plain)
                        .font(.system(size: 13, weight: .semibold))
                        .padding(.horizontal, 6)
                        .padding(.vertical, 2)
                        .background(RoundedRectangle(cornerRadius: 6).fill(Theme.card))
                        .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Theme.accent.opacity(0.6)))
                        .focused($fieldFocused)
                        .onSubmit(commit)
                        .onExitCommand { editing = false }
                        .onChange(of: fieldFocused) { _, v in if !v && editing { commit() } }
                } else {
                    HStack(spacing: 5) {
                        Text(library.displayName(file))
                            .font(.system(size: 13, weight: .semibold))
                            .lineLimit(1)
                        if library.hasAlias(file) {
                            Image(systemName: "tag.fill")
                                .font(.system(size: 8))
                                .foregroundStyle(Theme.accent)
                                .help("Name set in GatePass")
                        }
                    }
                    .onTapGesture(count: 2, perform: startEditing)
                }
                // Original file name stays visible, so you always know which file it is.
                Text(file.url.lastPathComponent)
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .truncationMode(.middle)
                    .help(file.url.path)
                Text(details)
                    .font(.system(size: 10))
                    .foregroundStyle(.tertiary)
            }
            Spacer()
            if hover && !editing {
                Button(action: startEditing) { Image(systemName: "pencil") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Rename (only in GatePass)")
            }
            if hover && canRemove {
                Button { library.removeRecent(file) } label: { Image(systemName: "xmark") }
                    .buttonStyle(.borderless)
                    .foregroundStyle(.secondary)
                    .help("Remove from list")
            }
            Button("Install") { Task { await model.install(file) } }
                .buttonStyle(PillButtonStyle(compact: true))
                .disabled(model.isBusy || model.selectedDevice == nil)
            if canDelete {
                Button { confirmDelete = true } label: {
                    Image(systemName: "xmark.circle.fill").font(.system(size: 14))
                }
                .buttonStyle(.borderless)
                .foregroundStyle(.secondary.opacity(hover ? 1 : 0.5))
                .help("Delete IPA")
            }
        }
        .alert("Delete \(library.displayName(file))?", isPresented: $confirmDelete) {
            Button("Delete", role: .destructive) {
                do { try library.trash(file) } catch { model.errorMessage = "Couldn't delete: \(error.localizedDescription)" }
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("\(file.url.lastPathComponent) will be moved to the Trash, where you can restore it.")
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(hover ? Color.primary.opacity(0.05) : .clear))
        .onHover { hover = $0 }
        .contextMenu {
            if devMode {
                Button("Install with Options…") { model.advancedFile = file }
                Divider()
            }
            Button("Rename…", action: startEditing)
            if library.hasAlias(file) {
                Button("Restore Original Name") { library.setAlias(nil, for: file) }
            }
            Divider()
            Button("Show in Finder") { NSWorkspace.shared.activateFileViewerSelecting([file.url]) }
        }
    }

    private var details: String {
        var parts: [String] = []
        if library.hasAlias(file) { parts.append(file.name) }
        if let v = file.version { parts.append("v\(v)") }
        parts.append(file.fileSize)
        return parts.joined(separator: " · ")
    }

    private func startEditing() {
        draft = library.displayName(file)
        editing = true
        DispatchQueue.main.async { fieldFocused = true }
    }

    private func commit() {
        library.setAlias(draft, for: file)
        editing = false
    }
}

// MARK: - My apps

struct MyAppsPanel: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var library: Library

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            HStack {
                Text("My Apps").font(.system(size: 15, weight: .bold))
                Spacer()
                if let d = model.selectedDevice, model.trackedApps.contains(where: { $0.deviceUDID == d.udid }) {
                    Button("Refresh All") { Task { await model.refreshAll(on: d.udid) } }
                        .buttonStyle(.link)
                        .font(.system(size: 12))
                        .disabled(model.isBusy)
                }
            }

            if model.trackedApps.isEmpty {
                VStack(spacing: 8) {
                    Image(systemName: "sparkles")
                        .font(.system(size: 22))
                        .foregroundStyle(.tertiary)
                    Text("Installed apps will show up here. GatePass refreshes them automatically when the device connects.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                }
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .padding()
            } else {
                ScrollView {
                    LazyVStack(spacing: 6) {
                        ForEach(model.trackedApps) { app in
                            TrackedAppRow(app: app, icon: iconFor(app), displayName: library.alias(forBundleId: app.bundleId) ?? app.name)
                        }
                    }
                }
            }

            HStack(spacing: 6) {
                Circle().fill(model.account == nil ? .orange : .green).frame(width: 6, height: 6)
                Text(model.account == nil ? "Sign in to enable auto-refresh" : "Auto-refresh is on")
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
            }
        }
        .padding(16)
        .frame(maxHeight: .infinity, alignment: .top)
        .background(RoundedRectangle(cornerRadius: 18, style: .continuous).fill(Theme.card))
    }

    private func iconFor(_ app: TrackedApp) -> URL? {
        (library.recent + library.folderFiles).first { $0.bundleId == app.bundleId && $0.iconURL != nil }?.iconURL
    }
}

struct TrackedAppRow: View {
    @EnvironmentObject var model: AppModel
    let app: TrackedApp
    let icon: URL?
    let displayName: String
    @State private var hover = false

    var body: some View {
        HStack(spacing: 12) {
            AppIcon(url: icon, name: displayName, size: 38)
            VStack(alignment: .leading, spacing: 2) {
                Text(displayName).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                HStack(spacing: 4) {
                    if !model.isConnected(app.deviceUDID) {
                        Image(systemName: "bolt.horizontal.circle").font(.system(size: 9))
                    }
                    Text(app.deviceName)
                }
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
            }
            Spacer()
            if hover {
                Button { Task { await model.refresh(app) } } label: { Image(systemName: "arrow.clockwise") }
                    .buttonStyle(.borderless)
                    .disabled(model.isBusy || !model.isConnected(app.deviceUDID))
                    .help(model.isConnected(app.deviceUDID) ? "Refresh now" : "Device not connected")
            }
            DaysLeftBadge(days: app.daysLeft, expired: app.isExpired)
        }
        .padding(8)
        .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(hover ? Color.primary.opacity(0.05) : .clear))
        .onHover { hover = $0 }
        .contextMenu {
            Button("Refresh Now") { Task { await model.refresh(app) } }
                .disabled(!model.isConnected(app.deviceUDID))
            Divider()
            Button("Stop Tracking", role: .destructive) { Task { await model.forget(app) } }
        }
    }
}

struct DaysLeftBadge: View {
    let days: Int?
    let expired: Bool

    var body: some View {
        let d = days ?? 0
        let color: Color = expired ? .red : (d <= 2 ? .orange : .green)
        ZStack {
            Circle().stroke(color.opacity(0.18), lineWidth: 3)
            Circle()
                .trim(from: 0, to: expired ? 1 : CGFloat(min(d, 7)) / 7)
                .stroke(color, style: StrokeStyle(lineWidth: 3, lineCap: .round))
                .rotationEffect(.degrees(-90))
            Text(expired ? "!" : "\(d)d")
                .font(.system(size: 10, weight: .bold, design: .rounded))
                .foregroundStyle(color)
        }
        .frame(width: 32, height: 32)
        .help(expired ? "Expired — connect the device to refresh" : "Expires in \(d) days")
    }
}

// MARK: - Shared bits

struct AppIcon: View {
    let url: URL?
    let name: String
    let size: CGFloat

    var body: some View {
        Group {
            if let url, let image = NSImage(contentsOf: url) {
                Image(nsImage: image).resizable().interpolation(.high)
            } else {
                ZStack {
                    Theme.accentGradient
                    Text(String(name.prefix(1)).uppercased())
                        .font(.system(size: size * 0.42, weight: .bold, design: .rounded))
                        .foregroundStyle(.white)
                }
            }
        }
        .frame(width: size, height: size)
        .clipShape(RoundedRectangle(cornerRadius: size * 0.225, style: .continuous))
    }
}

struct ActivityBar: View {
    @EnvironmentObject var model: AppModel
    @State private var confirmStop = false

    var body: some View {
        if let activity = model.activity {
            VStack(spacing: 12) {
                HStack(spacing: 14) {
                    ProgressView().controlSize(.small)
                    VStack(alignment: .leading, spacing: 6) {
                        HStack {
                            Text(activity.title).font(.system(size: 13, weight: .semibold))
                            Spacer()
                            Text("\(Int(activity.percent))%")
                                .font(.system(size: 12, weight: .medium, design: .rounded))
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                        ProgressView(value: activity.percent, total: 100)
                            .progressViewStyle(.linear)
                            .tint(Theme.accent)
                        Text(activity.cancellable ? activity.stage : activity.stage + " · don't stop now")
                            .font(.system(size: 11)).foregroundStyle(.secondary)
                    }
                    Button { withAnimation(.snappy) { confirmStop = true } } label: {
                        Image(systemName: "stop.fill")
                            .font(.system(size: 10, weight: .bold))
                            .frame(width: 26, height: 26)
                            .background(Circle().fill(Color.primary.opacity(0.08)))
                    }
                    .buttonStyle(.plain)
                    .opacity(activity.cancellable ? 1 : 0.35)
                    .disabled(!activity.cancellable || confirmStop)
                    .help(activity.cancellable ? "Stop" : "This step can't be stopped safely — it'll be done in a moment")
                }

                if confirmStop {
                    HStack(spacing: 10) {
                        Text("Stop?").font(.system(size: 12, weight: .medium))
                        Spacer()
                        Button("Keep going") { withAnimation(.snappy) { confirmStop = false } }
                            .buttonStyle(.bordered)
                            .controlSize(.small)
                        Button("Stop") {
                            model.cancelCurrent()
                            withAnimation(.snappy) { confirmStop = false }
                        }
                        .buttonStyle(PillButtonStyle(compact: true))
                        .disabled(!activity.cancellable)
                    }
                    .transition(.opacity.combined(with: .move(edge: .bottom)))
                }
            }
            .padding(16)
            .frame(maxWidth: 520)
            .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 16, style: .continuous))
            .shadow(color: .black.opacity(0.15), radius: 20, y: 8)
            .padding(.bottom, 20)
            .transition(.move(edge: .bottom).combined(with: .opacity))
            .onDisappear { confirmStop = false }
        }
    }
}

struct ToastView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        if let toast = model.toast {
            Text(toast)
                .font(.system(size: 13, weight: .semibold))
                .padding(.horizontal, 16)
                .padding(.vertical, 10)
                .background(.regularMaterial, in: Capsule())
                .shadow(color: .black.opacity(0.12), radius: 12, y: 4)
                .padding(.top, 14)
                .transition(.move(edge: .top).combined(with: .opacity))
        }
    }
}

struct PillButtonStyle: ButtonStyle {
    var compact = false
    @Environment(\.isEnabled) private var enabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.system(size: compact ? 12 : 13, weight: .semibold))
            .foregroundStyle(.white)
            .padding(.horizontal, compact ? 12 : 16)
            .padding(.vertical, compact ? 5 : 8)
            .background(Capsule().fill(Theme.accentGradient))
            .opacity(enabled ? (configuration.isPressed ? 0.8 : 1) : 0.4)
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .animation(.snappy(duration: 0.15), value: configuration.isPressed)
    }
}

enum Theme {
    // Emerald -> teal, matching the app icon.
    static let accent = Color(red: 0.06, green: 0.73, blue: 0.51)
    static let accentGradient = LinearGradient(
        colors: [Color(red: 0.13, green: 0.80, blue: 0.56), Color(red: 0.03, green: 0.57, blue: 0.70)],
        startPoint: .topLeading, endPoint: .bottomTrailing
    )
    static let background = Color(nsColor: .windowBackgroundColor)
    /// Subtle raised surface that reads well in both light and dark mode.
    static let card = Color.primary.opacity(0.055)
}
