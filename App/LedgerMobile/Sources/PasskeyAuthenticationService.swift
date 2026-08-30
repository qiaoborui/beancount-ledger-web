import Foundation

enum PasskeyAuthenticationError: LocalizedError, Equatable {
    case unavailable
    case invalidChallenge
    case invalidCredentialID
    case relyingPartyMismatch(expected: String, received: String)
    case requestInProgress
    case cancelled
    case failed(String)

    var errorDescription: String? {
        switch self {
        case .unavailable:
            return "当前设备无法使用原生通行密钥"
        case .invalidChallenge:
            return "服务器返回了无效的通行密钥挑战"
        case .invalidCredentialID:
            return "服务器返回了无效的通行密钥凭据"
        case let .relyingPartyMismatch(expected, received):
            return "通行密钥域名不匹配：需要 \(expected)，收到 \(received)"
        case .requestInProgress:
            return "通行密钥验证正在进行"
        case .cancelled:
            return "通行密钥验证已取消"
        case let .failed(message):
            return "通行密钥验证失败：\(message)"
        }
    }
}

@MainActor
protocol PasskeyAuthenticating {
    func authenticate(options: PasskeyRequestOptions, relyingPartyID: String) async throws -> PasskeyAssertion
}

struct PreparedPasskeyRequest: Equatable, Sendable {
    let challenge: Data
    let allowedCredentialIDs: [Data]
}

extension PasskeyRequestOptions {
    func preparedForNativeAuthentication(relyingPartyID: String) throws -> PreparedPasskeyRequest {
        if let serverRelyingPartyID = self.relyingPartyID,
           serverRelyingPartyID != relyingPartyID {
            throw PasskeyAuthenticationError.relyingPartyMismatch(
                expected: relyingPartyID,
                received: serverRelyingPartyID
            )
        }
        guard let challenge = Data(base64URLEncoded: challenge), !challenge.isEmpty else {
            throw PasskeyAuthenticationError.invalidChallenge
        }
        let allowedCredentialIDs = try allowCredentials.map { descriptor in
            guard descriptor.type == "public-key",
                  let credentialID = Data(base64URLEncoded: descriptor.id),
                  !credentialID.isEmpty else {
                throw PasskeyAuthenticationError.invalidCredentialID
            }
            return credentialID
        }
        return PreparedPasskeyRequest(
            challenge: challenge,
            allowedCredentialIDs: allowedCredentialIDs
        )
    }
}

#if os(iOS)
import AuthenticationServices
import UIKit

@MainActor
final class SystemPasskeyAuthenticationService: PasskeyAuthenticating {
    private var coordinator: PasskeyAuthorizationCoordinator?

    func authenticate(options: PasskeyRequestOptions, relyingPartyID: String) async throws -> PasskeyAssertion {
        guard coordinator == nil else { throw PasskeyAuthenticationError.requestInProgress }
        let prepared = try options.preparedForNativeAuthentication(relyingPartyID: relyingPartyID)

        return try await withCheckedThrowingContinuation { continuation in
            let coordinator = PasskeyAuthorizationCoordinator(
                challenge: prepared.challenge,
                allowedCredentialIDs: prepared.allowedCredentialIDs,
                relyingPartyID: relyingPartyID
            ) { [weak self] result in
                self?.coordinator = nil
                continuation.resume(with: result)
            }
            self.coordinator = coordinator
            coordinator.perform()
        }
    }
}

@MainActor
private final class PasskeyAuthorizationCoordinator: NSObject,
    ASAuthorizationControllerDelegate,
    ASAuthorizationControllerPresentationContextProviding {
    private let challenge: Data
    private let allowedCredentialIDs: [Data]
    private let relyingPartyID: String
    private let completion: (Result<PasskeyAssertion, Error>) -> Void
    private var authorizationController: ASAuthorizationController?
    private var completed = false

    init(
        challenge: Data,
        allowedCredentialIDs: [Data],
        relyingPartyID: String,
        completion: @escaping (Result<PasskeyAssertion, Error>) -> Void
    ) {
        self.challenge = challenge
        self.allowedCredentialIDs = allowedCredentialIDs
        self.relyingPartyID = relyingPartyID
        self.completion = completion
    }

    func perform() {
        let provider = ASAuthorizationPlatformPublicKeyCredentialProvider(
            relyingPartyIdentifier: relyingPartyID
        )
        let request = provider.createCredentialAssertionRequest(challenge: challenge)
        request.allowedCredentials = allowedCredentialIDs.map {
            ASAuthorizationPlatformPublicKeyCredentialDescriptor(credentialID: $0)
        }
        let controller = ASAuthorizationController(authorizationRequests: [request])
        controller.delegate = self
        controller.presentationContextProvider = self
        authorizationController = controller
        controller.performRequests()
    }

    func presentationAnchor(for controller: ASAuthorizationController) -> ASPresentationAnchor {
        let scenes = UIApplication.shared.connectedScenes.compactMap { $0 as? UIWindowScene }
        if let window = scenes.flatMap(\.windows).first(where: \.isKeyWindow) {
            return window
        }
        if let window = scenes.flatMap(\.windows).first {
            return window
        }
        return ASPresentationAnchor(frame: UIScreen.main.bounds)
    }

    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithAuthorization authorization: ASAuthorization
    ) {
        guard let assertion = authorization.credential as? ASAuthorizationPlatformPublicKeyCredentialAssertion else {
            finish(.failure(PasskeyAuthenticationError.failed("系统返回了未知凭据")))
            return
        }
        finish(.success(PasskeyAssertion(
            credentialID: assertion.credentialID,
            clientDataJSON: assertion.rawClientDataJSON,
            authenticatorData: assertion.rawAuthenticatorData,
            signature: assertion.signature,
            userHandle: assertion.userID
        )))
    }

    func authorizationController(
        controller: ASAuthorizationController,
        didCompleteWithError error: Error
    ) {
        let authorizationError = error as? ASAuthorizationError
        if authorizationError?.code == .canceled {
            finish(.failure(PasskeyAuthenticationError.cancelled))
        } else {
            finish(.failure(PasskeyAuthenticationError.failed(error.localizedDescription)))
        }
    }

    private func finish(_ result: Result<PasskeyAssertion, Error>) {
        guard !completed else { return }
        completed = true
        authorizationController = nil
        completion(result)
    }
}
#else
@MainActor
final class SystemPasskeyAuthenticationService: PasskeyAuthenticating {
    func authenticate(options: PasskeyRequestOptions, relyingPartyID: String) async throws -> PasskeyAssertion {
        throw PasskeyAuthenticationError.unavailable
    }
}
#endif
