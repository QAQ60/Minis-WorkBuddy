import SwiftUI
import WebKit

/// WorkBuddy sign-in panel — rendered INLINE inside the Add Provider form.
///
/// Deliberately not a `.sheet`. A container runtime (LiveContainer and
/// friends) hosts the guest app in a child window whose view controller is not
/// the scene's root, and `.sheet` presentation from there silently does
/// nothing: the tap looks dead. An inline panel has no presentation step to
/// fail, so it works in both environments.
///
/// The authorization page is shown in an in-app `WKWebView` rather than handed
/// to `UIApplication.shared.open` — a guest bundle's URL schemes are never
/// registered, so opening Safari was a second dead end. Sign-in is polled
/// (`/v2/plugin/auth/state` → `/v2/plugin/auth/token`), so no callback scheme
/// is needed either way.
@available(iOS 16.0, *)
struct WorkBuddyLoginPanel: View {
    let instanceId: String
    /// Called with whether authentication succeeded, once the poll resolves.
    var onFinish: (Bool) -> Void

    private enum Phase: Equatable {
        case idle
        case awaitingUser(url: String, siteName: String)
        case success
        case failed(String)
    }

    @State private var phase: Phase = .idle
    @State private var selectedSite: WorkBuddySite = .china
    @State private var loginTask: Task<Void, Never>?

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Picker(AppLocalized("站点"), selection: $selectedSite) {
                ForEach(WorkBuddySite.allCases, id: \.self) { site in
                    Text(site.displayName).tag(site)
                }
            }
            .pickerStyle(.segmented)
            .disabled(isRunning)

            switch phase {
            case .idle:
                Button {
                    start()
                } label: {
                    HStack {
                        Spacer()
                        Text(AppLocalized("打开登录页"))
                            .font(.body.weight(.semibold))
                        Spacer()
                    }
                }
                .buttonStyle(.borderedProminent)

            case let .awaitingUser(url, siteName):
                HStack(spacing: 8) {
                    ProgressView().controlSize(.small)
                    Text(AppLocalized("正在等待 \(siteName) 登录完成…"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                if let target = URL(string: url), !url.isEmpty {
                    WorkBuddyWebView(url: target)
                        .frame(height: 460)
                        .clipShape(RoundedRectangle(cornerRadius: 12))
                        .overlay(
                            RoundedRectangle(cornerRadius: 12)
                                .strokeBorder(Color.secondary.opacity(0.25))
                        )
                } else {
                    Text(AppLocalized("正在准备登录页…"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
                Button(AppLocalized("取消登录")) { cancel() }
                    .buttonStyle(.bordered)
                    .font(.footnote)

            case .success:
                HStack(spacing: 8) {
                    Image(systemName: "checkmark.circle.fill").foregroundStyle(.green)
                    Text(AppLocalized("已登录 WorkBuddy")).font(.footnote.weight(.semibold))
                }

            case let .failed(message):
                HStack(alignment: .top, spacing: 8) {
                    Image(systemName: "exclamationmark.triangle.fill").foregroundStyle(.orange)
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .textSelection(.enabled)
                }
                Button(AppLocalized("Try Again")) { phase = .idle }
                    .buttonStyle(.bordered)
                    .font(.footnote)
            }
        }
        .onDisappear { loginTask?.cancel() }
    }

    private var isRunning: Bool {
        if case .awaitingUser = phase { return true }
        return false
    }

    private func start() {
        let site = selectedSite
        phase = .awaitingUser(url: "", siteName: site.displayName)
        loginTask?.cancel()
        loginTask = Task {
            do {
                try await WorkBuddyOAuthManager.shared.login(instanceId: instanceId, site: site) { presentation in
                    phase = .awaitingUser(url: presentation.authURL.absoluteString,
                                          siteName: presentation.site.displayName)
                }
                guard !Task.isCancelled else { return }
                phase = .success
                onFinish(true)
            } catch {
                guard !Task.isCancelled else { return }
                phase = .failed(error.localizedDescription)
                onFinish(false)
            }
        }
    }

    private func cancel() {
        loginTask?.cancel()
        loginTask = nil
        phase = .idle
    }
}

// MARK: - Sheet wrapper

/// Sheet-shaped container for the call sites that CAN present a sheet (the
/// provider detail page). The Add Provider flow uses `WorkBuddyLoginPanel`
/// inline instead, because a container runtime cannot present a sheet.
@available(iOS 16.0, *)
struct WorkBuddyLoginSheet: View {
    let instanceId: String
    var onFinish: (Bool) -> Void

    @Environment(\.dismiss) private var dismiss

    var body: some View {
        NavigationStack {
            ScrollView {
                WorkBuddyLoginPanel(instanceId: instanceId) { success in
                    onFinish(success)
                    if success { dismiss() }
                }
                .padding()
            }
            .navigationTitle(AppLocalized("WorkBuddy 登录"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AppLocalized("Cancel")) { dismiss() }
                }
            }
        }
    }
}

// MARK: - In-app browser

/// Minimal `WKWebView` host. `WKWebView` keeps the page inside the app's own
/// process group, which is what makes this work under a container runtime
/// where `SFSafariViewController` (a separate service process) is unavailable.
private struct WorkBuddyWebView: UIViewRepresentable {
    let url: URL

    func makeUIView(context: Context) -> WKWebView {
        let configuration = WKWebViewConfiguration()
        configuration.websiteDataStore = .default()
        let webView = WKWebView(frame: .zero, configuration: configuration)
        webView.isOpaque = false
        webView.backgroundColor = .clear
        webView.allowsBackForwardNavigationGestures = true
        return webView
    }

    func updateUIView(_ webView: WKWebView, context: Context) {
        // Only load when the URL actually changed, otherwise every SwiftUI
        // re-render would reload the page and wipe the half-finished login.
        guard webView.url != url else { return }
        webView.load(URLRequest(url: url))
    }
}
