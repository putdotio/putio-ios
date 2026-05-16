import SwiftUI

/// Device-code linking screen. Ports
/// `apps/tv-native/src/features/auth/screens/auth-with-code.tsx`:
/// activation-code cards on hi-contrast surfaces, yellow `put.io/link` callout,
/// `Get new code` primary action, app version footer.
struct AuthCodeView: View {
    let session: AuthSession

    var body: some View {
        ZStack {
            Color.put.bg.ignoresSafeArea()
            content
            VStack {
                Spacer()
                AppInfoFooter()
                    .padding(.bottom, PutSpacing.md + PutSafe.vertical)
            }
        }
        .onAppear {
            if case .idle = session.state {
                session.start()
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch session.state {
        case .idle, .creatingCode:
            PutLoadingState(title: "Getting code")

        case let .awaitingLink(code, _):
            codeView(code: code)

        case .verifyingToken:
            PutLoadingState(title: "Linking your account")

        case .linked:
            PutLoadingState(title: "Signed in")

        case let .failed(failure):
            FailureView(failure: failure)
        }
    }

    private func codeView(code: String) -> some View {
        VStack(spacing: PutSpacing.lg) {
            Text("┌( ಠ‿ಠ)┘ welcome!")
                .font(.put.heading)
                .foregroundStyle(Color.put.text)

            VStack(spacing: PutSpacing.sm) {
                Text("use this activation code to log in")
                    .font(.put.body)
                    .foregroundStyle(Color.put.text)
                ActivationCode(code: code)
            }

            VStack(spacing: PutSpacing.xs) {
                Text("follow the steps at the website below")
                    .font(.put.body)
                    .foregroundStyle(Color.put.text)
                Text(PutioTV.Constants.appLinkURL)
                    .font(.put.label)
                    .foregroundStyle(Color.put.yellowSolid)
            }

            PutButton(title: "Get new code", icon: "refresh-ccw", hasTVPreferredFocus: true) {
                session.start()
            }
            .id(code)
        }
        .padding(PutSpacing.xxl)
    }
}

/// 6-char activation code with each character on a hi-contrast square.
/// Ports `apps/tv-native/src/components/activation-code.tsx`.
struct ActivationCode: View {
    let code: String

    var body: some View {
        HStack(spacing: PutSpacing.sm) {
            ForEach(Array(code.enumerated()), id: \.offset) { _, ch in
                Text(String(ch))
                    .font(.put.label)
                    .foregroundStyle(Color.put.loContrast)
                    .frame(width: 96, height: 96)
                    .background(
                        RoundedRectangle(cornerRadius: PutRadius.default, style: .continuous)
                            .fill(Color.put.hiContrast)
                    )
            }
        }
    }
}

struct AppInfoFooter: View {
    var body: some View {
        let info = Bundle.main.infoDictionary
        let bundleID = info?["CFBundleIdentifier"] as? String ?? "io.put.tvos"
        let short = info?["CFBundleShortVersionString"] as? String ?? "0.0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        Text("\(bundleID)@\(short)+\(build)")
            .font(.put.smol)
            .foregroundStyle(Color.put.textSecondary)
            .frame(maxWidth: .infinity)
    }
}
