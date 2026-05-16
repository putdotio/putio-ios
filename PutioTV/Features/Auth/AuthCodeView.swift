import SwiftUI

/// Device-code linking screen. Matches the `01-auth-code` exported tvOS
/// screenshot: big code, `put.io/link` callout, primary "Get new code" action.
struct AuthCodeView: View {
    let session: AuthSession

    var body: some View {
        ZStack {
            Color.put.surface.ignoresSafeArea()
            content
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
            PutErrorState(failure: failure, retryLabel: "Get new code")
        }
    }

    private func codeView(code: String) -> some View {
        VStack(spacing: PutSpacing.xl) {
            Text("┌( ಠ‿ಠ)┘ welcome!")
                .font(.put.title)
                .foregroundStyle(Color.put.textPrimary)

            VStack(spacing: PutSpacing.sm) {
                Text("use this activation code to log in")
                    .font(.put.body)
                    .foregroundStyle(Color.put.textSecondary)
                Text(code)
                    .font(.put.code)
                    .foregroundStyle(Color.put.textPrimary)
                    .tracking(12)
                    .padding(.horizontal, PutSpacing.lg)
                    .padding(.vertical, PutSpacing.md)
                    .background {
                        RoundedRectangle(cornerRadius: 32, style: .continuous)
                            .fill(.thinMaterial)
                    }
                    .overlay(
                        RoundedRectangle(cornerRadius: 32, style: .continuous)
                            .strokeBorder(Color.white.opacity(0.08), lineWidth: 1)
                    )
            }

            VStack(spacing: PutSpacing.xs) {
                Text("follow the steps at the website below")
                    .font(.put.body)
                    .foregroundStyle(Color.put.textSecondary)
                Text(PutioTV.Constants.appLinkURL)
                    .font(.put.headline)
                    .foregroundStyle(Color.put.accentYellow)
            }

            Button {
                session.start()
            } label: {
                Label("Get new code", systemImage: "arrow.clockwise")
                    .font(.put.headline)
                    .padding(.horizontal, PutSpacing.md)
                    .padding(.vertical, PutSpacing.xs)
            }
            .buttonStyle(.borderedProminent)
            .tint(Color.put.accentYellow)
            .id(code)
        }
        .padding(PutSpacing.xxl)
    }
}
