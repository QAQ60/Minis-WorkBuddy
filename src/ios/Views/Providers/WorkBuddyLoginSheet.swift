import SwiftUI
import SafariServices

/// WorkBuddy sign-in sheet: pick the site (China / International), open the
/// official authorization page in a browser, and poll until the sign-in
/// completes. Mirrors the state/error surface of `KimiDeviceLoginSheet`.
///
/// Usage (once ProviderType.workBuddy is wired):
///   .sheet(isPresented: $showWorkBuddyLogin) {
///       WorkBuddyLoginSheet(instanceId: instance.id) { success in ... }
///   }
@available(iOS 16.0, *)
struct WorkBuddyLoginSheet: View {
    let instanceId: String
    /// Called on dismiss with whether authentication succeeded.
    var onFinish: (Bool) -> Void

    @Environment(\.dismiss) private var dismiss

    private enum Phase: Equatable {
        case pickingSite
        case awaitingUser(url: String, siteName: String)
        case success
        case failed(String)
    }

    @State private var phase: Phase = .pickingSite
    @State private var selectedSite: WorkBuddySite = .china
    @State private var loginTask: Task<Void, Never>?

    var body: some View {
        NavigationStack {
            VStack(spacing: 24) {
                switch phase {
                case .pickingSite:
                    Picker(AppLocalized("站点"), selection: $selectedSite) {
                        ForEach(WorkBuddySite.allCases, id: \.self) { site in
                            Text(site.displayName).tag(site)
                        }
                    }
                    .pickerStyle(.segmented)
                    .padding(.horizontal)

                    Text(AppLocalized("登录将打开 WorkBuddy 官方授权页；请使用你的 CodeBuddy 计划账号登录并确认授权。"))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .padding(.horizontal)

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
                    VStack(spacing: 12) {
                        Text(AppLocalized("正在等待 \(siteName) 登录完成…"))
                            .font(.headline)
                        ProgressView()
                        Button(AppLocalized("重新打开登录页")) { open(url) }
                            .buttonStyle(.bordered)
                    }

                case .success:
                    Image(systemName: "checkmark.circle.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(.green)
                    Text(AppLocalized("已登录 WorkBuddy"))
                        .font(.headline)

                case let .failed(message):
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.system(size: 44))
                        .foregroundStyle(.orange)
                    Text(message)
                        .multilineTextAlignment(.center)
                        .foregroundStyle(.secondary)
                        .padding(.horizontal)
                    Button(AppLocalized("Try Again")) {
                        phase = .pickingSite
                    }
                    .buttonStyle(.borderedProminent)
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .padding()
            .navigationTitle(AppLocalized("WorkBuddy 登录"))
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(AppLocalized("Cancel")) { finish(false) }
                }
            }
        }
        // 一次真实的登录等待不允许下滑误关（与 Kimi sheet 同款约束）。
        .interactiveDismissDisabled({
            if case .awaitingUser = phase { return loginTask != nil }
            return false
        }())
        .onDisappear { loginTask?.cancel() }
    }

    private func start() {
        let site = selectedSite
        phase = .awaitingUser(url: "", siteName: site.displayName)
        loginTask = Task {
            do {
                try await WorkBuddyOAuthManager.shared.login(instanceId: instanceId, site: site) { presentation in
                    // The auth page belongs to the vendor's web console — open
                    // it in the user's browser (QR / password login there).
                    phase = .awaitingUser(url: presentation.authURL.absoluteString, siteName: presentation.site.displayName)
                    open(presentation.authURL.absoluteString)
                }
                guard !Task.isCancelled else { return }
                phase = .success
                finish(true)
            } catch {
                guard !Task.isCancelled else { return }
                phase = .failed(error.localizedDescription)
            }
        }
    }

    private func open(_ urlString: String) {
        guard let url = URL(string: urlString) else { return }
        UIApplication.shared.open(url)
    }

    private func finish(_ success: Bool) {
        loginTask?.cancel()
        loginTask = nil
        onFinish(success)
        dismiss()
    }
}
