import SwiftUI

// MARK: - Apple IDs in the account popover

/// Every signed-in Apple ID. Clicking one makes it the Apple ID for new installs; apps already
/// installed keep refreshing with the Apple ID that installed them.
struct AccountList: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmSignOut: Account?

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("Apple IDs").font(.system(size: 13, weight: .semibold))
                Spacer()
                Text("Free accounts").font(.system(size: 11)).foregroundStyle(.tertiary)
            }

            VStack(spacing: 4) {
                ForEach(model.accounts) { account in
                    AccountRow(account: account, current: account.email == model.account?.email,
                               appCount: model.apps(of: account.email).count) {
                        Task { await model.switchAccount(to: account) }
                    } onSignOut: {
                        confirmSignOut = account
                    }
                }
            }

            Button {
                dismiss()
                model.addAccount()
            } label: {
                Label("Add Apple ID…", systemImage: "plus.circle.fill")
                    .font(.system(size: 12, weight: .medium))
            }
            .buttonStyle(.borderless)
            .padding(.leading, 4)
            .padding(.top, 2)

            Text(model.accounts.count > 1
                 ? "New installs use the checked Apple ID. Each app keeps refreshing with the Apple ID that installed it."
                 : "Add a second Apple ID when this one runs out of signatures.")
                .font(.system(size: 11))
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .alert(signOutTitle, isPresented: Binding(get: { confirmSignOut != nil }, set: { if !$0 { confirmSignOut = nil } }),
               presenting: confirmSignOut) { account in
            Button("Sign Out", role: .destructive) { Task { await model.logout(account) } }
            Button("Cancel", role: .cancel) {}
        } message: { account in
            Text(signOutMessage(account))
        }
    }

    private var signOutTitle: String { "Sign out of \(confirmSignOut?.email ?? "this Apple ID")?" }

    private func signOutMessage(_ account: Account) -> String {
        let apps = model.apps(of: account.email)
        guard !apps.isEmpty else { return "You can sign in again any time." }
        let names = apps.map(\.name).joined(separator: ", ")
        return "\(names) \(apps.count == 1 ? "refreshes" : "refresh") with this Apple ID. After signing out GatePass can't refresh \(apps.count == 1 ? "it" : "them") until you sign in again or move \(apps.count == 1 ? "it" : "them") to another Apple ID."
    }
}

struct AccountRow: View {
    let account: Account
    let current: Bool
    let appCount: Int
    let onSelect: () -> Void
    let onSignOut: () -> Void
    @State private var hover = false

    var body: some View {
        HStack(spacing: 10) {
            Button(action: onSelect) {
                HStack(spacing: 10) {
                    AccountBadge(email: account.email, initials: account.initials, size: 30)
                    VStack(alignment: .leading, spacing: 1) {
                        Text(account.displayName).font(.system(size: 13, weight: .semibold)).lineLimit(1)
                        Text(account.email)
                            .font(.system(size: 11))
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                    }
                    Spacer(minLength: 4)
                    if appCount > 0 {
                        Text("\(appCount) app\(appCount == 1 ? "" : "s")")
                            .font(.system(size: 10, weight: .semibold))
                            .foregroundStyle(.secondary)
                            .padding(.horizontal, 6)
                            .padding(.vertical, 2)
                            .background(Capsule().fill(Color.primary.opacity(0.07)))
                    }
                    Image(systemName: current ? "checkmark.circle.fill" : "circle")
                        .font(.system(size: 15))
                        .foregroundStyle(current ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.tertiary))
                }
                .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help(current ? "New installs use this Apple ID" : "Use this Apple ID for new installs")

            Button(action: onSignOut) {
                Image(systemName: "rectangle.portrait.and.arrow.right")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
            .buttonStyle(.borderless)
            .opacity(hover ? 1 : 0)
            .help("Sign out of this Apple ID")
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .background(RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(current ? Theme.accent.opacity(0.10) : (hover ? Color.primary.opacity(0.05) : .clear)))
        .onHover { hover = $0 }
    }
}

/// Small circle with the Apple ID's initial; each Apple ID gets its own color so apps in the
/// list are easy to match to their Apple ID.
struct AccountBadge: View {
    let email: String
    let initials: String
    let size: CGFloat

    var body: some View {
        Circle()
            .fill(AccountBadge.color(for: email).gradient)
            .frame(width: size, height: size)
            .overlay(
                Text(initials)
                    .font(.system(size: size * 0.45, weight: .bold, design: .rounded))
                    .foregroundStyle(.white)
            )
    }

    static func color(for email: String) -> Color {
        // Stable across launches (String.hashValue isn't).
        let sum = email.lowercased().unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xFFFF }
        let palette: [Color] = [
            Color(red: 0.06, green: 0.66, blue: 0.47), .blue, .purple, .orange, .pink, .teal, .indigo, .brown,
        ]
        return palette[sum % palette.count]
    }
}

// MARK: - Apple ID under each app

struct AppleIDLabel: View {
    @EnvironmentObject var model: AppModel
    let app: TrackedApp

    var body: some View {
        Button { model.resignApp = app } label: {
            HStack(spacing: 4) {
                if app.accountSignedIn, let email = app.account {
                    AccountBadge(email: email, initials: initial(email), size: 11)
                    Text(email).lineLimit(1).truncationMode(.middle)
                } else {
                    Image(systemName: "exclamationmark.circle.fill").foregroundStyle(.orange)
                    Text(app.account.map { "\($0) · signed out" } ?? "No Apple ID — choose one")
                        .lineLimit(1)
                        .truncationMode(.middle)
                        .foregroundStyle(.orange)
                }
            }
            .font(.system(size: 10.5))
            .foregroundStyle(.secondary)
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .help(app.accountSignedIn ? "Refreshes with this Apple ID. Click to use another one." : "Sign in again or choose another Apple ID")
    }

    private func initial(_ email: String) -> String {
        model.accounts.first { $0.email == email }?.initials ?? String(email.prefix(1)).uppercased()
    }
}

// MARK: - Refresh one app with another Apple ID

struct ResignSheet: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var library: Library
    @Environment(\.dismiss) private var dismiss
    let app: TrackedApp

    @State private var choice: Account?
    @State private var quotas: [String: Quota] = [:]
    @State private var loading: Set<String> = []

    private var name: String { library.alias(forBundleId: app.bundleId) ?? app.name }
    private var others: [Account] { model.accounts.filter { $0.email != app.account } }
    private var connected: Bool { model.isConnected(app.deviceUDID) }

    var body: some View {
        VStack(alignment: .leading, spacing: 16) {
            HStack(spacing: 12) {
                Image(systemName: "person.2.badge.gearshape.fill")
                    .font(.system(size: 26))
                    .foregroundStyle(Theme.accentGradient)
                VStack(alignment: .leading, spacing: 2) {
                    Text("Refresh \(name) with another Apple ID").font(.system(size: 16, weight: .bold))
                    current.font(.system(size: 12)).foregroundStyle(.secondary)
                }
            }

            if !app.accountSignedIn, let email = app.account {
                Button {
                    dismiss()
                    model.addAccount(email: email)
                } label: {
                    OptionCard(selected: false) {
                        Image(systemName: "key.fill").foregroundStyle(Theme.accent).frame(width: 30)
                        VStack(alignment: .leading, spacing: 1) {
                            Text("Sign in to \(email) again").font(.system(size: 13, weight: .semibold))
                            Text("Recommended: \(name) keeps its data.").font(.system(size: 11)).foregroundStyle(.secondary)
                        }
                        Spacer()
                        Image(systemName: "chevron.right").foregroundStyle(.tertiary)
                    }
                }
                .buttonStyle(.plain)
            }

            VStack(alignment: .leading, spacing: 6) {
                if !others.isEmpty {
                    Text(app.accountSignedIn ? "Sign with" : "Or move it to").font(.system(size: 12, weight: .semibold)).foregroundStyle(.secondary)
                }
                ForEach(others) { account in
                    let q = quotas[account.email]
                    let full = (q?.available ?? 1) == 0
                    Button { choice = account } label: {
                        OptionCard(selected: choice == account) {
                            AccountBadge(email: account.email, initials: account.initials, size: 30)
                            VStack(alignment: .leading, spacing: 1) {
                                Text(account.email).font(.system(size: 13, weight: .semibold)).lineLimit(1).truncationMode(.middle)
                                quotaLine(account)
                            }
                            Spacer()
                            Image(systemName: choice == account ? "checkmark.circle.fill" : "circle")
                                .font(.system(size: 16))
                                .foregroundStyle(choice == account ? AnyShapeStyle(Theme.accent) : AnyShapeStyle(.tertiary))
                        }
                    }
                    .buttonStyle(.plain)
                    .disabled(full)
                    .opacity(full ? 0.55 : 1)
                }
                Button {
                    dismiss()
                    model.addAccount(thenResign: app)
                } label: {
                    Label(others.isEmpty ? "Sign in to another Apple ID…" : "Another Apple ID…", systemImage: "plus.circle.fill")
                        .font(.system(size: 12, weight: .medium))
                }
                .buttonStyle(.borderless)
                .padding(.top, 2)
            }

            if let choice {
                HStack(alignment: .top, spacing: 10) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text("\(name) will be removed from \(app.deviceName) and installed again, signed by \(choice.email). Everything saved inside the app on the device (logins, downloads, settings) will be deleted. It uses at least one of this Apple ID's App IDs this week.")
                        .font(.system(size: 12))
                        .fixedSize(horizontal: false, vertical: true)
                }
                .padding(12)
                .background(RoundedRectangle(cornerRadius: 12, style: .continuous).fill(Color.orange.opacity(0.12)))
                .transition(.opacity.combined(with: .move(edge: .top)))
            }

            if !connected {
                Label("Connect \(app.deviceName) by cable or Wi-Fi to continue.", systemImage: "bolt.horizontal.circle")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            HStack {
                Button("Cancel") { dismiss() }
                    .keyboardShortcut(.cancelAction)
                    .buttonStyle(.borderless)
                Spacer()
                Button {
                    guard let choice else { return }
                    dismiss()
                    Task { await model.refresh(app, with: choice) }
                } label: {
                    Text(choice.map { "Reinstall with \($0.displayName)" } ?? "Choose an Apple ID")
                }
                .buttonStyle(PillButtonStyle())
                .keyboardShortcut(.defaultAction)
                .disabled(choice == nil || !connected || model.isBusy)
            }
        }
        .padding(24)
        .frame(width: 440)
        .animation(.snappy, value: choice)
        .task { await loadQuotas() }
    }

    @ViewBuilder private var current: some View {
        if let email = app.account, app.accountSignedIn {
            Text("Now signed by \(email) on \(app.deviceName).")
        } else if let email = app.account {
            Text("\(email) isn't signed in, so \(name) can't be refreshed.")
        } else {
            Text("GatePass doesn't know which Apple ID signed \(name).")
        }
    }

    @ViewBuilder private func quotaLine(_ account: Account) -> some View {
        if let q = quotas[account.email] {
            Text(q.available == 0 ? "No signatures left this week" : "\(q.available) of \(q.max) signatures left this week")
                .font(.system(size: 11))
                .foregroundStyle(q.available == 0 ? AnyShapeStyle(Color.red) : AnyShapeStyle(.secondary))
        } else if loading.contains(account.email) {
            HStack(spacing: 4) {
                ProgressView().controlSize(.mini)
                Text("Checking signatures…")
            }
            .font(.system(size: 11)).foregroundStyle(.secondary)
        } else {
            Text("Signatures unknown").font(.system(size: 11)).foregroundStyle(.secondary)
        }
    }

    private func loadQuotas() async {
        let list = others
        loading = Set(list.map(\.email))
        await withTaskGroup(of: (String, Quota?).self) { group in
            for a in list {
                group.addTask { (a.email, await model.quota(for: a.email)) }
            }
            for await (email, q) in group {
                loading.remove(email)
                if let q { quotas[email] = q }
            }
        }
        // Preselect when there's only one sensible choice.
        if choice == nil, list.count == 1, (quotas[list[0].email]?.available ?? 1) > 0 { choice = list[0] }
    }
}

private struct OptionCard<Content: View>: View {
    let selected: Bool
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 10) { content }
            .padding(10)
            .background(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .fill(selected ? Theme.accent.opacity(0.12) : Theme.card))
            .overlay(RoundedRectangle(cornerRadius: 12, style: .continuous)
                .strokeBorder(selected ? Theme.accent.opacity(0.6) : Color.primary.opacity(0.06)))
            .contentShape(Rectangle())
    }
}
