import AuthenticationServices
import SwiftUI
import ZapaKidKit

/// Parents sign in with Apple or Google. Kids don't sign in: a parent adds their phone with a QR code.
struct SignInView: View {
    let auth: AuthModel
    let google: GoogleSignInProviding
    let ageCheck: AgeRangeProviding

    @Environment(\.colorScheme) private var colorScheme
    @State private var appleNonce = SignInNonce()

    var body: some View {
        ScrollView {
            VStack(spacing: 24) {
                Image(systemName: "bubble.left.and.bubble.right.fill")
                    .font(.system(.largeTitle))
                    .imageScale(.large)
                    .foregroundStyle(.tint)
                    .accessibilityHidden(true)
                Text("ZapaKid")
                    .font(.largeTitle.bold())
                    .accessibilityAddTraits(.isHeader)
                Text("Private chat for your family. Parents sign in with Apple or Google.")
                    .font(.body)
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)

                SignInWithAppleButton(.signIn) { request in
                    appleNonce = SignInNonce()
                    request.requestedScopes = []
                    request.nonce = appleNonce.hashed
                } onCompletion: { result in
                    Task { await finishApple(result) }
                }
                .signInWithAppleButtonStyle(colorScheme == .dark ? .white : .black)
                .frame(minHeight: 50)
                .disabled(auth.isBusy)
                .accessibilityIdentifier("signin.apple")

                Button {
                    Task { await signInWithGoogle() }
                } label: {
                    Label("Sign in with Google", systemImage: "g.circle.fill")
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: 50)
                }
                .buttonStyle(.bordered)
                .disabled(auth.isBusy)
                .accessibilityLabel(Text("Sign in with Google"))
                .accessibilityIdentifier("signin.google")

                if auth.isBusy {
                    ProgressView()
                        .accessibilityLabel(Text("Signing in"))
                }
                if let message = auth.errorMessage {
                    Text(message)
                        .font(.footnote)
                        .foregroundStyle(.red)
                        .multilineTextAlignment(.center)
                        .accessibilityIdentifier("signin.error")
                }
                Text("Kids: ask a parent to add your phone.")
                    .font(.footnote.italic())
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            .padding(24)
        }
        .accessibilityElement(children: .contain)
        .accessibilityIdentifier("signin.screen")
    }

    private func finishApple(_ result: Result<ASAuthorization, Error>) async {
        switch result {
        case let .success(authorization):
            guard let credential = authorization.credential as? ASAuthorizationAppleIDCredential,
                  let data = credential.identityToken,
                  let idToken = String(data: data, encoding: .utf8)
            else {
                auth.signInFailed(String(localized: "Apple didn't return a sign-in token."))
                return
            }
            let ageRange = await ageCheck.ageRange()
            await auth.signIn(provider: .apple, idToken: idToken, nonce: appleNonce.raw, ageRange: ageRange)
        case let .failure(error):
            if (error as? ASAuthorizationError)?.code != .canceled {
                auth.signInFailed(error.localizedDescription)
            }
        }
    }

    private func signInWithGoogle() async {
        let nonce = SignInNonce()
        do {
            let idToken = try await google.idToken(nonce: nonce.hashed)
            let ageRange = await ageCheck.ageRange()
            await auth.signIn(provider: .google, idToken: idToken, nonce: nonce.raw, ageRange: ageRange)
        } catch let error as ASWebAuthenticationSessionError where error.code == .canceledLogin {
            return
        } catch {
            auth.signInFailed(error.localizedDescription)
        }
    }
}
