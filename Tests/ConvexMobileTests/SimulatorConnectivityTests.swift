import Combine
import XCTest

import ConvexMobile

/// Guards against a class of regression where ConvexMobile query subscriptions
/// never resolve on the iOS Simulator — the app sits "refreshing over and over"
/// because the `wss://` connection never establishes and no query update is
/// delivered.
///
/// The rest of the suite (`IntegrationTests`) uses iOS 15 `AsyncPublisher.values`
/// and, historically, only ever ran on macOS. This test is written with
/// iOS 13-compatible Combine APIs and is meant to run on the **iOS Simulator**
/// destination so the transport is exercised there in CI, over a real cloud
/// (`wss://`) deployment.
final class SimulatorConnectivityTests: XCTestCase {
  private var cancellables = Set<AnyCancellable>()

  private struct Message: Decodable, Equatable {
    let author: String
    let body: String
  }

  private let deploymentUrl = "https://curious-lynx-309.convex.cloud"

  func testSubscriptionResolvesOverTLS() {
    let client = ConvexClient(deploymentUrl: deploymentUrl)

    let connected = expectation(description: "websocket reached .connected")
    let gotInitialValue = expectation(description: "received initial messages:list value")

    // Attach the websocket-state observer before triggering a connect (via
    // subscribe) so we don't miss the .connecting -> .connected transition.
    client.watchWebSocketState()
      .sink { state in
        NSLog("ConvexConnectivity websocket state: \(state)")
        if state == .connected { connected.fulfill() }
      }
      .store(in: &cancellables)

    let subscription: AnyPublisher<[Message]?, ClientError> =
      client.subscribe(to: "messages:list")
    subscription
      .sink(
        receiveCompletion: { completion in
          if case .failure(let error) = completion {
            XCTFail("subscription failed before delivering a value: \(error)")
            gotInitialValue.fulfill()
          }
        },
        receiveValue: { _ in
          gotInitialValue.fulfill()
        }
      )
      .store(in: &cancellables)

    wait(for: [connected, gotInitialValue], timeout: 30)
  }
}
