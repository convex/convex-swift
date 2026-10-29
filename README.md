# Convex for Swift

The official Swift client for [Convex](https://www.convex.dev/).

Convex is the backend application platform with everything you need to build your product.

This library lets you create Convex applications that run on iOS and macOS. It builds on the 
Convex Rust client and offers a convenient Swift API for executing queries, actions and mutations.

## Getting Started

If you haven't started a Convex application yet, head over to the
[Convex iOS quickstart](https://docs.convex.dev/quickstart/swift) to get the
basics down. It will get you up and running with a Convex dev deployment and a basic iOS application
that communicates with it using this library.

Also [join us on Discord](https://www.convex.dev/community) to get your questions answered or share
what you're doing with Convex.

## Installation

In Xcode,
[add a package dependency](https://developer.apple.com/documentation/xcode/adding-package-dependencies-to-your-app)
pointing to this Github repo. See the quickstart linked above for step-by-step instructions.

## Basic Usage

The code below shows a few basic patterns for working with the library. See the
[full documentation](https://docs.convex.dev/client/swift) for more details.

```swift
import ConvexMobile

struct YourData: Decodable {
  let foo: String
  @ConvexInt
  var bar: Int
}

let client = ConvexClient(deploymentUrl: "your convex deployment URL")

let yourData = client.subscribe(to: "your:data", yielding: YourData?.self)
    .replaceError(with: nil)
    .values

for await latestValue in yourData {
  // Do something with the latest `YourData?` value here.
  // The loop body will execute each time the "your:data" query result changes.
}

try await client.mutation("your:mutation", with: ["anotherArg": "anotherVal", "anInt": 42])
```
 
## Building

### The complete way

This library depends on Rust code built in the
[`convex-mobile`](https://github.com/convex/convex-mobile) project. If you are working
on changes there or want to incorporate recent changes from that code into this library, you
should clone `convex-mobile` and work with this library as a submodule.

In your `convex-mobile` clone:

1. `git submodule init`
2. `git submodule update`

Once you've done that, starting from your `convex-mobile` clone:

1. `cd rust/`
2. `./build-ios.sh`
3. Open Xcode
4. Open `convex-mobile/ios`

That will build the full Rust library and build and bundle new XCFrameworks for target platforms in the `ios/`
submodule (which points to this repository).

### The quick way

If you just want to work on the Swift side of things, you can just open a checked out version of this repo in Xcode.
It should build and run standalone with previously bundled XCFrameworks.
