import Combine
import XCTest

@testable import ConvexMobile
@testable import UniFFI

final class ConvexMobileTests: XCTestCase {
  func testSubscribeResult() async throws {
    let expectation = self.expectation(description: "subscribe")
    var error: ClientError?
    var result: Message?
    let client = ConvexMobile.ConvexClient(ffiClient: FakeMobileConvexClient())

    let cancellationHandle = client.subscribe(to: "foo").sink(
      receiveCompletion: { completion in
        switch completion {
        case .finished:
          break
        case .failure(let clientError):
          error = clientError
          break
        }
      },
      receiveValue: { (value: Message) in
        result = value
        expectation.fulfill()
      })

    await fulfillment(of: [expectation], timeout: 10)

    XCTAssertEqual(result!.id, "the_id")
    XCTAssertEqual(result!.val, 42)
    XCTAssertNil(error)
  }

  func testSubscribeReceivesValueSentBeforeSubscribing() async throws {
    let expectation = self.expectation(description: "subscribe")
    var result: Message?
    let client = ConvexMobile.ConvexClient(ffiClient: FakeMobileConvexClient())

    // The fake sends this query's value before `subscribe` returns, like a cached result.
    let cancellationHandle = client.subscribe(to: "immediate").sink(
      receiveCompletion: { _ in },
      receiveValue: { (value: Message) in
        result = value
        expectation.fulfill()
      })

    await fulfillment(of: [expectation], timeout: 10)
    cancellationHandle.cancel()
    XCTAssertEqual(result?.val, 42)
  }

  func testSubscribeWithCacheInfoSaysWhichResultsAreCached() async throws {
    struct Count: Decodable, Equatable { let n: Int }
    let expectation = self.expectation(description: "subscribe")
    expectation.expectedFulfillmentCount = 2
    var updates: [QueryUpdate<Count>] = []
    let client = ConvexMobile.ConvexClient(ffiClient: FakeMobileConvexClient())

    let cancellationHandle = client.subscribeWithCacheInfo(to: "cachedThenFresh", yielding: Count.self)
      .sink(
        receiveCompletion: { _ in },
        receiveValue: { update in
          updates.append(update)
          expectation.fulfill()
        })

    await fulfillment(of: [expectation], timeout: 10)
    cancellationHandle.cancel()
    XCTAssertEqual(
      updates,
      [
        QueryUpdate(value: Count(n: 1), cachedAt: Date(timeIntervalSince1970: 1_767_225_600)),
        QueryUpdate(value: Count(n: 1), cachedAt: nil),
      ])
    XCTAssertTrue(updates[0].isCached)
    XCTAssertFalse(updates[1].isCached)
  }

  func testQueryCacheOptionsReachTheFfiClient() {
    let options = QueryCacheOptions(
      directory: URL(fileURLWithPath: "/tmp/cache", isDirectory: true), capacity: 50, maxAge: 1.5,
      sharedQueries: ["products:list", "config:get"], keepResultsOnError: true)
    let config = options.ffiConfig
    XCTAssertEqual(config.directory, "/tmp/cache")
    XCTAssertEqual(config.capacity, 50)
    XCTAssertEqual(config.maxAgeMs, 1500)
    XCTAssertEqual(config.sharedQueries, ["config:get", "products:list"])
    XCTAssertTrue(config.keepResultsOnError)

    let defaults = QueryCacheOptions(directory: URL(fileURLWithPath: "/tmp/cache")).ffiConfig
    XCTAssertNil(defaults.capacity)
    XCTAssertNil(defaults.maxAgeMs)
    XCTAssertEqual(defaults.sharedQueries, [])
    XCTAssertFalse(defaults.keepResultsOnError)
  }

  func testFlushQueryCacheCallsFfiClient() async throws {
    let fakeFfiClient = FakeMobileConvexClient()
    let client = ConvexMobile.ConvexClient(ffiClient: fakeFfiClient)

    try await client.flushQueryCache()

    XCTAssertEqual(fakeFfiClient.flushQueryCacheCount, 1)
  }

  func testClearQueryCacheCallsFfiClient() async throws {
    let fakeFfiClient = FakeMobileConvexClient()
    let client = ConvexMobile.ConvexClient(ffiClient: fakeFfiClient)

    try await client.clearQueryCache()

    XCTAssertEqual(fakeFfiClient.clearQueryCacheCount, 1)
  }

  func testLogoutClearsQueryCache() async throws {
    let fakeFfiClient = FakeMobileConvexClient()
    let client = ConvexClientWithAuth(ffiClient: fakeFfiClient, authProvider: FakeAuthProvider())
    _ = await client.login()

    await client.logout()

    XCTAssertEqual(fakeFfiClient.clearQueryCacheCount, 1)
  }

  func testDefaultQueryCacheDirectoryIsPerAppAndDeployment() throws {
    let applicationSupport = URL(fileURLWithPath: "/AppSupport", isDirectory: true)
    func directory(_ deploymentUrl: String, app: String = "com.example.App") -> URL {
      ConvexClient.defaultQueryCacheDirectory(
        for: deploymentUrl, in: applicationSupport, appIdentifier: app)
    }

    XCTAssertEqual(
      directory("https://a-1.convex.cloud").path,
      "/AppSupport/com.example.App/ConvexQueryCache/https___a_1_convex_cloud")
    XCTAssertNotEqual(directory("https://a-1.convex.cloud"), directory("https://b-2.convex.cloud"))
    XCTAssertNotEqual(
      directory("https://a-1.convex.cloud", app: "com.example.Other"),
      directory("https://a-1.convex.cloud"))
    XCTAssertEqual(
      directory("https://a-1.convex.cloud", app: "my/tool").pathComponents.dropLast(2).last,
      "my_tool")
  }

  func testPrepareQueryCacheDirectoryExcludesExistingDirectoryFromBackup() throws {
    let root = FileManager.default.temporaryDirectory
      .appendingPathComponent("convex-query-cache-\(UUID().uuidString)", isDirectory: true)
    defer { try? FileManager.default.removeItem(at: root) }
    let directory = root.appendingPathComponent("cache", isDirectory: true)
    try FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)

    try ConvexClient.prepareQueryCacheDirectory(at: directory)
    try ConvexClient.prepareQueryCacheDirectory(at: directory)

    let values = try directory.resourceValues(forKeys: [.isExcludedFromBackupKey])
    XCTAssertEqual(values.isExcludedFromBackup, true)
  }

  func testInvalidSessionClearsQueryCache() async throws {
    let fakeFfiClient = FakeMobileConvexClient()
    let fakeAuthProvider = FakeAuthProvider()
    let client = ConvexClientWithAuth(ffiClient: fakeFfiClient, authProvider: fakeAuthProvider)
    _ = await client.login()

    fakeAuthProvider.simulateTokenRefresh(newToken: nil)
    // Auth changes are applied in call order, so the invalidation has been applied once this
    // returns. Cached logins never clear the cache.
    _ = await client.loginFromCache()

    XCTAssertEqual(fakeFfiClient.clearQueryCacheCount, 1)
  }

  func testLoginWhileSignedInClearsQueryCache() async throws {
    let fakeFfiClient = FakeMobileConvexClient()
    let client = ConvexClientWithAuth(ffiClient: fakeFfiClient, authProvider: FakeAuthProvider())
    _ = await client.login()
    XCTAssertEqual(fakeFfiClient.clearQueryCacheCount, 0)

    // A user switching accounts without logging out.
    _ = await client.login()

    XCTAssertEqual(fakeFfiClient.clearQueryCacheCount, 1)
  }

  func testLoginFromCacheWhileSignedInKeepsQueryCache() async throws {
    let fakeFfiClient = FakeMobileConvexClient()
    let client = ConvexClientWithAuth(ffiClient: fakeFfiClient, authProvider: FakeAuthProvider())
    _ = await client.login()

    _ = await client.loginFromCache()

    XCTAssertEqual(fakeFfiClient.clearQueryCacheCount, 0)
  }

  func testLogoutClearsQueryCacheEvenIfLogoutFails() async throws {
    let fakeFfiClient = FakeMobileConvexClient()
    let client = ConvexClientWithAuth(
      ffiClient: fakeFfiClient, authProvider: FailingLogoutAuthProvider())

    await client.logout()

    XCTAssertEqual(fakeFfiClient.clearQueryCacheCount, 1)
  }

  func testSubscribeCanTrimDupeVals() async throws {
    let receivedSomething = self.expectation(description: "subscribe")
    let donePublishing = self.expectation(description: "done_publishing")
    var error: ClientError?
    var result: [Message] = []
    let client = ConvexMobile.ConvexClient(
      ffiClient: FakeMobileConvexClient(resultPublished: donePublishing))

    let cancellationHandle = client.subscribe(to: "dupeVals")
      .removeDuplicates()
      .sink(
        receiveCompletion: { completion in
          switch completion {
          case .finished:
            break
          case .failure(let clientError):
            error = clientError
            break
          }
        },
        receiveValue: { (value: Message) in
          result.append(value)
          if result.count == 1 {
            receivedSomething.fulfill()
          }
        })

    await fulfillment(of: [donePublishing, receivedSomething], timeout: 10)

    XCTAssertEqual(result.count, 1)
    XCTAssertNil(error)
  }

  func testSubscribeOptionalResultWithPresentVal() async throws {
    let expectation = self.expectation(description: "subscribe")
    var error: ClientError?
    var result: MessageWithOptionalVal?
    let client = ConvexMobile.ConvexClient(ffiClient: FakeMobileConvexClient())

    let cancellationHandle = client.subscribe(to: "foo").sink(
      receiveCompletion: { completion in
        switch completion {
        case .finished:
          break
        case .failure(let clientError):
          error = clientError
          break
        }
      },
      receiveValue: { (value: MessageWithOptionalVal?) in
        result = value
        expectation.fulfill()
      })

    await fulfillment(of: [expectation], timeout: 10)

    XCTAssertEqual(result!.id, "the_id")
    XCTAssertEqual(result!.val, 42)
    XCTAssertNil(error)
  }

  func testSubscribeOptionalResultWithNullVal() async throws {
    let expectation = self.expectation(description: "subscribe")
    var error: ClientError?
    var result: MessageWithOptionalVal?
    let client = ConvexMobile.ConvexClient(ffiClient: FakeMobileConvexClient())

    let cancellationHandle = client.subscribe(to: "nullVal").sink(
      receiveCompletion: { completion in
        switch completion {
        case .finished:
          break
        case .failure(let clientError):
          error = clientError
          break
        }
      },
      receiveValue: { (value: MessageWithOptionalVal?) in
        result = value
        expectation.fulfill()
      })

    await fulfillment(of: [expectation], timeout: 10)

    XCTAssertEqual(result!.id, "the_id")
    XCTAssertEqual(result!.val, nil)
    XCTAssertNil(error)
  }

  func testSubscribeOptionalResultWithMissingVal() async throws {
    let expectation = self.expectation(description: "subscribe")
    var error: ClientError?
    var result: MessageWithOptionalVal?
    let client = ConvexMobile.ConvexClient(ffiClient: FakeMobileConvexClient())

    let cancellationHandle = client.subscribe(to: "missingVal").sink(
      receiveCompletion: { completion in
        switch completion {
        case .finished:
          break
        case .failure(let clientError):
          error = clientError
          break
        }
      },
      receiveValue: { (value: MessageWithOptionalVal?) in
        result = value
        expectation.fulfill()
      })

    await fulfillment(of: [expectation], timeout: 10)

    XCTAssertEqual(result!.id, "the_id")
    XCTAssertEqual(result!.val, nil)
    XCTAssertNil(error)
  }

  func testMissingSubscribeArgs() async throws {
    let expectation = self.expectation(description: "subscribe")
    let fakeFfiClient = FakeMobileConvexClient()
    let client = ConvexMobile.ConvexClient(ffiClient: fakeFfiClient)

    let cancellationHandle = try client.subscribe(to: "foo").sink(
      receiveCompletion: { completion in
        switch completion {
        case .finished:
          break
        case .failure:
          break
        }
      },
      receiveValue: { (value: Message) in
        expectation.fulfill()
      })

    await fulfillment(of: [expectation], timeout: 10)

    XCTAssertEqual(fakeFfiClient.subscriptionArgs, [:])
  }

  func testPopulatedSubscribeArgs() async throws {
    let expectation = self.expectation(description: "subscribe")
    let fakeFfiClient = FakeMobileConvexClient()
    let client = ConvexMobile.ConvexClient(ffiClient: fakeFfiClient)

    let cancellationHandle = client.subscribe(
      to: "foo",
      with: [
        "aString": "bar", "aDouble": 42.0, "anInt": 42, "aNil": nil,
        "aDict": ["sub1": 1.0, "nested": ["ohmy": true]], "aList": [true, false, true, nil],
      ]
    ).sink(
      receiveCompletion: { completion in
        switch completion {
        case .finished:
          break
        case .failure:
          break
        }
      }) {
        (value: Message) in
        expectation.fulfill()
      }

    await fulfillment(of: [expectation], timeout: 10)

    XCTAssertEqual(fakeFfiClient.subscriptionArgs["aString"], "\"bar\"")
    XCTAssertEqual(fakeFfiClient.subscriptionArgs["aDouble"], "42")
    XCTAssertEqual(fakeFfiClient.subscriptionArgs["anInt"], "{\"$integer\":\"KgAAAAAAAAA=\"}")
    XCTAssertEqual(fakeFfiClient.subscriptionArgs["aNil"], "null")
    XCTAssertEqual(
      fakeFfiClient.subscriptionArgs["aDict"], "{\"nested\":{\"ohmy\":true},\"sub1\":1}")
    XCTAssertEqual(fakeFfiClient.subscriptionArgs["aList"], "[true,false,true,null]")

  }

  func testSubscribeCancellation() async throws {
    let expectation = self.expectation(description: "subscribe")
    var error: ClientError?
    let ffiClient = FakeMobileConvexClient()
    let client = ConvexMobile.ConvexClient(ffiClient: ffiClient)

    let cancellationHandle = client.subscribe(to: "foo").sink(
      receiveCompletion: { completion in
        switch completion {
        case .finished:
          break
        case .failure(let clientError):
          error = clientError
          break
        }
      },
      receiveValue: { (value: Message) in
        expectation.fulfill()
      })

    await fulfillment(of: [expectation], timeout: 10)
    cancellationHandle.cancel()

    XCTAssertEqual(ffiClient.cancellationCount, 1)
    XCTAssertNil(error)
  }

  func testSubscribeFinishesForLaterSubscribersAfterCancellation() async throws {
    let received = self.expectation(description: "first subscriber received a value")
    let ffiClient = FakeMobileConvexClient()
    let client = ConvexMobile.ConvexClient(ffiClient: ffiClient)
    let publisher: AnyPublisher<Message, ClientError> = client.subscribe(to: "foo")

    let first = publisher.sink(receiveCompletion: { _ in }, receiveValue: { _ in received.fulfill() })
    await fulfillment(of: [received], timeout: 10)
    first.cancel()
    XCTAssertEqual(ffiClient.cancellationCount, 1)

    // The Convex subscription is gone, so a later subscriber must not get its last value.
    let finished = self.expectation(description: "later subscriber finished")
    let later = publisher.sink(
      receiveCompletion: { completion in
        if case .finished = completion { finished.fulfill() }
      },
      receiveValue: { _ in XCTFail("A canceled subscription should not publish values") })
    await fulfillment(of: [finished], timeout: 10)
    later.cancel()
    XCTAssertEqual(ffiClient.cancellationCount, 1)
  }

  func testSubscribeCancellationBeforeSubscriptionStartsCancelsIt() async throws {
    let ffiClient = FakeMobileConvexClient()
    let client = ConvexMobile.ConvexClient(ffiClient: ffiClient)

    // The fake takes a while to start this subscription, so this cancels before its handle arrives.
    client.subscribe(to: "slowStart", yielding: Message.self)
      .sink(receiveCompletion: { _ in }, receiveValue: { _ in })
      .cancel()

    let deadline = Date().addingTimeInterval(5)
    while ffiClient.cancellationCount == 0 && Date() < deadline {
      try await Task.sleep(nanoseconds: 10_000_000)
    }
    XCTAssertEqual(ffiClient.cancellationCount, 1)
  }

  func testMutationRoundTrip() async throws {
    let fakeFfiClient = FakeMobileConvexClient()
    let client = ConvexMobile.ConvexClient(ffiClient: fakeFfiClient)

    let message: Message = try await client.mutation("foo", with: ["anInt": 101])

    XCTAssertEqual(message.id, "the_id")
    XCTAssertEqual(message.val, 101)
  }

  func testVoidMutation() async throws {
    let fakeFfiClient = FakeMobileConvexClient()
    let client = ConvexMobile.ConvexClient(ffiClient: fakeFfiClient)

    try await client.mutation("nullResult")

    XCTAssertEqual(fakeFfiClient.mutationCalls, ["nullResult"])
  }

  func testOptimisticUpdateSetsQueryAndRunsMutation() async throws {
    let fakeFfiClient = FakeMobileConvexClient()
    fakeFfiClient.optimisticStore.values[
      FakeOptimisticLocalStore.key("notes:list", ["channel": "\"a\""])] =
      "[{\"body\":\"first\",\"likes\":{\"$integer\":\"AQAAAAAAAAA=\"}}]"
    let client = ConvexMobile.ConvexClient(ffiClient: fakeFfiClient)

    let message: Message = try await client.mutation(
      "foo", with: ["anInt": 101],
      optimisticUpdate: { store in
        let notes: [Note] = try store.getQuery("notes:list", with: ["channel": "a"]) ?? []
        try store.setQuery(
          "notes:list", with: ["channel": "a"], to: notes + [Note(body: "second", likes: 0)])
      })

    XCTAssertEqual(message.val, 101)
    XCTAssertEqual(fakeFfiClient.mutationCalls, ["foo"])
    let notes = try JSONDecoder().decode(
      [Note].self,
      from: Data(
        fakeFfiClient.optimisticStore.values[
          FakeOptimisticLocalStore.key("notes:list", ["channel": "\"a\""])]!!.utf8))
    XCTAssertEqual(notes, [Note(body: "first", likes: 1), Note(body: "second", likes: 0)])
  }

  func testOptimisticUpdateGetAllQueriesArgsRoundTrip() async throws {
    let fakeFfiClient = FakeMobileConvexClient()
    fakeFfiClient.optimisticStore.values[
      FakeOptimisticLocalStore.key("counter:get", ["name": "\"a\""])] = "1"
    fakeFfiClient.optimisticStore.values[
      FakeOptimisticLocalStore.key("counter:get", ["name": "\"b\""])] = "2"
    let client = ConvexMobile.ConvexClient(ffiClient: fakeFfiClient)

    // Optimistic updates are `@Sendable`, so collect names through a lock.
    let names = Locked<[String]>([])
    try await client.mutation(
      "nullResult",
      optimisticUpdate: { store in
        for query in try store.getAllQueries("counter:get", yielding: Double.self) {
          let name = try query.decodeArgs(as: CounterArgs.self).name
          names.withLock { $0.append(name) }
          try store.setQuery("counter:get", with: query.args, to: query.value! + 10)
        }
        try store.setQueryLoading("other:query")
      })

    XCTAssertEqual(names.withLock { $0 }.sorted(), ["a", "b"])
    let values = fakeFfiClient.optimisticStore.values
    XCTAssertEqual(values[FakeOptimisticLocalStore.key("counter:get", ["name": "\"a\""])], "11")
    XCTAssertEqual(values[FakeOptimisticLocalStore.key("counter:get", ["name": "\"b\""])], "12")
    XCTAssertEqual(values[FakeOptimisticLocalStore.key("other:query", [:])], .some(nil))
  }

  /// Sets `serverValue` as the result of `name` in a fake store, applies `update` to it and returns
  /// the value the update set.
  private func applyOptimisticUpdate(
    to name: String, withServerValue serverValue: String,
    _ update: @escaping OptimisticUpdate
  ) async throws -> String {
    let fakeFfiClient = FakeMobileConvexClient()
    let key = FakeOptimisticLocalStore.key(name, [:])
    fakeFfiClient.optimisticStore.values[key] = serverValue
    let client = ConvexMobile.ConvexClient(ffiClient: fakeFfiClient)
    try await client.mutation("nullResult", optimisticUpdate: update)
    return try XCTUnwrap(fakeFfiClient.optimisticStore.values[key] ?? nil)
  }

  func testOptimisticTopLevelIntRoundTripsAsJsNumber() async throws {
    // The server sends a JavaScript number (a Float64) as a JSON number.
    let set = try await applyOptimisticUpdate(to: "counter:get", withServerValue: "5.0") { store in
      let count: Int = try store.getQuery("counter:get")!
      try store.setQuery("counter:get", to: count + 1)
    }

    XCTAssertEqual(set, "6")
    XCTAssertEqual(try JSONDecoder().decode(Int.self, from: Data(set.utf8)), 6)
  }

  func testOptimisticNestedIntRoundTripsAsJsNumber() async throws {
    let set = try await applyOptimisticUpdate(
      to: "counter:get", withServerValue: "{\"count\":5.0}"
    ) { store in
      let counter: Counter = try store.getQuery("counter:get")!
      try store.setQuery("counter:get", to: Counter(count: counter.count + 1))
    }

    XCTAssertEqual(set, "{\"count\":6}")
    XCTAssertEqual(try JSONDecoder().decode(Counter.self, from: Data(set.utf8)), Counter(count: 6))
  }

  func testOptimisticDoubleRoundTripsAsJsNumber() async throws {
    let set = try await applyOptimisticUpdate(to: "counter:get", withServerValue: "1.5") { store in
      let value: Double = try store.getQuery("counter:get")!
      try store.setQuery("counter:get", to: value + 1)
    }

    XCTAssertEqual(set, "2.5")
    XCTAssertEqual(try JSONDecoder().decode(Double.self, from: Data(set.utf8)), 2.5)
  }

  func testOptimisticConvexIntRoundTripsAsInt64() async throws {
    // The server sends an Int64 (a JavaScript bigint) as an `$integer` object.
    let set = try await applyOptimisticUpdate(
      to: "notes:get", withServerValue: "{\"body\":\"a\",\"likes\":{\"$integer\":\"BQAAAAAAAAA=\"}}"
    ) { store in
      let note: Note = try store.getQuery("notes:get")!
      try store.setQuery("notes:get", to: Note(body: note.body, likes: note.likes + 1))
    }

    let json = try JSONSerialization.jsonObject(with: Data(set.utf8)) as! [String: Any]
    XCTAssertEqual(json["likes"] as? [String: String], ["$integer": "BgAAAAAAAAA="])
    XCTAssertEqual(
      try JSONDecoder().decode(Note.self, from: Data(set.utf8)), Note(body: "a", likes: 6))
  }

  func testOptimisticTopLevelConvexIntRoundTripsAsInt64() async throws {
    let set = try await applyOptimisticUpdate(
      to: "counter:get", withServerValue: "{\"$integer\":\"BQAAAAAAAAA=\"}"
    ) { store in
      let count: ConvexInt<Int> = try store.getQuery("counter:get")!
      try store.setQuery("counter:get", to: ConvexInt(wrappedValue: count.wrappedValue + 1))
    }

    XCTAssertEqual(set, "{\"$integer\":\"BgAAAAAAAAA=\"}")
  }

  func testThrowingOptimisticUpdateFailsMutationWithItsError() async throws {
    struct BadUpdate: Error {}
    let fakeFfiClient = FakeMobileConvexClient()
    let client = ConvexMobile.ConvexClient(ffiClient: fakeFfiClient)

    do {
      try await client.mutation(
        "nullResult",
        optimisticUpdate: { store in
          try store.setQuery("counter:get", to: 1)
          throw BadUpdate()
        })
      XCTFail("mutation should have thrown")
    } catch is BadUpdate {}

    XCTAssertEqual(fakeFfiClient.mutationCalls, [])
    XCTAssertEqual(fakeFfiClient.optimisticUpdateApplyCount, 1)
  }

  func testOptimisticUpdateErrorsCrossTheFfiAsClientErrors() throws {
    struct BadUpdate: Error {}
    let adapter = OptimisticUpdateAdapter(update: { _ in throw BadUpdate() })

    XCTAssertThrowsError(try adapter.apply(store: FakeOptimisticLocalStore())) { error in
      guard case ClientError.InternalError = error else {
        return XCTFail("expected an InternalError, got \(error)")
      }
    }
  }

  func testConvexNumberWrappersEncodeToConvexJson() throws {
    let encoded = try JSONEncoder().encode(
      NumberWrappers(int: 42, optionalInt: nil, float: .infinity, optionalFloat: 1.5))
    let json = try JSONSerialization.jsonObject(with: encoded) as! [String: Any]

    XCTAssertEqual(json["int"] as? [String: String], ["$integer": "KgAAAAAAAAA="])
    XCTAssertNil(json["optionalInt"])
    XCTAssertEqual(json["float"] as? [String: String], ["$float": "AAAAAAAA8H8="])
    XCTAssertEqual(json["optionalFloat"] as? Double, 1.5)
    XCTAssertEqual(
      try JSONDecoder().decode(NumberWrappers.self, from: encoded),
      NumberWrappers(int: 42, optionalInt: nil, float: .infinity, optionalFloat: 1.5))
  }

  func testConvexIntEncodesUnsignedValuesAboveInt64MaxByBitPattern() throws {
    let encoded = try JSONEncoder().encode(ConvexInt<UInt64>(wrappedValue: UInt64.max))

    let json = try JSONSerialization.jsonObject(with: encoded) as! [String: String]

    // -1 as an Int64.
    XCTAssertEqual(json, ["$integer": "//////////8="])
    XCTAssertEqual(
      try JSONDecoder().decode(ConvexInt<UInt64>.self, from: encoded).wrappedValue, UInt64.max)
  }

  func testActionRoundTrip() async throws {
    let fakeFfiClient = FakeMobileConvexClient()
    let client = ConvexMobile.ConvexClient(ffiClient: fakeFfiClient)

    let message: Message = try await client.action("foo", with: ["anInt": Int.max])

    XCTAssertEqual(message.id, "the_id")
    XCTAssertEqual(message.val, Int.max)
  }

  func testVoidAction() async throws {
    let fakeFfiClient = FakeMobileConvexClient()
    let client = ConvexMobile.ConvexClient(ffiClient: fakeFfiClient)

    try await client.action("nullResult")

    XCTAssertEqual(fakeFfiClient.actionCalls, ["nullResult"])
  }

  func testMutationTypeMismatchThrows() async throws {
    let client = ConvexMobile.ConvexClient(ffiClient: FakeMobileConvexClient())

    do {
      let _: Message = try await client.mutation("typeMismatch")
      XCTFail("Expected a DecodingError to be thrown")
    } catch is DecodingError {
      // Expected: decoding "just a plain string" into Message fails gracefully
    } catch {
      XCTFail("Expected DecodingError but got \(type(of: error)): \(error)")
    }
  }

  func testSubscribeTypeMismatchSendsError() async throws {
    let expectation = self.expectation(description: "subscribe error")
    var receivedError: ClientError?
    let client = ConvexMobile.ConvexClient(ffiClient: FakeMobileConvexClient())

    let cancellationHandle = client.subscribe(to: "typeMismatch").sink(
      receiveCompletion: { completion in
        switch completion {
        case .finished:
          break
        case .failure(let clientError):
          receivedError = clientError
          expectation.fulfill()
        }
      },
      receiveValue: { (value: Message) in
        XCTFail("Should not receive a value for a type mismatch")
      })

    await fulfillment(of: [expectation], timeout: 10)

    if case .InternalError = receivedError! {
      // Expected: decoding error surfaced as InternalError
    } else {
      XCTFail("Expected InternalError but got \(receivedError!)")
    }
  }

  func testLoginSetsAuthCallbackOnFfiClient() async throws {
    let fakeFfiClient = FakeMobileConvexClient()
    let client = ConvexMobile.ConvexClientWithAuth(
      ffiClient: fakeFfiClient, authProvider: FakeAuthProvider())

    let result = await client.login()

    XCTAssertEqual(try result.get(), FakeAuthProvider.CREDENTIALS)
    // The callback provider should have been set
    XCTAssertNotNil(fakeFfiClient.authProvider)
    // Fetching the token from the provider should return the extracted token
    let token = try await fakeFfiClient.authProvider?.fetchToken(forceRefresh: false)
    XCTAssertEqual(token, "extracted: \(FakeAuthProvider.CREDENTIALS)")
  }

  func testLoginFromCacheSetsAuthCallbackOnFfiClient() async throws {
    let fakeFfiClient = FakeMobileConvexClient()
    let client = ConvexMobile.ConvexClientWithAuth(
      ffiClient: fakeFfiClient, authProvider: FakeAuthProvider())

    let result = await client.loginFromCache()

    XCTAssertEqual(try result.get(), FakeAuthProvider.CREDENTIALS)
    XCTAssertNotNil(fakeFfiClient.authProvider)
    let token = try await fakeFfiClient.authProvider?.fetchToken(forceRefresh: false)
    XCTAssertEqual(token, "extracted: \(FakeAuthProvider.CREDENTIALS)")
  }

  func testLogoutClearsAuthCallbackOnFfiClient() async throws {
    let fakeFfiClient = FakeMobileConvexClient()
    let client = ConvexMobile.ConvexClientWithAuth(
      ffiClient: fakeFfiClient, authProvider: FakeAuthProvider())

    // Login first to set up auth
    let _ = await client.login()
    XCTAssertNotNil(fakeFfiClient.authProvider)

    await client.logout()

    XCTAssertNil(fakeFfiClient.authProvider)
  }

  func testLoginUpdatesAuthState() async throws {
    let expectation = self.expectation(description: "authState")
    var credentials: String?
    let client = ConvexMobile.ConvexClientWithAuth(
      ffiClient: FakeMobileConvexClient(), authProvider: FakeAuthProvider())

    let cancellationHandle = client.authState.sink(
      receiveValue: { (value: AuthState<String>) in
        if case .authenticated(let creds) = value {
          credentials = creds
          expectation.fulfill()
        }
      })

    let result = await client.login()

    await fulfillment(of: [expectation], timeout: 10)

    XCTAssertEqual(try result.get(), FakeAuthProvider.CREDENTIALS)
    XCTAssertEqual(credentials, FakeAuthProvider.CREDENTIALS)
  }

  func testForceRefreshCallsLoginFromCacheForFreshToken() async throws {
    let fakeFfiClient = FakeMobileConvexClient()
    let fakeAuthProvider = FakeAuthProvider()
    let client = ConvexMobile.ConvexClientWithAuth(
      ffiClient: fakeFfiClient, authProvider: fakeAuthProvider)

    // Initial login sets the auth callback
    let result = await client.login()
    XCTAssertEqual(try result.get(), FakeAuthProvider.CREDENTIALS)

    // loginFromCache is not called during login() (only login is)
    let callCountAfterLogin = fakeAuthProvider.loginFromCacheCallCount

    // Fetch with forceRefresh: true should call through to loginFromCache
    let token = try await fakeFfiClient.authProvider?.fetchToken(forceRefresh: true)
    XCTAssertEqual(token, "extracted: \(FakeAuthProvider.CREDENTIALS)")
    XCTAssertEqual(fakeAuthProvider.loginFromCacheCallCount, callCountAfterLogin + 1)
  }

  func testTokenRefreshUpdatesAuthCallback() async throws {
    let expectation = self.expectation(description: "setAuthCallbackCalled")
    let fakeFfiClient = FakeMobileConvexClient()
    let fakeAuthProvider = FakeAuthProvider()
    let client = ConvexMobile.ConvexClientWithAuth(
      ffiClient: fakeFfiClient, authProvider: fakeAuthProvider)

    // Initial login sets the auth callback
    let result = await client.login()
    XCTAssertEqual(try result.get(), FakeAuthProvider.CREDENTIALS)
    let initialToken = try await fakeFfiClient.authProvider?.fetchToken(forceRefresh: false)
    XCTAssertEqual(initialToken, "extracted: \(FakeAuthProvider.CREDENTIALS)")

    // Set up expectation for the next setAuthCallback call
    fakeFfiClient.setAuthCallbackExpectation = expectation

    // Simulate a token refresh by invoking the stored callback with a new token
    let refreshedToken = "refreshed_token_value"
    fakeAuthProvider.simulateTokenRefresh(newToken: refreshedToken)

    await fulfillment(of: [expectation], timeout: 10)

    // The provider's cached token should now be the refreshed token
    let updatedToken = try await fakeFfiClient.authProvider?.fetchToken(forceRefresh: false)
    XCTAssertEqual(updatedToken, refreshedToken)
  }

  func testTokenRefreshWithNilSetsAuthStateToUnauthenticated() async throws {
    let expectation = self.expectation(description: "authStateUnauthenticated")
    let fakeFfiClient = FakeMobileConvexClient()
    let fakeAuthProvider = FakeAuthProvider()
    let client = ConvexMobile.ConvexClientWithAuth(
      ffiClient: fakeFfiClient, authProvider: fakeAuthProvider)

    var didBecomeUnauthenticated = false
    let cancellationHandle = client.authState.sink(
      receiveValue: { (value: AuthState<String>) in
        if case .unauthenticated = value {
          // Skip the initial unauthenticated state
          if didBecomeUnauthenticated {
            expectation.fulfill()
          }
        } else if case .authenticated = value {
          didBecomeUnauthenticated = true
        }
      })

    // Initial login sets the auth state to authenticated
    let result = await client.login()
    XCTAssertEqual(try result.get(), FakeAuthProvider.CREDENTIALS)

    // Simulate a token refresh with nil (session became invalid)
    fakeAuthProvider.simulateTokenRefresh(newToken: nil)

    await fulfillment(of: [expectation], timeout: 10)

    // Verify the auth callback provider was cleared and state is unauthenticated
    XCTAssertNil(fakeFfiClient.authProvider)
  }

  func testPendingAuthChangesArePublishedBeforeLoading() async throws {
    let fakeFfiClient = FakeMobileConvexClient()
    let fakeAuthProvider = FakeAuthProvider()
    let client = ConvexMobile.ConvexClientWithAuth(
      ffiClient: fakeFfiClient, authProvider: fakeAuthProvider)

    let statesLock = NSLock()
    var states: [String] = []
    let cancellable = client.authState.sink { state in
      statesLock.withLock { states.append("\(state)") }
    }

    _ = await client.login()
    // Invalidate the session and log in again right away. The invalidation is still queued when the
    // second login starts, so its `.unauthenticated` must be published before that login's `.loading`.
    fakeAuthProvider.simulateTokenRefresh(newToken: nil)
    _ = await client.login()
    cancellable.cancel()

    let authenticated = "authenticated(\"\(FakeAuthProvider.CREDENTIALS)\")"
    XCTAssertEqual(
      statesLock.withLock { states },
      ["unauthenticated", "loading", authenticated, "unauthenticated", "loading", authenticated])
  }

  func testTokenRefreshAfterLogoutDoesNotReinstallProvider() async throws {
    let fakeFfiClient = FakeMobileConvexClient()
    let fakeAuthProvider = FakeAuthProvider()
    let client = ConvexMobile.ConvexClientWithAuth(
      ffiClient: fakeFfiClient, authProvider: fakeAuthProvider)

    _ = await client.login()
    await client.logout()
    XCTAssertNil(fakeFfiClient.authProvider)
    let callsBeforePush = fakeFfiClient.authProviderHistory.count

    // A late token push from the provider (e.g. an in-flight refresh) must not log back in. Auth
    // changes are applied in call order, so the second logout only completes after the push has been
    // handled; the only call after the first logout should be the second logout's.
    fakeAuthProvider.simulateTokenRefresh(newToken: "late_token")
    await client.logout()
    let callsAfterPush = fakeFfiClient.authProviderHistory.dropFirst(callsBeforePush)
    XCTAssertEqual(callsAfterPush.count, 1)
    XCTAssertNil(callsAfterPush.first ?? nil)
  }

  /// Hammers login, cached login, token pushes and logout concurrently. Run with
  /// `swift test --sanitize=thread` to detect unsynchronized access to the auth state.
  func testConcurrentAuthChangesEndInConsistentState() async throws {
    let fakeFfiClient = FakeMobileConvexClient()
    let fakeAuthProvider = FakeAuthProvider()
    let client = ConvexMobile.ConvexClientWithAuth(
      ffiClient: fakeFfiClient, authProvider: fakeAuthProvider)

    // Auth state is published from the same serialized operation that registers or clears the
    // provider, so every published state must match what the Rust client has at that moment.
    let mismatchLock = NSLock()
    var mismatches: [String] = []
    let cancellable = client.authState.sink { state in
      let hasProvider = fakeFfiClient.authProvider != nil
      switch state {
      case .authenticated where !hasProvider:
        mismatchLock.withLock { mismatches.append("authenticated without a provider") }
      case .unauthenticated where hasProvider:
        mismatchLock.withLock { mismatches.append("unauthenticated with a provider") }
      default:
        break
      }
    }

    _ = await client.login()
    await withTaskGroup(of: Void.self) { group in
      for i in 0..<200 {
        group.addTask {
          switch i % 5 {
          case 0: _ = await client.loginFromCache()
          case 1: fakeAuthProvider.simulateTokenRefresh(newToken: "token-\(i)")
          case 2: fakeAuthProvider.simulateTokenRefresh(newToken: nil)
          case 3: _ = try? await fakeFfiClient.authProvider?.fetchToken(forceRefresh: true)
          default: await client.logout()
          }
        }
      }
    }

    // Every token push above was queued before its call returned, so this logout is applied after
    // all of them and must win.
    await client.logout()
    cancellable.cancel()
    XCTAssertNil(fakeFfiClient.authProvider)
    XCTAssertEqual(mismatchLock.withLock { mismatches }, [])
  }
}

class FakeMobileConvexClient: UniFFI.MobileConvexClientProtocol {
  var cancellationCount = 0
  var subscriptionArgs: [String: String] = [:]
  var mutationCalls: [String] = []
  var actionCalls: [String] = []
  var auth: String? = nil
  private let authProviderLock = NSLock()
  private var _authProvider: (any AuthTokenProvider)? = nil
  private var _authProviderHistory: [(any AuthTokenProvider)?] = []
  var authProvider: (any AuthTokenProvider)? {
    authProviderLock.withLock { _authProvider }
  }
  /// Every provider passed to `setAuthCallback`, in call order.
  var authProviderHistory: [(any AuthTokenProvider)?] {
    authProviderLock.withLock { _authProviderHistory }
  }
  var resultPublished: XCTestExpectation?
  var setAuthExpectation: XCTestExpectation?
  var setAuthCallbackExpectation: XCTestExpectation?

  init(initialAuth: String? = nil, resultPublished: XCTestExpectation? = nil) {
    self.auth = initialAuth
    self.resultPublished = resultPublished
  }

  func action(name: String, args: [String: String]) async throws -> String {
    actionCalls.append(name)
    if name == "nullResult" {
      return "null"
    }
    if name == "typeMismatch" {
      return "\"just a plain string\""
    }
    let receivedConvexInt = args["anInt"]!
    return "{\"_id\": \"the_id\", \"val\": \(receivedConvexInt), \"extra\": null}"
  }

  func mutation(name: String, args: [String: String]) async throws -> String {
    mutationCalls.append(name)
    if name == "nullResult" {
      return "null"
    }
    if name == "typeMismatch" {
      return "\"just a plain string\""
    }
    let receivedConvexInt = args["anInt"]!
    return "{\"_id\": \"the_id\", \"val\": \(receivedConvexInt), \"extra\": null}"
  }

  private let clearQueryCacheLock = NSLock()
  private var _clearQueryCacheCount = 0
  var clearQueryCacheCount: Int { clearQueryCacheLock.withLock { _clearQueryCacheCount } }

  func clearQueryCache() async throws {
    clearQueryCacheLock.withLock { _clearQueryCacheCount += 1 }
  }

  var flushQueryCacheCount = 0

  func flushQueryCache() async throws {
    flushQueryCacheCount += 1
  }

  let optimisticStore = FakeOptimisticLocalStore()
  var optimisticUpdateApplyCount = 0

  func mutationWithOptimisticUpdate(
    name: String, args: [String: String], optimisticUpdate: any MobileOptimisticUpdate
  ) async throws -> String {
    optimisticUpdateApplyCount += 1
    // Like the Rust client, don't send the mutation if the update fails when it's called.
    try optimisticUpdate.apply(store: optimisticStore)
    return try await mutation(name: name, args: args)
  }

  func query(name: String, args: [String: String]) async throws -> String {
    return "foo"
  }

  func setAuth(token: String?) async throws {
    auth = token
    setAuthExpectation?.fulfill()
  }

  func setAuthCallback(provider: (any AuthTokenProvider)?) async throws {
    authProviderLock.withLock {
      _authProvider = provider
      _authProviderHistory.append(provider)
    }
    setAuthCallbackExpectation?.fulfill()
  }

  func subscribe(name: String, args: [String: String], subscriber: any UniFFI.QuerySubscriber)
    async throws -> UniFFI.SubscriptionHandle
  {
    subscriptionArgs = args
    if name == "slowStart" {
      try await Task.sleep(nanoseconds: UInt64(0.1 * 1_000_000_000))
    }
    if name == "cachedThenFresh" {
      // A result restored from the cache (sent by the server at 2026-01-01T00:00:00Z), then the
      // server's, with the same value.
      subscriber.onUpdate(value: "{\"n\": 1}", cachedServerTs: 1_767_225_600_000_000_000)
      let _ = Task {
        try await Task.sleep(nanoseconds: UInt64(0.05 * 1_000_000_000))
        subscriber.onUpdate(value: "{\"n\": 1}", cachedServerTs: nil)
      }
      return FakeSubscriptionHandle(client: self)
    }
    if name == "immediate" {
      subscriber.onUpdate(
        value: "{\"_id\": \"the_id\", \"val\": {\"$integer\":\"KgAAAAAAAAA=\"}, \"extra\": null}", cachedServerTs: nil)
      return FakeSubscriptionHandle(client: self)
    }
    let _ = Task {
      try await Task.sleep(nanoseconds: UInt64(0.05 * 1_000_000_000))
      if name == "typeMismatch" {
        subscriber.onUpdate(
          value: "\"just a plain string\"", cachedServerTs: nil)
      } else if name == "missingVal" {
        subscriber.onUpdate(
          value: "{\"_id\": \"the_id\", \"extra\": null}", cachedServerTs: nil)
      } else if name == "nullVal" {
        subscriber.onUpdate(
          value: "{\"_id\": \"the_id\", \"val\": null, \"extra\": null}", cachedServerTs: nil)
      } else {
        subscriber.onUpdate(
          value: "{\"_id\": \"the_id\", \"val\": {\"$integer\":\"KgAAAAAAAAA=\"}, \"extra\": null}", cachedServerTs: nil)
        if name == "dupeVals" {
          subscriber.onUpdate(
            value:
              "{\"_id\": \"the_id\", \"val\": {\"$integer\":\"KgAAAAAAAAA=\"}, \"extra\": null}",
            cachedServerTs: nil)
        }
      }
      resultPublished?.fulfill()

    }
    return FakeSubscriptionHandle(client: self)
  }

}

class FakeAuthProvider: AuthProvider {
  static let CREDENTIALS = "credentials, yo"

  // Guards the state below, since the stress test calls into this provider concurrently.
  private let lock = NSLock()
  private var storedOnIdToken: (@Sendable (String?) -> Void)?
  private var _loginFromCacheCallCount = 0
  var loginFromCacheCallCount: Int { lock.withLock { _loginFromCacheCallCount } }

  func loginFromCache(onIdToken: @Sendable @escaping (String?) -> Void) async throws -> String {
    lock.withLock {
      _loginFromCacheCallCount += 1
      storedOnIdToken = onIdToken
    }
    onIdToken("extracted: \(FakeAuthProvider.CREDENTIALS)")
    return FakeAuthProvider.CREDENTIALS
  }

  func login(onIdToken: @Sendable @escaping (String?) -> Void) async throws -> String {
    lock.withLock { storedOnIdToken = onIdToken }
    onIdToken("extracted: \(FakeAuthProvider.CREDENTIALS)")
    return FakeAuthProvider.CREDENTIALS
  }

  func logout() async throws {

  }

  func extractIdToken(from authResult: String) -> String {
    return "extracted: \(authResult)"
  }

  /// Simulates a token refresh by invoking the stored callback with a new token.
  func simulateTokenRefresh(newToken: String?) {
    lock.withLock { storedOnIdToken }?(newToken)
  }
}

class FailingLogoutAuthProvider: FakeAuthProvider {
  struct LogoutFailed: Error {}

  override func logout() async throws {
    throw LogoutFailed()
  }
}

class FakeSubscriptionHandle: UniFFI.SubscriptionHandle {
  let client: FakeMobileConvexClient
  init(client: FakeMobileConvexClient) {
    self.client = client
    super.init(noPointer: UniFFI.SubscriptionHandle.NoPointer())
  }

  required init(unsafeFromRawPointer pointer: UnsafeMutableRawPointer) {
    fatalError("init(unsafeFromRawPointer:) has not been implemented")
  }

  override func cancel() {
    self.client.cancellationCount += 1
  }
}

/// An in-memory stand-in for the Rust optimistic update store, keyed by query name and JSON args.
class FakeOptimisticLocalStore: UniFFI.MobileOptimisticLocalStore {
  /// A `nil` value means the query was set to loading.
  var values: [String: String?] = [:]

  init() {
    super.init(noPointer: UniFFI.MobileOptimisticLocalStore.NoPointer())
  }

  required init(unsafeFromRawPointer pointer: UnsafeMutableRawPointer) {
    fatalError("init(unsafeFromRawPointer:) has not been implemented")
  }

  static func key(_ name: String, _ args: [String: String]) -> String {
    let sortedArgs = args.keys.sorted().map { "\($0)=\(args[$0]!)" }.joined(separator: ",")
    return "\(name)(\(sortedArgs))"
  }

  override func getQuery(name: String, args: [String: String]) throws -> String? {
    values[Self.key(name, args)] ?? nil
  }

  override func getAllQueries(name: String) throws -> [MobileOptimisticQuery] {
    values.compactMap { key, value in
      guard key.hasPrefix("\(name)(") else { return nil }
      let argsString = key.dropFirst(name.count + 1).dropLast()
      var args: [String: String] = [:]
      for pair in argsString.split(separator: ",") {
        let parts = pair.split(separator: "=", maxSplits: 1)
        args[String(parts[0])] = String(parts[1])
      }
      return MobileOptimisticQuery(args: args, value: value)
    }
  }

  override func setQuery(name: String, args: [String: String], value: String?) throws {
    values[Self.key(name, args)] = .some(value)
  }
}

private struct Note: Codable, Equatable {
  let body: String
  @ConvexInt
  var likes: Int
}

/// A value guarded by a lock, for state shared with `@Sendable` closures.
private final class Locked<Value>: @unchecked Sendable {
  private let lock = NSLock()
  private var value: Value

  init(_ value: Value) {
    self.value = value
  }

  func withLock<R>(_ body: (inout Value) throws -> R) rethrows -> R {
    try lock.withLock { try body(&value) }
  }
}

private struct Counter: Codable, Equatable {
  let count: Int
}

private struct CounterArgs: Decodable {
  let name: String
}

private struct NumberWrappers: Codable, Equatable {
  @ConvexInt
  var int: Int
  @OptionalConvexInt
  var optionalInt: Int?
  @ConvexFloat
  var float: Double
  @OptionalConvexFloat
  var optionalFloat: Double?
}

private struct MessageWithOptionalVal: Decodable {
  let id: String
  @OptionalConvexInt
  var val: Int? = nil

  enum CodingKeys: String, CodingKey {
    case id = "_id"
    case val
  }
}

private struct Message: Decodable, Equatable {
  let id: String
  @ConvexInt
  var val: Int

  enum CodingKeys: String, CodingKey {
    case id = "_id"
    case val
  }
}
