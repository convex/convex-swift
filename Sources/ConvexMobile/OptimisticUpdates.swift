//
//  OptimisticUpdates.swift
//  ConvexMobile
//

import Foundation

/// A temporary, local update to query results within a ``ConvexClient``.
///
/// Pass one to ``ConvexClient/mutation(_:with:optimisticUpdate:)`` to update query results
/// immediately, before the mutation reaches the server. The update is rolled back when the mutation's
/// result is reflected in query results from the server, or when the mutation fails.
///
/// Keep in mind:
///
/// - **It runs synchronously on the client's background thread**, not on the caller's thread or the
///   main actor. Read and write query results only through the ``OptimisticLocalStore``.
/// - **It may run several times.** If the client receives new data from the server before the
///   mutation is reflected in it, the update is replayed on top of the new data. Derive the new
///   values from the store each time rather than from state captured when the update was created.
/// - **It must be fast and must not block.** Query results can't update while it runs. Don't wait on
///   locks, I/O or other work, and don't call back into the ``ConvexClient``.
/// - **It may be retained until the mutation completes**, which can be indefinitely while the device
///   is offline. Capture objects such as view models weakly.
///
/// If the update throws, its writes are undone. When the mutation is called, the error is thrown from
/// the `mutation` call and the mutation isn't sent; when the update is replayed later, the update is
/// dropped.
public typealias OptimisticUpdate = @Sendable (OptimisticLocalStore) throws -> Void

/// A view of the query results currently in the ``ConvexClient`` for use within an
/// ``OptimisticUpdate``.
///
/// Queries are identified by their name and arguments, in the same format used by
/// ``ConvexClient/subscribe(to:with:yielding:)``.
///
/// The store is only usable while the ``OptimisticUpdate`` it was passed to is running.
public final class OptimisticLocalStore {
  private let ffiStore: MobileOptimisticLocalStoreProtocol

  init(ffiStore: MobileOptimisticLocalStoreProtocol) {
    self.ffiStore = ffiStore
  }

  /// Retrieves the result of a query from the client.
  ///
  /// A query whose result is Convex `null` can only be decoded when `T` is an `Optional`, and then
  /// returns `.some(nil)`. Once flattened, for example with `?? nil`, that's indistinguishable from
  /// the `nil` returned for a query that's loading, so check the outer optional first if the
  /// difference matters. With a non-`Optional` `T`, a `null` result throws a `DecodingError`.
  ///
  /// - Parameters:
  ///   - name: A value in "module:query_name" format
  ///   - args: An optional ``Dictionary`` of arguments to the query
  ///   - output: The type to decode the result into, as a convenience to callers where the type
  ///             can't be easily inferred.
  /// - Returns: The query result, or `nil` if the query isn't currently in the client, is loading or
  ///            is in an error state.
  public func getQuery<T: Decodable>(
    _ name: String, with args: [String: ConvexEncodable?]? = nil, yielding output: T.Type? = nil
  ) throws -> T? {
    guard let value = try ffiStore.getQuery(name: name, args: try encodeArgs(args)) else {
      return nil
    }
    return try JSONDecoder().decode(T.self, from: Data(value.utf8))
  }

  /// Retrieves the arguments and results of all queries with the given `name`.
  ///
  /// This is useful for complex optimistic updates that need to inspect and update many query
  /// results (for example updating a paginated list).
  ///
  /// - Parameters:
  ///   - name: A value in "module:query_name" format
  ///   - output: The type to decode the results into, as a convenience to callers where the type
  ///             can't be easily inferred.
  public func getAllQueries<T: Decodable>(_ name: String, yielding output: T.Type? = nil) throws
    -> [OptimisticQuery<T>]
  {
    try ffiStore.getAllQueries(name: name).map { query in
      OptimisticQuery(
        args: query.args.mapValues { RawConvexValue(json: $0) },
        value: try query.value.map { try JSONDecoder().decode(T.self, from: Data($0.utf8)) })
    }
  }

  /// Optimistically updates the result of a query.
  ///
  /// The new value is often derived from the current value from ``getQuery(_:with:yielding:)``.
  /// Treat values from the store as immutable and build a new value to set.
  ///
  /// `value` is encoded with ``JSONEncoder``, mirroring how subscribers decode query results with
  /// ``JSONDecoder``, so a value read from the store, modified and set again decodes as the same
  /// type:
  ///
  /// - Numbers such as `Int` and `Double` become JSON numbers, which Convex stores as `Float64` (a
  ///   JavaScript `number`). This applies to top-level values and to values nested in structs and
  ///   arrays alike.
  /// - For a query that returns an `Int64` (a JavaScript `bigint`), use ``ConvexInt`` or
  ///   ``OptionalConvexInt``, just as you do to decode it.
  /// - For `NaN` and infinite values, use ``ConvexFloat`` or ``OptionalConvexFloat``.
  ///
  /// If a subscriber can't decode the new value as its result type, its subscription ends with an
  /// error, so set values of the same type the query returns.
  ///
  /// - Parameters:
  ///   - name: A value in "module:query_name" format
  ///   - args: An optional ``Dictionary`` of arguments to the query
  ///   - value: The new result for the query.
  public func setQuery<T: Encodable>(
    _ name: String, with args: [String: ConvexEncodable?]? = nil, to value: T
  ) throws {
    // Don't use `ConvexEncodable` here, even for values that conform to it: it encodes `Int` as an
    // `Int64`, which subscribers decoding `Int` can't read. Arguments still use it, so they match
    // the arguments of subscriptions.
    let encoded = String(decoding: try JSONEncoder().encode(value), as: UTF8.self)
    try ffiStore.setQuery(name: name, args: try encodeArgs(args), value: encoded)
  }

  /// Optimistically sets a query to be loading, removing its result from the client.
  ///
  /// This is useful to create loading states while Convex recomputes the query results. Subscribers
  /// don't receive a value for a loading query; they receive the next result from the server.
  ///
  /// - Parameters:
  ///   - name: A value in "module:query_name" format
  ///   - args: An optional ``Dictionary`` of arguments to the query
  public func setQueryLoading(_ name: String, with args: [String: ConvexEncodable?]? = nil) throws {
    try ffiStore.setQuery(name: name, args: try encodeArgs(args), value: nil)
  }

  private func encodeArgs(_ args: [String: ConvexEncodable?]?) throws -> [String: String] {
    try args?.mapValues({ v in try v?.convexEncode() ?? "null" }) ?? [:]
  }
}

/// A query in the ``OptimisticLocalStore``, as returned by
/// ``OptimisticLocalStore/getAllQueries(_:yielding:)``.
public struct OptimisticQuery<T> {
  /// The query's arguments, which can be passed back to
  /// ``OptimisticLocalStore/setQuery(_:with:to:)``.
  public let args: [String: ConvexEncodable?]
  /// The query result, or `nil` if the query is loading or is in an error state. As with
  /// ``OptimisticLocalStore/getQuery(_:with:yielding:)``, a Convex `null` result is `.some(nil)` when
  /// `T` is an `Optional`.
  public let value: T?

  /// Decodes the query's arguments into `type`.
  ///
  /// The arguments are in their Convex encoding, as sent to the server, so `type` must decode them
  /// as it would a query result: arguments passed as `Int`, `Int32` or `Int64` are Convex `Int64`s
  /// and need ``ConvexInt`` (or ``OptionalConvexInt``), while `Double` and `Float` arguments are
  /// plain numbers.
  public func decodeArgs<A: Decodable>(as type: A.Type) throws -> A {
    let json = try args.convexEncode()
    return try JSONDecoder().decode(A.self, from: Data(json.utf8))
  }
}

/// A Convex value that's already encoded as JSON.
private struct RawConvexValue: ConvexEncodable {
  let json: String

  func convexEncode() throws -> String {
    json
  }
}

/// Passes optimistic updates from the Rust client to the Swift ``OptimisticUpdate``.
class OptimisticUpdateAdapter: MobileOptimisticUpdate {
  private let update: OptimisticUpdate

  init(update: @escaping OptimisticUpdate) {
    self.update = update
  }

  private let lock = NSLock()
  private var hasRun = false
  private var _firstRunError: Error?

  /// The error the update threw when the mutation was called, if any, so the `mutation` call can
  /// rethrow it instead of the FFI's description of it.
  var firstRunError: Error? {
    lock.withLock { _firstRunError }
  }

  func apply(store: MobileOptimisticLocalStore) throws {
    do {
      try update(OptimisticLocalStore(ffiStore: store))
      lock.withLock { hasRun = true }
    } catch {
      lock.withLock {
        if !hasRun {
          _firstRunError = error
        }
        hasRun = true
      }
      if let error = error as? ClientError {
        throw error
      }
      // Only ClientErrors cross the FFI as errors; anything else would crash the client.
      throw ClientError.InternalError(msg: "Optimistic update failed: \(error)")
    }
  }
}
