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
                    .padding(.bottom, 48)
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
        VStack(spacing: 56) {
            VStack(spacing: 16) {
                Text("Welcome to put.io")
                    .font(.system(size: 64, weight: .semibold))
                    .foregroundStyle(.white)
                Text("Enter this code to sign in to your account")
                    .font(.system(size: 32))
                    .foregroundStyle(.secondary)
            }

            ActivationCode(code: code)

            VStack(spacing: 8) {
                Text("Visit the URL below from any device:")
                    .font(.system(size: 28))
                    .foregroundStyle(.secondary)
                Text(PutioTV.Constants.appLinkURL)
                    .font(.system(size: 48, weight: .semibold, design: .rounded))
                    .foregroundStyle(Color.put.yellowSolid)
            }

            Button {
                session.start()
            } label: {
                Label("Get new code", systemImage: "arrow.clockwise")
                    .padding(.horizontal, 32)
                    .padding(.vertical, 12)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.put.yellowSolid)
            .foregroundStyle(.black)
            .id(code)
        }
        .padding(80)
    }
}

/// 6-char activation code with each character on a hi-contrast square.
/// Ports `apps/tv-native/src/components/activation-code.tsx`.
struct ActivationCode: View {
    let code: String

    var body: some View {
        HStack(spacing: 24) {
            ForEach(Array(code.enumerated()), id: \.offset) { _, ch in
                Text(String(ch))
                    .font(.system(size: 120, weight: .bold, design: .rounded))
                    .foregroundStyle(.black)
                    .frame(width: 160, height: 180)
                    .background(
                        RoundedRectangle(cornerRadius: 20, style: .continuous)
                            .fill(.white)
                    )
            }
        }
    }
}

struct AppInfoFooter: View {
    var body: some View {
        let info = Bundle.main.infoDictionary
        let short = info?["CFBundleShortVersionString"] as? String ?? "0.0"
        let build = info?["CFBundleVersion"] as? String ?? "0"
        Text("Version \(short) (\(build))")
            .font(.system(size: 22))
            .foregroundStyle(.tertiary)
            .frame(maxWidth: .infinity)
    }
}
