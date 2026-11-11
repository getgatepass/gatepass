import SwiftUI

/// First-launch walkthrough. Shown once; can be replayed from Settings.
struct WelcomeView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage(Pref.didOnboard) private var didOnboard = false
    @State private var page = 0

    private struct Page {
        let symbol: String
        let title: String
        let text: String
    }

    private let pages: [Page] = [
        Page(symbol: "", title: "Welcome to GatePass",
             text: "The simplest way to put your own apps on iPhone, iPad and Apple TV — wirelessly, without worrying about expiry."),
        Page(symbol: "person.crop.circle.badge.checkmark", title: "1. Sign in",
             text: "Use a free Apple ID — ideally a separate one just for this. Your password goes only to Apple; nothing is sent to us."),
        Page(symbol: "iphone.radiowaves.left.and.right", title: "2. Connect a device",
             text: "Connect your iPhone by cable and tap “Trust”. For wireless: select the iPhone in Finder and turn on “Show this iPhone when on Wi-Fi”."),
        Page(symbol: "arrow.down.doc.fill", title: "3. Drop in an IPA",
             text: "Drag .ipa files into the window and press Install. You can also pick a folder of IPAs and rename them inside the app."),
        Page(symbol: "arrow.triangle.2.circlepath", title: "4. Forget about expiry",
             text: "Apps signed with a free account last 7 days. GatePass lives in the menu bar and refreshes them when your device shows up. Top right shows how many signatures you have left this week."),
    ]

    var body: some View {
        VStack(spacing: 0) {
            let p = pages[page]
            VStack(spacing: 18) {
                Group {
                    if page == 0 {
                        Image(nsImage: NSApp.applicationIconImage).resizable().frame(width: 110, height: 110)
                    } else {
                        Image(systemName: p.symbol)
                            .font(.system(size: 54, weight: .medium))
                            .foregroundStyle(Theme.accentGradient)
                            .frame(height: 110)
                    }
                }
                Text(p.title).font(.system(size: 22, weight: .bold, design: .rounded))
                Text(p.text)
                    .font(.system(size: 14))
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: 380)
            }
            .id(page)
            .transition(.asymmetric(insertion: .move(edge: .trailing).combined(with: .opacity),
                                    removal: .move(edge: .leading).combined(with: .opacity)))
            .frame(maxHeight: .infinity)

            HStack(spacing: 7) {
                ForEach(pages.indices, id: \.self) { i in
                    Capsule()
                        .fill(i == page ? AnyShapeStyle(Theme.accentGradient) : AnyShapeStyle(Color.secondary.opacity(0.3)))
                        .frame(width: i == page ? 20 : 7, height: 7)
                }
            }
            .padding(.bottom, 20)

            HStack {
                if page > 0 {
                    Button("Back") { withAnimation(.snappy) { page -= 1 } }
                        .buttonStyle(.borderless)
                } else {
                    Button("Skip") { finish() }
                        .buttonStyle(.borderless)
                        .foregroundStyle(.secondary)
                }
                Spacer()
                Button(page == pages.count - 1 ? (model.account == nil ? "Sign In" : "Get Started") : "Next") {
                    if page == pages.count - 1 { finish() } else { withAnimation(.snappy) { page += 1 } }
                }
                .buttonStyle(PillButtonStyle())
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(30)
        .frame(width: 520, height: 440)
        .interactiveDismissDisabled()
    }

    private func finish() {
        didOnboard = true
        if model.account == nil {
            Task {
                try? await Task.sleep(nanoseconds: 450_000_000)
                model.showLogin = true
            }
        }
    }
}
