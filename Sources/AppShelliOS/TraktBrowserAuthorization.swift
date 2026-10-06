#if os(iOS)
import AuthenticationServices
import CoreModels
import UIKit

@MainActor
final class TraktBrowserAuthorization: NSObject, ASWebAuthenticationPresentationContextProviding {
    private var session: ASWebAuthenticationSession?
    private var continuation: CheckedContinuation<URL, Error>?
    private var anchor: UIWindow?
    private var attemptID: UUID?

    @available(iOS 17.4, *)
    func authorize(url: URL, callback: URL) async throws -> URL {
        finish(.failure(CancellationError()))
        try Task.checkCancellation()
        guard let host = callback.host,
              let window = UIApplication.shared.connectedScenes
                .compactMap({ $0 as? UIWindowScene })
                .filter({ $0.activationState == .foregroundActive })
                .flatMap(\.windows).first(where: \.isKeyWindow)
        else { throw AppError.invalidResponse }
        anchor = window
        let id = UUID()
        attemptID = id
        return try await withTaskCancellationHandler {
            try await withCheckedThrowingContinuation { continuation in
                self.continuation = continuation
                let session = ASWebAuthenticationSession(
                    url: url,
                    callback: .https(host: host, path: callback.path)
                ) { [weak self] url, error in
                    Task { @MainActor in
                        guard let self, self.attemptID == id else { return }
                        if let url {
                            self.finish(.success(url))
                        } else if (error as? ASWebAuthenticationSessionError)?.code == .canceledLogin {
                            self.finish(.failure(CancellationError()))
                        } else {
                            self.finish(.failure(AppError.invalidResponse))
                        }
                    }
                }
                session.presentationContextProvider = self
                // Household profiles must choose their own Trakt identity.
                session.prefersEphemeralWebBrowserSession = true
                self.session = session
                if Task.isCancelled {
                    finish(.failure(CancellationError()))
                } else if !session.start() {
                    finish(.failure(AppError.invalidResponse))
                }
            }
        } onCancel: {
            Task { @MainActor [weak self] in
                guard self?.attemptID == id else { return }
                self?.finish(.failure(CancellationError()))
            }
        }
    }

    func presentationAnchor(for session: ASWebAuthenticationSession) -> ASPresentationAnchor {
        anchor ?? ASPresentationAnchor()
    }

    private func finish(_ result: Result<URL, Error>) {
        let continuation = continuation
        self.continuation = nil
        attemptID = nil
        session?.cancel()
        session = nil
        anchor = nil
        continuation?.resume(with: result)
    }
}
#endif
