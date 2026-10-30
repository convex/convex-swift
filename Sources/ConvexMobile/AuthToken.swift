//
//  AuthToken.swift
//  ConvexMobile
//
//  Token injection on the base ConvexClient.
//

import Foundation

/// Supplies the JWT that `ConvexClient` sends with authenticated calls.
///
/// Implement this to drive Convex auth from an identity provider you already
/// manage, without adopting ``ConvexClientWithAuth``. That subclass owns the
/// whole login lifecycle — sign-in strategies, cached sessions, an auth state
/// publisher — which is convenient when it fits and awkward when the app
/// already has its own auth layer and only needs to hand Convex a token.
///
/// `fetchToken` is called by the Rust core when it needs a token, including
/// after a reconnect. Returning `nil` means "no valid token right now", which
/// leaves the connection unauthenticated rather than failing.
///
/// - Parameter forceRefresh: `true` when the previous token was rejected, so a
///   cached value should not be reused.
public protocol ConvexAuthTokenProvider: Sendable {
    func fetchToken(forceRefresh: Bool) async throws -> String?
}

extension ConvexClient {
    /// Sets or clears the provider supplying auth tokens for this client.
    ///
    /// Pass `nil` to return to unauthenticated calls, e.g. on sign-out.
    ///
    /// Unlike ``ConvexClientWithAuth``, this stores no mutable auth state on the
    /// client: the provider is handed straight to the Rust core, which owns
    /// refresh. Callers that need serialisation across sign-in, sign-out and
    /// token refresh should make their provider an `actor`.
    public func setAuthTokenProvider(
        _ provider: (any ConvexAuthTokenProvider)?
    ) async throws {
        guard let provider else {
            try await ffiClient.setAuthCallback(provider: nil)
            return
        }
        try await ffiClient.setAuthCallback(
            provider: ExternalAuthTokenProvider(wrapping: provider)
        )
    }
}

/// Adapts a public ``ConvexAuthTokenProvider`` to the UniFFI-generated protocol,
/// so callers never have to import or conform to generated types.
///
/// A `final class` because the generated protocol requires `AnyObject`.
/// `@unchecked Sendable` is safe here: the single stored property is a `let`
/// holding a `Sendable` value, so there is no mutable state to race on.
private final class ExternalAuthTokenProvider: AuthTokenProvider, @unchecked Sendable {
    private let wrapped: any ConvexAuthTokenProvider

    init(wrapping wrapped: any ConvexAuthTokenProvider) {
        self.wrapped = wrapped
    }

    func fetchToken(forceRefresh: Bool) async throws -> String? {
        try await wrapped.fetchToken(forceRefresh: forceRefresh)
    }
}
