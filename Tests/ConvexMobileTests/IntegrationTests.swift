//
//  IntegrationTests.swift
//  ConvexMobile
//
//  Created by Christian Wyglendowski on 10/1/24.
//

import Combine
import Foundation
import ConvexMobile
import Testing

private let deploymentUrl = "https://curious-lynx-309.convex.cloud"

@Suite(.serialized) struct Test {
  init() async throws {
    let client = ConvexClient(deploymentUrl: deploymentUrl)
    try await client.mutation("messages:clearAll")
  }

  @Test func test_empty_subscribe() async throws {
    let client = ConvexClient(deploymentUrl: deploymentUrl)
    let s = client.subscribe(to: "messages:list", yielding: [Message]?.self)
    var received = 0
    for try await messages in s.replaceError(with: nil).first().valuesWithTimeout() {
      #expect(messages! == [])
      received += 1
    }
    #expect(received == 1)
  }

  @Test func test_convex_error_in_subscription() async throws {
    let client = ConvexClient(deploymentUrl: deploymentUrl)
    let s: AnyPublisher<[Message]?, ClientError> = client.subscribe(
      to: "messages:list", with: ["forceError": true])
    await #expect(throws: ClientError.ConvexError(data: "\"forced error data\"")) {
      for try await _ in s.first().valuesWithTimeout() {}
    }
  }

  @Test func test_convex_error_in_action() async throws {
    let client = ConvexClient(deploymentUrl: deploymentUrl)
    await #expect(throws: ClientError.ConvexError(data: "\"forced error data\"")) {
      try await client.action("messages:forceActionError")
    }
  }

  @Test func test_convex_error_in_mutation() async throws {
    let client = ConvexClient(deploymentUrl: deploymentUrl)
    await #expect(throws: ClientError.ConvexError(data: "\"forced error data\"")) {
      try await client.mutation("messages:forceMutationError")
    }
  }

  @Test func send_and_receive_one_message() async throws {
    let clientA = ConvexClient(deploymentUrl: deploymentUrl)
    let clientB = ConvexClient(deploymentUrl: deploymentUrl)

    let messagesA: AnyPublisher<[Message]?, ClientError> = clientA.subscribe(to: "messages:list")
    var resultsA = messagesA.replaceError(with: nil).valuesWithTimeout().makeAsyncIterator()

    // Wait for the initial empty list before sending, so the message can't arrive before clientA
    // is listening.
    #expect(try await resultsA.next()! == [])

    try await clientB.mutation(
      "messages:send", with: ["author": "Client B", "body": "Test 123"])

    #expect(try await resultsA.next()! == [Message(author: "Client B", body: "Test 123")])
  }

  @Test func optimistic_update_is_visible_until_mutation_is_reflected() async throws {
    let client = ConvexClient(deploymentUrl: deploymentUrl)
    let messages: AnyPublisher<[Message]?, ClientError> = client.subscribe(to: "messages:list")
    var results = messages.replaceError(with: nil).valuesWithTimeout().makeAsyncIterator()
    #expect(try await results.next()! == [])

    let optimistic = [Message(author: "Optimistic", body: "Test 123")]
    let fromServer = [Message(author: "Client", body: "Test 123")]
    let mutation = Task {
      try await client.mutation(
        "messages:send", with: ["author": "Client", "body": "Test 123"],
        optimisticUpdate: { store in
          let current: [Message] = try store.getQuery("messages:list") ?? []
          try store.setQuery("messages:list", to: current + optimistic)
        })
    }

    // The optimistic value is applied before the mutation is sent, and stays until the mutation's
    // result is reflected in the query. A subscriber that isn't waiting for a value only gets the
    // latest one, though, so the optimistic value can be skipped if the server's result arrives
    // while the test isn't waiting.
    var latest = try await results.next()!!
    #expect(latest == optimistic || latest == fromServer)
    while latest == optimistic {
      latest = try await results.next()!!
    }
    #expect(latest == fromServer)
    try await mutation.value
  }

  @Test func optimistic_update_rolls_back_when_mutation_fails() async throws {
    let client = ConvexClient(deploymentUrl: deploymentUrl)
    let messages: AnyPublisher<[Message]?, ClientError> = client.subscribe(to: "messages:list")
    var results = messages.replaceError(with: nil).valuesWithTimeout().makeAsyncIterator()
    #expect(try await results.next()! == [])

    let mutation = Task {
      try await client.mutation(
        "messages:forceMutationError",
        optimisticUpdate: { store in
          try store.setQuery("messages:list", to: [Message(author: "Optimistic", body: "Nope")])
        })
    }

    // As above, the optimistic value can be skipped if the rollback arrives while the test isn't
    // waiting.
    var latest = try await results.next()!!
    if latest == [Message(author: "Optimistic", body: "Nope")] {
      latest = try await results.next()!!
    }
    #expect(latest == [])
    await #expect(throws: ClientError.ConvexError(data: "\"forced error data\"")) {
      try await mutation.value
    }
  }

  @Test func throwing_optimistic_update_fails_the_mutation_without_sending_it() async throws {
    struct BadUpdate: Error {}
    let client = ConvexClient(deploymentUrl: deploymentUrl)
    let messages: AnyPublisher<[Message]?, ClientError> = client.subscribe(to: "messages:list")
    var results = messages.replaceError(with: nil).valuesWithTimeout().makeAsyncIterator()
    #expect(try await results.next()! == [])

    await #expect(throws: BadUpdate.self) {
      try await client.mutation(
        "messages:send", with: ["author": "Client", "body": "Never sent"],
        optimisticUpdate: { store in
          try store.setQuery("messages:list", to: [Message(author: "Optimistic", body: "Nope")])
          throw BadUpdate()
        })
    }

    // The client still works, and the message was never sent.
    let fromServer = [Message(author: "Client", body: "Sent")]
    try await client.mutation("messages:send", with: ["author": "Client", "body": "Sent"])
    #expect(try await results.next()! == fromServer)
  }

  @Test func cached_results_are_shown_offline_after_restart() async throws {
    let cacheDirectory = temporaryCacheDirectory()
    defer { try? FileManager.default.removeItem(at: cacheDirectory) }
    let expected = [Message(author: "Cache", body: "Test 123")]
    try await cacheMessages(expected, in: cacheDirectory)
    try moveCachedResults(in: cacheDirectory, to: offlineDeploymentUrl)

    // A new client that can't reach its deployment still starts with the cached result.
    let offline = ConvexClient(
      deploymentUrl: offlineDeploymentUrl, queryCacheDirectory: cacheDirectory)
    let offlineMessages: AnyPublisher<[Message], ClientError> = offline.subscribe(
      to: "messages:list")
    var offlineResults = offlineMessages.valuesWithTimeout().makeAsyncIterator()
    #expect(try await offlineResults.next() == expected)

    try await offline.clearQueryCache()
    #expect(cachedFiles(in: cacheDirectory).isEmpty)
  }

  @Test func cached_results_are_shown_offline_when_signed_in_with_an_expired_token() async throws {
    let cacheDirectory = temporaryCacheDirectory()
    defer { try? FileManager.default.removeItem(at: cacheDirectory) }
    let expected = [Message(author: "Cache", body: "Signed in")]
    try await cacheMessages(expected, in: cacheDirectory)
    try moveCachedResults(in: cacheDirectory, to: offlineDeploymentUrl)

    // Apps commonly wait until they're signed in to subscribe, so signing in offline must succeed
    // for cached results to show.
    let offline = ConvexClientWithAuth(
      deploymentUrl: offlineDeploymentUrl, authProvider: OfflineAuthProvider(),
      queryCacheDirectory: cacheDirectory)
    let login = await offline.loginFromCache()
    #expect(try login.get() == OfflineAuthProvider.expiredToken)
    for try await state in offline.authState.valuesWithTimeout() {
      if case .authenticated = state { break }
    }

    let offlineMessages: AnyPublisher<[Message], ClientError> = offline.subscribe(
      to: "messages:list")
    var offlineResults = offlineMessages.valuesWithTimeout().makeAsyncIterator()
    #expect(try await offlineResults.next() == expected)
  }

  /// A deployment URL that can't be reached, standing in for this test's deployment while offline.
  private let offlineDeploymentUrl = "https://offline.invalid/"

  /// Cached results are only restored for the deployment they came from, so make the results in
  /// `directory` look like they came from `deploymentUrl`.
  private func moveCachedResults(in directory: URL, to deploymentUrl: String) throws {
    for file in cachedFiles(in: directory) {
      let url = directory.appendingPathComponent(file)
      var file = try JSONSerialization.jsonObject(with: Data(contentsOf: url)) as! [String: Any]
      var query = file["query"] as! [String: Any]
      query["deploymentUrl"] = deploymentUrl
      file["query"] = query
      try JSONSerialization.data(withJSONObject: file).write(to: url)
    }
  }

  private func temporaryCacheDirectory() -> URL {
    FileManager.default.temporaryDirectory
      .appendingPathComponent("convex-query-cache-\(UUID().uuidString)", isDirectory: true)
  }

  /// Cache files in `directory`. Saves write a temporary file first, so only finished files count.
  private func cachedFiles(in directory: URL) -> [String] {
    ((try? FileManager.default.contentsOfDirectory(atPath: directory.path)) ?? [])
      .filter { $0.hasSuffix(".convexquery") }
  }

  /// Sends `messages` and waits until a client with a cache in `directory` has saved them as the
  /// result of `messages:list`.
  private func cacheMessages(_ messages: [Message], in directory: URL) async throws {
    let online = ConvexClient(deploymentUrl: deploymentUrl, queryCacheDirectory: directory)
    for message in messages {
      try await online.mutation(
        "messages:send", with: ["author": message.author, "body": message.body])
    }
    let onlineMessages: AnyPublisher<[Message], ClientError> = online.subscribe(to: "messages:list")
    var onlineResults = onlineMessages.valuesWithTimeout().makeAsyncIterator()
    #expect(try await onlineResults.next() == messages)

    // Saves happen in the background at most every 500ms.
    let deadline = Date().addingTimeInterval(5)
    while cachedFiles(in: directory).isEmpty && Date() < deadline {
      try await Task.sleep(nanoseconds: 50_000_000)
    }
    #expect(!cachedFiles(in: directory).isEmpty)
  }

  @Test func send_and_receive_multiple_messages() async throws {
    let clientA = ConvexClient(deploymentUrl: deploymentUrl)
    let clientB = ConvexClient(deploymentUrl: deploymentUrl)

    let messagesA: AnyPublisher<[Message]?, ClientError> = clientA.subscribe(to: "messages:list")

    var resultsA = messagesA.replaceError(with: nil).valuesWithTimeout().makeAsyncIterator()
    var latest = try await resultsA.next()!
    #expect(latest == [])

    // Each send is awaited before the next, so clientA sees each new message in turn. Transitions
    // that don't change the query can repeat the previous result, so skip repeats.
    for i in 1...3 {
      try await clientB.mutation(
        "messages:send", with: ["author": "Client B", "body": "Message \(i)"])
      let previous = latest
      while latest == previous {
        latest = try await resultsA.next()!
      }
      #expect(latest == (1...i).map { Message(author: "Client B", body: "Message \($0)") })
    }
  }

  @Test func can_round_trip_max_value_args() async throws {
    let client = ConvexClient(deploymentUrl: deploymentUrl)
    let maxValues = NumericValues(
      anInt64: Int64.max, aFloat64: Double.greatestFiniteMagnitude,
      jsNumber: Double.greatestFiniteMagnitude, anInt32: Int32.max,
      aFloat32: Float32.greatestFiniteMagnitude)

    let result: NumericValues = try await client.action(
      "messages:echoValidatedArgs", with: maxValues.toArgs())

    #expect(result == maxValues)
  }

  @Test func can_round_trip_special_floats() async throws {
    let client = ConvexClient(deploymentUrl: deploymentUrl)
    let specialFloats = SpecialFloats()
    let result: SpecialFloats = try await client.action(
      "messages:echoArgs", with: specialFloats.toArgs())

    #expect(result.f32Nan.isNaN)
    #expect(result.f32NegInf == specialFloats.f32NegInf)
    #expect(result.f32PosInf == specialFloats.f32PosInf)
    #expect(result.f64Nan.isNaN)
    #expect(result.f64NegInf == specialFloats.f64NegInf)
    #expect(result.f64PosInf == specialFloats.f64PosInf)
  }

  @Test func can_receive_numbers() async throws {
    let client = ConvexClient(deploymentUrl: deploymentUrl)
    let result: NumericValues = try await client.action("messages:numbers")
    let expected = NumericValues(
      anInt64: 100, aFloat64: 100.0, jsNumber: 100.0, anInt32: 100, aFloat32: 100.0)
    #expect(result == expected)
    #expect(result.aPlainInt == 100)
  }

  @Test func can_receive_null_and_missing_float64_values() async throws {
    let client = ConvexClient(deploymentUrl: deploymentUrl)
    let result: NullableFloats = try await client.action(
      "messages:echoArgs", with: ["aNullableDouble": nil])
    #expect(result == NullableFloats())
  }
  
  @Test func can_observe_websocket_state() async throws {
    let client = ConvexClient(deploymentUrl: deploymentUrl)

    // The client connects on its first call, so collecting with `sink` beforehand sees every state
    // change. States arrive on a background thread.
    let lock = NSLock()
    var states: [WebSocketState] = []
    let cancellable = client.watchWebSocketState().sink { state in
      lock.withLock { states.append(state) }
    }

    try await client.mutation("messages:clearAll")

    let deadline = Date().addingTimeInterval(5)
    while lock.withLock({ states.count }) < 2 && Date() < deadline {
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    cancellable.cancel()
    #expect(lock.withLock { Array(states.prefix(2)) } == [.connecting, .connected])
  }
}

/// Thrown when a publisher doesn't publish a value in time.
private struct TimedOut: Error {}

extension Publisher {
  /// Like `values`, but throws ``TimedOut`` if no value arrives within `seconds` of subscribing or
  /// of the previous value, so a missing value fails the test instead of hanging the suite.
  fileprivate func valuesWithTimeout(_ seconds: Int = 10)
    -> AsyncThrowingPublisher<AnyPublisher<Output, Error>>
  {
    // `timeout` delivers events on its scheduler, so it must be serial: on a concurrent queue,
    // the completion `first()` sends right after its value can overtake it.
    mapError { $0 as Error }
      .timeout(
        .seconds(seconds), scheduler: DispatchQueue(label: "valuesWithTimeout"),
        customError: { TimedOut() })
      .eraseToAnyPublisher()
      .values
  }
}

private struct Message: Codable, Equatable {
  let author: String
  let body: String
}

private struct NumericValues: Decodable, Equatable {
  init(anInt64: Int64, aFloat64: Float64, jsNumber: Double, anInt32: Int32, aFloat32: Float32) {
    self.anInt64 = anInt64
    self.aFloat64 = aFloat64
    self.jsNumber = jsNumber
    self.anInt32 = anInt32
    self.aFloat32 = aFloat32
  }

  @ConvexInt
  var anInt64: Int64
  @ConvexFloat
  var aFloat64: Float64
  @ConvexFloat
  private var jsNumber: Double
  @ConvexInt
  var anInt32: Int32
  @ConvexFloat
  var aFloat32: Float32

  enum CodingKeys: String, CodingKey {
    case anInt64
    case aFloat64
    case jsNumber = "aPlainInt"
    case anInt32
    case aFloat32
  }

  func toArgs() -> [String: ConvexEncodable] {
    [
      "anInt64": anInt64,
      "aFloat64": aFloat64,
      "aPlainInt": jsNumber,
      "anInt32": anInt32,
      "aFloat32": aFloat32,
    ]
  }

  // Expose the JavaScript number value as an Int.
  var aPlainInt: Int { Int(jsNumber) }
}

private struct SpecialFloats: Decodable, Equatable {
  @ConvexFloat
  var f64Nan: Float64 = Float64.nan
  @ConvexFloat
  var f64NegInf: Double = -Double.infinity
  @ConvexFloat
  var f64PosInf: Double = Double.infinity
  @ConvexFloat
  var f32Nan: Float32 = Float32.nan
  @ConvexFloat
  var f32NegInf: Float32 = -Float32.infinity
  @ConvexFloat
  var f32PosInf: Float = Float.infinity

  func toArgs() -> [String: ConvexEncodable] {
    [
      "f64Nan": f64Nan,
      "f64NegInf": f64NegInf,
      "f64PosInf": f64PosInf,
      "f32Nan": f32Nan,
      "f32NegInf": f32NegInf,
      "f32PosInf": f32PosInf,
    ]
  }
}

private struct NullableFloats: Decodable, Equatable {
  @OptionalConvexFloat
  var aNullableDouble: Double?
  @OptionalConvexFloat
  var aMissingDouble: Double?
}

/// An ``AuthProvider`` whose stored token has expired and can't be refreshed because the device is
/// offline. It returns the stored credentials anyway, as providers should for cached results to show.
private final class OfflineAuthProvider: AuthProvider {
  static let expiredToken = "expired-token"

  func loginFromCache(onIdToken: @Sendable @escaping (String?) -> Void) async throws -> String {
    do {
      return try await refreshedToken()
    } catch is URLError {
      return Self.expiredToken
    }
  }

  func login(onIdToken: @Sendable @escaping (String?) -> Void) async throws -> String {
    throw URLError(.notConnectedToInternet)
  }

  func logout() async throws {}

  func extractIdToken(from authResult: String) -> String { authResult }

  private func refreshedToken() async throws -> String {
    throw URLError(.notConnectedToInternet)
  }
}
