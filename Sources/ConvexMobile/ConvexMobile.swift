// The Swift Programming Language
// https://docs.swift.org/swift-book

import Combine
import Foundation
@_exported import UniFFI

/// A client API for interacting with a Convex backend.
///
/// Handles marshalling of data between calling code and the
/// [convex-mobile](https://github.com/convex/convex-mobile) and
/// [convex-rs](https://github.com/convex/convex-rs) native libraries.
///
/// Consumers of this client should use Swift's ``Decodable``  protocol for handling data received from the
/// Convex backend.
public class ConvexClient {
  let ffiClient: UniFFI.MobileConvexClientProtocol
  fileprivate let webSocketStateAdapter = WebSocketStateAdapter()

  /// Creates a new instance of ``ConvexClient``.
  ///
  /// - Parameters:
  ///   - deploymentUrl: The Convex backend URL to connect to; find it in the [dashboard](https://dashboard.convex.dev) Settings for your project
  public init(deploymentUrl: String) {
    self.ffiClient = UniFFI.MobileConvexClient(
      deploymentUrl: deploymentUrl, clientId: "swift-\(convexMobileVersion)", webSocketStateSubscriber: webSocketStateAdapter)
  }

  init(ffiClient: UniFFI.MobileConvexClientProtocol) {
    self.ffiClient = ffiClient
  }

  /// Subscribes to the query with the given `name` and converts data from the subscription into an
  /// ``AnyPublisher<T, ClientError>``.
  ///
  /// The upstream Convex subscription will be canceled if whatever is subscribed to returned publisher
  /// stops listening.
  ///
  /// - Parameters:
  ///   - name: A value in "module:query_name"  format that will be used when calling the backend
  ///   - args: An optional ``Dictionary`` of arguments to be sent to the backend query function
  ///   - output: The type of data that will be returned in the Publisher, as a convenience to callers
  ///             where the type can't be easily inferred.
  public func subscribe<T: Decodable>(
    to name: String, with args: [String: ConvexEncodable?]? = nil, yielding output: T.Type? = nil
  ) -> AnyPublisher<T, ClientError> {
    // There are two steps to producing the final Publisher in this method.
    // 1. Subscribe to the data from Convex and publish the subscription handle
    // 2. Feed the subscription handle into the Convex data Publisher so it can cancel the upstream
    //    subscription when downstream subscribers are done consuming data

    // This Publisher will ultimately publish the data received from Convex.
    let convexPublisher = PassthroughSubject<T, ClientError>()
    let adapter = SubscriptionAdapter<T>(publisher: convexPublisher)

    // This Publisher is responsible for initializing the Convex subscription and returning a handle
    // to the upstream (Convex) subscription.
    let initializationPublisher = Future<SubscriptionHandle, ClientError> {
      result in
      Task {
        do {
          let subscriptionHandle = try await self.ffiClient.subscribe(
            name: name,
            args: args?.mapValues({ v in
              try v?.convexEncode() ?? "null"
            }) ?? [:], subscriber: adapter)
          result(.success(subscriptionHandle))
        } catch {
          result(.failure(ClientError.InternalError(msg: error.localizedDescription)))
        }
      }
    }

    // The final Publisher takes the handle from the initial Convex subscription and supplies it to
    // the data publisher so it can cancel the upstream subscription when consumers are no longer
    // listening for data.
    return initializationPublisher.flatMap({ subscriptionHandle in
      convexPublisher.handleEvents(receiveCancel: {
        subscriptionHandle.cancel()
      })
    })
    .eraseToAnyPublisher()
  }

  /// Executes the mutation with the given `name` and `args` and returns the result.
  ///
  /// For mutations that don't return a value, prefer calling the version of this method that doesn't return a value.
  ///
  /// - Parameters:
  ///   - name: A value in "module:mutation_name"  format that will be used when calling the backend
  ///   - args: An optional ``Dictionary`` of arguments to be sent to the backend mutation function
  public func mutation<T: Decodable>(_ name: String, with args: [String: ConvexEncodable?]? = nil)
    async throws -> T
  {
    try await callForResult(name: name, args: args, remoteCall: ffiClient.mutation)
  }

  /// Executes the mutation with the given `name` and `args` without returning a result.
  ///
  /// For mutations that return a value, prefer calling the version of this method that returns a ``Decodable`` value.
  ///
  /// - Parameters:
  ///   - name: A value in "module:mutation_name"  format that will be used when calling the backend
  ///   - args: An optional ``Dictionary`` of arguments to be sent to the backend mutation function
  public func mutation(_ name: String, with args: [String: ConvexEncodable?]? = nil)
    async throws
  {
    let _: String? = try await mutation(name, with: args)
  }

  /// Executes the action with the given `name` and `args` and returns the result.
  ///
  /// For actions that don't return a value, prefer calling the version of this method that doesn't return a value.
  ///
  /// - Parameters:
  ///   - name: A value in "module:mutation_name"  format that will be used when calling the backend
  ///   - args: An optional ``Dictionary`` of arguments to be sent to the backend mutation function
  public func action<T: Decodable>(_ name: String, with args: [String: ConvexEncodable?]? = nil)
    async throws -> T
  {
    return try await callForResult(name: name, args: args, remoteCall: ffiClient.action)
  }

  /// Executes the action with the given `name` and `args` without returning a result.
  ///
  /// For actions that return a value, prefer calling the version of this method that returns a ``Decodable`` value.
  ///
  /// - Parameters:
  ///   - name: A value in "module:mutation_name"  format that will be used when calling the backend
  ///   - args: An optional ``Dictionary`` of arguments to be sent to the backend mutation function
  public func action(_ name: String, with args: [String: ConvexEncodable?]? = nil)
    async throws
  {
    let _: String? = try await action(name, with: args)
  }

  /// Common handler for `action` and `mutation` calls.
  ///
  /// To the client code, both work in a very similar fashion where remote code is invoked and a result is returned. This handler takes care of
  /// encoding the arguments and decoding the result, whether the call is an `action` or `mutation`.
  func callForResult<T: Decodable>(
    name: String, args: [String: ConvexEncodable?]? = nil, remoteCall: RemoteCall
  )
    async throws -> T
  {
    let rawResult = try await remoteCall(
      name,
      args?.mapValues({ v in
        try v?.convexEncode() ?? "null"
      }) ?? [:])
    return try JSONDecoder().decode(T.self, from: Data(rawResult.utf8))
  }

  typealias RemoteCall = (String, [String: String]) async throws -> String
  
  public func watchWebSocketState() -> AnyPublisher<WebSocketState, Never> {
    return webSocketStateAdapter.newPublisher()
  }
}

/// Authentication states that can be experienced when using an ``AuthProvider`` with
/// ``ConvexClientWithAuth``.
public enum AuthState<T> {
  /// Represents an authenticated user.
  ///
  /// Contains authentication data from the associated ``AuthProvider``.
  case authenticated(T)
  /// Represents an unauthenticated user.
  case unauthenticated
  /// Represents an ongoing authentication attempt.
  case loading
}

/// An authentication provider, used with ``ConvexClientWithAuth``.
///
/// The generic type `T` is the data returned by the provider upon a successful authentication attempt.
public protocol AuthProvider<T> {
  associatedtype T

  /// Trigger a login flow, which might launch a new UI/screen.
  ///
  /// - Parameter onIdToken: A callback to invoke with a fresh JWT ID token. The auth provider should store
  ///   this callback and invoke it whenever a new token is available (e.g., on token refresh).
  ///   Call with `nil` if the session becomes invalid (e.g., token refresh fails).
  func login(onIdToken: @Sendable @escaping (String?) -> Void) async throws -> T

  /// Trigger a logout flow, which might launch a new UI/screen.
  func logout() async throws

  /// Trigger a cached, UI-less re-authentication using stored credentials from a previous ``login()``.
  ///
  /// For OAuth providers, this is a good place to check token validity and perform a refresh if necessary
  /// before returning the auth data as``T``.
  ///
  /// - Parameter onIdToken: A callback to invoke with a fresh JWT ID token. The auth provider should store
  ///   this callback and invoke it whenever a new token is available (e.g., on token refresh).
  ///   Call with `nil` if the session becomes invalid (e.g., token refresh fails).
  func loginFromCache(onIdToken: @Sendable @escaping (String?) -> Void)
    async throws -> T

  /// Extracts a [JWT ID token](https://openid.net/specs/openid-connect-core-1_0.html#IDToken)
  /// from the `authResult`.
  func extractIdToken(from authResult: T) -> String
}

/// A bridge that adapts the push-based `onIdToken` model to the pull-based `AuthTokenProvider`
/// callback model used by the Rust client.
///
/// Caches the latest pushed token so that the Rust client can pull it if needed.
private actor AuthTokenProviderBridge: AuthTokenProvider {
  private var cachedToken: String?
  private var getValidToken: () async throws -> String?

  init(token: String?, getValidToken: @escaping () async throws -> String?) {
    self.cachedToken = token
    self.getValidToken = getValidToken
  }

  func fetchToken(forceRefresh: Bool) async throws -> String? {
    // Note: it's actually not required to treat this as a "force refresh". The
    // `getValidToken` function just needs to ensure that it's valid, which means
    // it can be an existing token that was previously cached elsewhere by the
    // `AuthProvider`.
    if forceRefresh, let freshToken = try? await getValidToken() {
      cachedToken = freshToken
    }
    return cachedToken
  }

  func updateToken(_ token: String?) {
    cachedToken = token
  }
}

/// Owns the auth state of a ``ConvexClientWithAuth``: the active ``AuthTokenProviderBridge``, the
/// provider registered with the Rust client, and the published ``AuthState``.
///
/// Login, logout and token pushes from the ``AuthProvider`` can all happen concurrently. Operations are
/// queued synchronously, in call order, and a single loop runs them one at a time (including the FFI
/// call), so the current bridge, the provider registered with the Rust client and the published
/// ``AuthState`` can't get out of sync.
///
/// `ffiClient` is passed to each operation rather than stored because ``ConvexClientWithAuth`` must
/// create its session before `super.init` has created the client.
///
/// `@unchecked Sendable` because Combine's `CurrentValueSubject` and `AnyPublisher` aren't annotated as
/// `Sendable`, though `send` and subscribing are thread-safe; the remaining stored property is `Sendable`.
private final class AuthSession<T>: @unchecked Sendable {
  /// Receives the current bridge and returns the bridge that is current afterwards.
  private typealias Operation =
    @Sendable (AuthTokenProviderBridge?) async -> AuthTokenProviderBridge?

  private let operations: AsyncStream<Operation>.Continuation
  private let authPublisher = CurrentValueSubject<AuthState<T>, Never>(AuthState.unauthenticated)

  /// Publishes the current ``AuthState``.
  let authState: AnyPublisher<AuthState<T>, Never>

  init() {
    let (stream, operations) = AsyncStream.makeStream(of: Operation.self)
    self.operations = operations
    self.authState = authPublisher.eraseToAnyPublisher()
    // Captures only the stream, so the loop ends when this session is deinitialized.
    Task {
      var bridge: AuthTokenProviderBridge?
      for await operation in stream {
        bridge = await operation(bridge)
      }
    }
  }

  deinit {
    operations.finish()
  }

  /// Queues publishing ``AuthState/loading`` at the start of a login attempt.
  func beginLogin() {
    operations.yield { [authPublisher] current in
      authPublisher.send(.loading)
      return current
    }
  }

  /// Queues publishing ``AuthState/unauthenticated`` after a failed login attempt.
  func loginFailed() {
    operations.yield { [authPublisher] current in
      authPublisher.send(.unauthenticated)
      return current
    }
  }

  /// Makes `bridge` the active auth provider and publishes ``AuthState/authenticated(_:)`` with
  /// `authData` once the Rust client has it.
  func install(
    _ bridge: AuthTokenProviderBridge, authData: T, on ffiClient: MobileConvexClientProtocol
  ) async throws {
    try await perform { [authPublisher] _ in
      try await ffiClient.setAuthCallback(provider: bridge)
      authPublisher.send(.authenticated(authData))
      return bridge
    }
  }

  /// Clears the active auth provider, logging out the Rust client, and publishes
  /// ``AuthState/unauthenticated``.
  func clear(on ffiClient: MobileConvexClientProtocol) async throws {
    try await perform { [authPublisher] _ in
      try await ffiClient.setAuthCallback(provider: nil)
      authPublisher.send(.unauthenticated)
      return nil
    }
  }

  /// Queues a token pushed by the ``AuthProvider`` and returns without waiting for it to be applied.
  func pushToken(_ token: String?, on ffiClient: MobileConvexClientProtocol) {
    operations.yield { [authPublisher] current in
      do {
        if let token {
          guard let current else { return nil }
          await current.updateToken(token)
          try await ffiClient.setAuthCallback(provider: current)
          return current
        } else {
          try await ffiClient.setAuthCallback(provider: nil)
          authPublisher.send(.unauthenticated)
          return nil
        }
      } catch {
        dump(error)
        authPublisher.send(.unauthenticated)
        return current
      }
    }
  }

  /// Queues `body` and waits for it to run. If `body` throws, the current bridge is left unchanged,
  /// matching the Rust client, which keeps its previous provider when `setAuthCallback` fails.
  private func perform(
    _ body: @escaping @Sendable (AuthTokenProviderBridge?) async throws -> AuthTokenProviderBridge?
  ) async throws {
    try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
      let result = operations.yield { current in
        do {
          let next = try await body(current)
          continuation.resume()
          return next
        } catch {
          continuation.resume(throwing: error)
          return current
        }
      }
      if case .terminated = result {
        continuation.resume(throwing: CancellationError())
      }
    }
  }
}

/// Like ``ConvexClient``, but supports integration with an authentication provider via ``AuthProvider``.
///
/// The generic parameter `T` matches the type of data returned by the ``AuthProvider`` upon successful
/// authentication.
public class ConvexClientWithAuth<T>: ConvexClient {
  private let authProvider: any AuthProvider<T>
  private let authSession = AuthSession<T>()

  /// A publisher that updates with the current ``AuthState`` of this client instance.
  public let authState: AnyPublisher<AuthState<T>, Never>

  /// Creates a new instance of ``ConvexClientWithAuth``.
  ///
  /// - Parameters:
  ///   - deploymentUrl: The Convex backend URL to connect to; find it in the [dashboard](https://dashboard.convex.dev) Settings for your project
  ///   - authProvider: An instance that will handle the actual authentication duties.
  public init(deploymentUrl: String, authProvider: any AuthProvider<T>) {
    self.authProvider = authProvider
    self.authState = authSession.authState
    super.init(deploymentUrl: deploymentUrl)
  }

  init(ffiClient: MobileConvexClientProtocol, authProvider: any AuthProvider<T>) {
    self.authProvider = authProvider
    self.authState = authSession.authState
    super.init(ffiClient: ffiClient)
  }

  /// Triggers a UI driven login flow and updates the ``authState``.
  ///
  /// The ``authState`` is set to ``AuthState.loading`` once any pending auth changes have been applied
  /// and will change to either ``AuthState.authenticated`` or ``AuthState.unauthenticated``
  /// depending on the result.
  public func login() async -> Result<T, Error> {
    await login(strategy: authProvider.login)
  }

  /// Triggers a cached, UI-less re-authentication flow using previously stored credentials and updates the
  /// ``authState``.
  ///
  /// If no credentials were previously stored, or if there is an error reusing stored credentials, the resulting
  /// ``authState`` willl be ``AuthState.unauthenticated``. If supported by the ``AuthProvider``,
  /// a call to ``login()`` should store another set of credentials upon successful authentication.
  ///
  /// The ``authState`` is set to ``AuthState.loading`` once any pending auth changes have been applied
  /// and will change to either ``AuthState.authenticated`` or ``AuthState.unauthenticated``
  /// depending on the result.
  public func loginFromCache() async -> Result<T, Error> {
    await login(strategy: authProvider.loginFromCache)
  }

  /// Triggers a logout flow and updates the ``authState``.
  ///
  /// The ``authState`` will change to ``AuthState.unauthenticated`` if logout is successful.
  public func logout() async {
    do {
      try await authProvider.logout()
      try await authSession.clear(on: ffiClient)
    } catch {
      dump(error)
    }
  }

  private func login(strategy: LoginStrategy) async -> Result<T, Error> {
    authSession.beginLogin()
    do {
      let idTokenHandler = onIdTokenHandler()
      let authData = try await strategy(idTokenHandler)
      let token = authProvider.extractIdToken(from: authData)
      let bridge = AuthTokenProviderBridge(
        token: token,
        getValidToken: {
          [authProvider, idTokenHandler] in
          let refreshData = try await authProvider.loginFromCache(
            onIdToken: idTokenHandler
          )
          return authProvider.extractIdToken(from: refreshData)
        }
      )
      try await authSession.install(bridge, authData: authData, on: ffiClient)
      return Result.success(authData)
    } catch {
      dump(error)
      authSession.loginFailed()
      return Result.failure(error)
    }
  }

  /// Creates a sendable handler for token updates from the auth provider.
  ///
  /// This handler is passed to the auth provider during login and should be called
  /// whenever a fresh token is available or when the session becomes invalid.
  private func onIdTokenHandler() -> @Sendable (String?) -> Void {
    // `authSession` is captured weakly: the bridge holds this handler (via `getValidToken`) and is in
    // turn held by the session's operation loop, so a strong capture would keep the session, its loop
    // and the bridge alive forever.
    { [ffiClient, weak authSession] token in
      authSession?.pushToken(token, on: ffiClient)
    }
  }

  private typealias LoginStrategy = (@Sendable @escaping (String?) -> Void) async throws -> T
}

private class SubscriptionAdapter<T: Decodable>: QuerySubscriber {
  typealias Publisher = PassthroughSubject<T, ClientError>

  let publisher: Publisher

  init(publisher: Publisher) {
    self.publisher = publisher
  }

  func onError(message: String, value: String?) {
    let err: ClientError
    if let value {
      err = ClientError.ConvexError(data: value)
    } else {
      err = ClientError.ServerError(msg: message)
    }
    publisher.send(
      completion: Subscribers.Completion.failure(err))
  }

  func onUpdate(value: String) {
    do {
      publisher.send(try JSONDecoder().decode(Publisher.Output.self, from: Data(value.utf8)))
    } catch {
      publisher.send(
        completion: .failure(ClientError.InternalError(msg: error.localizedDescription)))
    }
  }
}

private class WebSocketStateAdapter: WebSocketStateSubscriber {
  private let subject = PassthroughSubject<WebSocketState, Never>()
  
  init() { }

  func onStateChange(state: UniFFI.WebSocketState) {
    subject.send(state)
  }
  
  func newPublisher() -> AnyPublisher<WebSocketState, Never> {
    return subject.eraseToAnyPublisher()
  }
}
