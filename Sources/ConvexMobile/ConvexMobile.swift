// The Swift Programming Language
// https://docs.swift.org/swift-book

import Combine
import Foundation
@_exported import UniFFI

/// A client API for interacting with a Convex backend.
///
/// Handles marshalling of data between calling code and the
/// [convex-mobile](https://github.com/get-convex/convex-mobile) and
/// [convex-rs](https://github.com/get-convex/convex-rs) native libraries.
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
  ///   - queryCacheDirectory: A directory to keep the latest query results in. Subscriptions in later
  ///     launches start with the cached results until fresh ones arrive, including while offline. Use
  ///     ``defaultQueryCacheDirectory(for:)`` unless you need a specific location. Cached results belong
  ///     to whoever was signed in, so call ``clearQueryCache()`` when the user signs out or another
  ///     user signs in (``ConvexClientWithAuth`` does this for you). Only query results are cached:
  ///     files they refer to, such as image URLs from storage, need their own cache to show offline.
  ///     For more settings, use ``init(deploymentUrl:queryCache:)``.
  public init(deploymentUrl: String, queryCacheDirectory: URL? = nil) {
    self.ffiClient = UniFFI.MobileConvexClient(
      deploymentUrl: deploymentUrl, clientId: "swift-\(convexMobileVersion)",
      webSocketStateSubscriber: webSocketStateAdapter,
      queryCache: queryCacheDirectory.map { QueryCacheOptions(directory: $0).ffiConfig })
  }

  /// Creates a new instance of ``ConvexClient`` that caches query results with the given settings.
  ///
  /// - Parameters:
  ///   - deploymentUrl: The Convex backend URL to connect to; find it in the [dashboard](https://dashboard.convex.dev) Settings for your project
  ///   - queryCache: Where and how to keep the latest query results; see ``QueryCacheOptions`` and
  ///     ``init(deploymentUrl:queryCacheDirectory:)``. `nil` caches nothing.
  public init(deploymentUrl: String, queryCache: QueryCacheOptions?) {
    self.ffiClient = UniFFI.MobileConvexClient(
      deploymentUrl: deploymentUrl, clientId: "swift-\(convexMobileVersion)",
      webSocketStateSubscriber: webSocketStateAdapter,
      queryCache: queryCache?.ffiConfig)
  }

  /// Returns a directory for caching query results from `deploymentUrl`, for use with
  /// ``init(deploymentUrl:queryCacheDirectory:)``.
  ///
  /// The directory is `ConvexQueryCache/<deployment>` inside a folder named after the app's bundle
  /// identifier (or its process name, if it has none) in the user's Application Support directory.
  /// The bundle identifier keeps apps that share an Application Support directory, such as
  /// unsandboxed macOS apps, from sharing a cache.
  ///
  /// Creates the directory if needed. Each call also excludes it from backups, since its contents
  /// can be fetched again, and on iOS, iPadOS, tvOS, watchOS and visionOS sets its file protection
  /// so files in it stay readable while the device is locked after its first unlock, letting apps
  /// refresh in the background.
  public static func defaultQueryCacheDirectory(for deploymentUrl: String) throws -> URL {
    let applicationSupport = try FileManager.default.url(
      for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true)
    let directory = defaultQueryCacheDirectory(
      for: deploymentUrl, in: applicationSupport,
      appIdentifier: Bundle.main.bundleIdentifier ?? ProcessInfo.processInfo.processName)
    try prepareQueryCacheDirectory(at: directory)
    return directory
  }

  /// The path of ``defaultQueryCacheDirectory(for:)`` within `applicationSupport`, without creating
  /// it.
  static func defaultQueryCacheDirectory(
    for deploymentUrl: String, in applicationSupport: URL, appIdentifier: String
  ) -> URL {
    func pathComponent(_ name: String, allowing allowed: CharacterSet) -> String {
      name.unicodeScalars.map { allowed.contains($0) ? String($0) : "_" }.joined()
    }
    let app = pathComponent(
      appIdentifier, allowing: CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-.")))
    let deployment = pathComponent(deploymentUrl, allowing: .alphanumerics)
    return applicationSupport
      .appendingPathComponent(app, isDirectory: true)
      .appendingPathComponent("ConvexQueryCache", isDirectory: true)
      .appendingPathComponent(deployment, isDirectory: true)
  }

  /// Creates `directory` if needed, then excludes it from backups and sets its file protection.
  /// Both are applied to an existing directory too, such as one created by an earlier version.
  static func prepareQueryCacheDirectory(at directory: URL) throws {
    var attributes: [FileAttributeKey: Any] = [:]
    #if os(iOS) || os(tvOS) || os(watchOS) || os(visionOS)
      attributes[.protectionKey] = FileProtectionType.completeUntilFirstUserAuthentication
    #endif
    try FileManager.default.createDirectory(
      at: directory, withIntermediateDirectories: true, attributes: attributes)
    // `createDirectory` doesn't change the attributes of a directory that already exists.
    if !attributes.isEmpty {
      try FileManager.default.setAttributes(attributes, ofItemAtPath: directory.path)
    }
    var resourceValues = URLResourceValues()
    resourceValues.isExcludedFromBackup = true
    var directory = directory
    try directory.setResourceValues(resourceValues)
  }

  /// Deletes cached query results, from memory and from the
  /// ``init(deploymentUrl:queryCacheDirectory:)`` directory. Results already delivered to subscribers are
  /// unaffected.
  ///
  /// Does nothing if the client was created without a query cache.
  public func clearQueryCache() async throws {
    try await ffiClient.clearQueryCache()
  }

  /// Waits until the query results cached so far are saved, for example before the app is
  /// suspended. Results are otherwise saved in the background, at most every half second.
  ///
  /// Does nothing if the client was created without a query cache.
  public func flushQueryCache() async throws {
    try await ffiClient.flushQueryCache()
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
  /// The returned publisher is backed by a single Convex subscription, which starts right away and
  /// ends when any subscriber to the publisher cancels. The publisher then finishes, for remaining
  /// and later subscribers alike, rather than leaving them with a result that no longer updates. To
  /// share results between several subscribers, use an operator such as `share()`, or call this
  /// method once per subscriber.
  ///
  /// - Parameters:
  ///   - name: A value in "module:query_name"  format that will be used when calling the backend
  ///   - args: An optional ``Dictionary`` of arguments to be sent to the backend query function
  ///   - output: The type of data that will be returned in the Publisher, as a convenience to callers
  ///             where the type can't be easily inferred.
  public func subscribe<T: Decodable>(
    to name: String, with args: [String: ConvexEncodable?]? = nil, yielding output: T.Type? = nil
  ) -> AnyPublisher<T, ClientError> {
    subscribeWithCacheInfo(to: name, with: args, yielding: output)
      .map(\.value)
      .eraseToAnyPublisher()
  }

  /// Like ``subscribe(to:with:yielding:)``, but each result says whether it was restored from the
  /// query cache (see ``QueryUpdate``), for example to show that it may be out of date.
  public func subscribeWithCacheInfo<T: Decodable>(
    to name: String, with args: [String: ConvexEncodable?]? = nil, yielding output: T.Type? = nil
  ) -> AnyPublisher<QueryUpdate<T>, ClientError> {
    // There are two steps to producing the final Publisher in this method.
    // 1. Subscribe to the data from Convex and publish the subscription handle
    // 2. Publish the Convex data once subscribed, and cancel the upstream subscription when
    //    downstream subscribers are done consuming data

    // This Publisher will ultimately publish the data received from Convex. It keeps the latest value
    // because the first one, such as a cached result, can arrive before the flatMap below subscribes.
    let convexPublisher = CurrentValueSubject<QueryUpdate<T>?, ClientError>(nil)
    let adapter = SubscriptionAdapter<T>(publisher: convexPublisher)

    // Cancels the upstream subscription, even if consumers stop listening before it has started.
    let handle = SubscriptionHandleBox()

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
          handle.set(subscriptionHandle)
          result(.success(subscriptionHandle))
        } catch {
          result(.failure(ClientError.InternalError(msg: error.localizedDescription)))
        }
      }
    }

    // The final Publisher publishes the data once the Convex subscription has started, and cancels
    // the upstream subscription when consumers are no longer listening for data.
    return initializationPublisher.flatMap({ _ in
      convexPublisher.compactMap({ $0 })
    })
    .handleEvents(
      receiveCompletion: { _ in
        handle.cancel()
      },
      receiveCancel: {
        handle.cancel()
        // The Convex subscription is over, so finish rather than leave other subscribers with a
        // stale value that looks live.
        convexPublisher.send(completion: .finished)
      }
    )
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

  /// Executes the mutation with the given `name` and `args`, applying `optimisticUpdate` to local query
  /// results while the mutation is in flight, and returns the result.
  ///
  /// Subscribers see the optimistically updated results right away. The update is rolled back once the
  /// mutation's result is reflected in query results from the server, or when the mutation fails.
  ///
  /// ```swift
  /// try await client.mutation("messages:send", with: ["body": body], optimisticUpdate: { store in
  ///   let messages: [Message] = try store.getQuery("messages:list") ?? []
  ///   try store.setQuery("messages:list", to: messages + [Message(body: body)])
  /// })
  /// ```
  ///
  /// For mutations that don't return a value, prefer calling the version of this method that doesn't return a value.
  ///
  /// - Parameters:
  ///   - name: A value in "module:mutation_name"  format that will be used when calling the backend
  ///   - args: An optional ``Dictionary`` of arguments to be sent to the backend mutation function
  ///   - optimisticUpdate: An ``OptimisticUpdate`` to apply to local query results
  public func mutation<T: Decodable>(
    _ name: String, with args: [String: ConvexEncodable?]? = nil,
    optimisticUpdate: @escaping OptimisticUpdate
  ) async throws -> T {
    let adapter = OptimisticUpdateAdapter(update: optimisticUpdate)
    return try await callForResult(name: name, args: args) { [ffiClient] name, args in
      do {
        return try await ffiClient.mutationWithOptimisticUpdate(
          name: name, args: args, optimisticUpdate: adapter)
      } catch {
        throw adapter.firstRunError ?? error
      }
    }
  }

  /// Executes the mutation with the given `name` and `args`, applying `optimisticUpdate` to local query
  /// results while the mutation is in flight, without returning a result.
  ///
  /// For mutations that return a value, prefer calling the version of this method that returns a ``Decodable`` value.
  ///
  /// - Parameters:
  ///   - name: A value in "module:mutation_name"  format that will be used when calling the backend
  ///   - args: An optional ``Dictionary`` of arguments to be sent to the backend mutation function
  ///   - optimisticUpdate: An ``OptimisticUpdate`` to apply to local query results
  public func mutation(
    _ name: String, with args: [String: ConvexEncodable?]? = nil,
    optimisticUpdate: @escaping OptimisticUpdate
  ) async throws {
    let _: String? = try await mutation(name, with: args, optimisticUpdate: optimisticUpdate)
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
  ///   Call with `nil` if the session becomes invalid (e.g., token refresh fails); this logs out the
  ///   client and clears cached query results.
  func login(onIdToken: @Sendable @escaping (String?) -> Void) async throws -> T

  /// Trigger a logout flow, which might launch a new UI/screen.
  func logout() async throws

  /// Trigger a cached, UI-less re-authentication using stored credentials from a previous ``login()``.
  ///
  /// For OAuth providers, this is a good place to check token validity and perform a refresh if necessary
  /// before returning the auth data as``T``.
  ///
  /// If the refresh fails because the device is offline, return the stored credentials rather than
  /// throwing, even if their token has expired. If this throws, ``ConvexClientWithAuth/authState``
  /// becomes ``AuthState/unauthenticated``, so apps that wait for ``AuthState/authenticated`` before
  /// subscribing never show cached query results while offline. (Subscriptions still start with cached
  /// results; only apps that gate on the auth state hide them.) The stale token is never checked
  /// offline, and ``ConvexClientWithAuth`` calls this again to get a fresh token when it reconnects.
  ///
  /// - Parameter onIdToken: A callback to invoke with a fresh JWT ID token. The auth provider should store
  ///   this callback and invoke it whenever a new token is available (e.g., on token refresh).
  ///   Call with `nil` if the session becomes invalid (e.g., token refresh fails); this logs out the
  ///   client and clears cached query results.
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
  ///
  /// If `isNewSession` and another session is installed, which happens when a user switches accounts
  /// without logging out, cached query results are cleared before ``AuthState/authenticated(_:)`` is
  /// published, so the previous user's results aren't shown or kept for the new user. This happens
  /// in the same queued operation, so a later login or token push can't run in between.
  func install(
    _ bridge: AuthTokenProviderBridge, authData: T, isNewSession: Bool,
    on ffiClient: MobileConvexClientProtocol
  ) async throws {
    try await perform { [authPublisher] current in
      // Cleared before the new session is installed, so the previous user's results aren't shown
      // to it and the new session's results aren't deleted.
      if isNewSession && current != nil {
        await Self.clearQueryCache(on: ffiClient)
      }
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
  ///
  /// A `nil` token means the session is no longer valid: the Rust client is logged out and cached
  /// query results are cleared, so they aren't shown to whoever signs in next.
  func pushToken(_ token: String?, on ffiClient: MobileConvexClientProtocol) {
    operations.yield { [authPublisher] current in
      guard let token else {
        var next = current
        do {
          try await ffiClient.setAuthCallback(provider: nil)
          next = nil
        } catch {
          dump(error)
        }
        // Like `logout()`, clear even if logging out the Rust client failed.
        await Self.clearQueryCache(on: ffiClient)
        authPublisher.send(.unauthenticated)
        return next
      }
      do {
        guard let current else { return nil }
        await current.updateToken(token)
        try await ffiClient.setAuthCallback(provider: current)
        return current
      } catch {
        dump(error)
        authPublisher.send(.unauthenticated)
        return current
      }
    }
  }

  /// Clears cached query results, logging rather than throwing errors so auth changes still apply.
  private static func clearQueryCache(on ffiClient: MobileConvexClientProtocol) async {
    do {
      try await ffiClient.clearQueryCache()
    } catch {
      dump(error)
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
  ///   - queryCacheDirectory: A directory to keep the latest query results in; see
  ///     ``ConvexClient/init(deploymentUrl:queryCacheDirectory:)``. It's cleared by ``logout()``, when
  ///     `authProvider` reports that the session is invalid by passing `nil` to `onIdToken`, and when
  ///     ``login()`` replaces a signed-in user's session, so one user's results aren't shown to the
  ///     next. If your app waits for ``AuthState/authenticated`` before subscribing, `authProvider`
  ///     must let ``loginFromCache()`` succeed offline with stored credentials, or cached results
  ///     won't show; see ``AuthProvider/loginFromCache(onIdToken:)``.
  public init(
    deploymentUrl: String, authProvider: any AuthProvider<T>, queryCacheDirectory: URL? = nil
  ) {
    self.authProvider = authProvider
    self.authState = authSession.authState
    super.init(deploymentUrl: deploymentUrl, queryCacheDirectory: queryCacheDirectory)
  }

  /// Creates a new instance of ``ConvexClientWithAuth`` that caches query results with the given
  /// settings; see ``init(deploymentUrl:authProvider:queryCacheDirectory:)`` and
  /// ``QueryCacheOptions``.
  public init(
    deploymentUrl: String, authProvider: any AuthProvider<T>, queryCache: QueryCacheOptions?
  ) {
    self.authProvider = authProvider
    self.authState = authSession.authState
    super.init(deploymentUrl: deploymentUrl, queryCache: queryCache)
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
  ///
  /// If a user is already signed in, cached query results are cleared once the new login succeeds,
  /// since it may be a different user. Call ``logout()`` first to clear them right away.
  public func login() async -> Result<T, Error> {
    await login(strategy: authProvider.login, isNewSession: true)
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
    await login(strategy: authProvider.loginFromCache, isNewSession: false)
  }

  /// Triggers a logout flow and updates the ``authState``.
  ///
  /// The ``authState`` will change to ``AuthState.unauthenticated`` if logout is successful. Cached query
  /// results are deleted even if logout fails, so they're never shown to the next user.
  public func logout() async {
    do {
      try await authProvider.logout()
      try await authSession.clear(on: ffiClient)
    } catch {
      dump(error)
    }
    do {
      try await clearQueryCache()
    } catch {
      dump(error)
    }
  }

  /// - Parameter isNewSession: Whether the login may be for a different user than the current
  ///   session's, which clears cached query results; see ``AuthSession/install(_:authData:isNewSession:on:)``.
  private func login(strategy: LoginStrategy, isNewSession: Bool) async -> Result<T, Error> {
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
      try await authSession.install(
        bridge, authData: authData, isNewSession: isNewSession, on: ffiClient)
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

/// Holds the handle of a Convex subscription, which arrives asynchronously, so it can be canceled
/// exactly once, whether cancellation is requested before or after it arrives.
private final class SubscriptionHandleBox: @unchecked Sendable {
  private let lock = NSLock()
  private var handle: SubscriptionHandle?
  private var canceled = false

  /// Stores `handle`, canceling it right away if ``cancel()`` was already called.
  func set(_ handle: SubscriptionHandle) {
    lock.lock()
    let cancelNow = canceled
    self.handle = handle
    lock.unlock()
    if cancelNow {
      handle.cancel()
    }
  }

  /// Cancels the handle if it has arrived, or as soon as it does. Later calls do nothing.
  func cancel() {
    lock.lock()
    let handle = canceled ? nil : self.handle
    canceled = true
    lock.unlock()
    handle?.cancel()
  }
}

private class SubscriptionAdapter<T: Decodable>: QuerySubscriber {
  typealias Publisher = CurrentValueSubject<QueryUpdate<T>?, ClientError>

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

  func onUpdate(value: String, cachedServerTs: UInt64?) {
    // Values from the server and values set by optimistic updates arrive the same way, so a value
    // that can't be decoded ends the subscription either way. `OptimisticLocalStore.setQuery`
    // encodes values the way they're decoded here, so values derived from server results decode.
    do {
      let decoded = try JSONDecoder().decode(T.self, from: Data(value.utf8))
      publisher.send(
        QueryUpdate(
          value: decoded,
          cachedAt: cachedServerTs.map { Date(timeIntervalSince1970: Double($0) / 1_000_000_000) }))
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

/// Where and how ``ConvexClient`` keeps query results across launches.
public struct QueryCacheOptions: Sendable, Equatable {
  /// The directory for the cache's database file, for example
  /// ``ConvexClient/defaultQueryCacheDirectory(for:)``. Use one directory per client.
  public var directory: URL
  /// How many query results to keep, evicting those the server sent least recently. `nil` keeps
  /// the default, 1000.
  public var capacity: Int?
  /// Don't restore results the server sent longer ago than this. `nil` restores them however old
  /// they are.
  public var maxAge: TimeInterval?
  /// Names ("module:function") of queries whose results are the same for every user. They're shown
  /// whoever is signed in and kept when users sign out. Only list queries that don't read
  /// `ctx.auth`, or one user's results will be shown to another.
  public var sharedQueries: Set<String>
  /// Keep a query's cached result when the server reports an error for it, so it's still restored
  /// in later launches, for example when the error is because a token expired. By default it's
  /// deleted.
  public var keepResultsOnError: Bool

  public init(
    directory: URL, capacity: Int? = nil, maxAge: TimeInterval? = nil,
    sharedQueries: Set<String> = [], keepResultsOnError: Bool = false
  ) {
    self.directory = directory
    self.capacity = capacity
    self.maxAge = maxAge
    self.sharedQueries = sharedQueries
    self.keepResultsOnError = keepResultsOnError
  }

  var ffiConfig: UniFFI.QueryCacheConfig {
    UniFFI.QueryCacheConfig(
      directory: directory.path,
      capacity: capacity.map { UInt32(clamping: $0) },
      maxAgeMs: maxAge.map { UInt64(max(0, $0 * 1000)) },
      sharedQueries: sharedQueries.sorted(),
      keepResultsOnError: keepResultsOnError)
  }
}

/// A query result from ``ConvexClient/subscribeWithCacheInfo(to:with:yielding:)``.
public struct QueryUpdate<T> {
  public let value: T
  /// Set when ``value`` was restored from the query cache and the server hasn't confirmed it since
  /// launch: when the server last sent it. Once the server sends its result, the subscription
  /// publishes it with `cachedAt` `nil`, even if the value is the same.
  public let cachedAt: Date?
  /// Whether ``value`` was restored from the query cache and may be out of date.
  public var isCached: Bool { cachedAt != nil }
}

extension QueryUpdate: Sendable where T: Sendable {}
extension QueryUpdate: Equatable where T: Equatable {}
