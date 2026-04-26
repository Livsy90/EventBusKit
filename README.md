# EventBusKit

A lightweight, type-safe event bus for Swift code.

`EventBus` is implemented as a thread-safe `final class` backed by `NSLock`. It supports weak owner lifecycle, token-based cancellation, one-shot subscriptions, ordered snapshot delivery, `AsyncStream` consumption, and a `MainActor`-friendly overload for UI owners.

## Requirements

- iOS 13+

## Installation

Add the package dependency in Swift Package Manager and depend on the `EventBus` product.

## Quick Start

```swift
import EventBus

struct UserDidLoginEvent: EventBusEvent {
    let userID: String
}

let bus = EventBus.default

final class AnalyticsOwner: @unchecked Sendable {}
let owner = AnalyticsOwner()

let token = bus.subscribe(owner: owner, to: UserDidLoginEvent.self) { _, event in
    print("Logged in:", event.userID)
}

bus.publish(UserDidLoginEvent(userID: "u-1"))
token.cancel()
```

## Core Concepts

### Event Type

Any event must conform to `EventBusEvent` (`Sendable`).

```swift
struct AppReadyEvent: EventBusEvent {
    let timestamp: Date
}
```

### Subscriptions

- Every `subscribe(...)` call creates a new independent subscription.
- One owner may have multiple subscriptions for the same event type.
- `SubscriptionToken.cancel()` cancels one specific subscription.
- `unsubscribe(owner:from:)` removes all subscriptions for one owner and event type.
- `unsubscribeAll(for:)` removes all subscriptions for one owner across all event types.

### AsyncStream

Consume events with `for await`:

```swift
let stream = bus.stream(AppReadyEvent.self)

Task {
    for await event in stream {
        print(event.timestamp)
    }
}
```

## API Overview

- `publish(_:)`
- `subscribe(...)` with `(Owner, Event)` handler
- `subscribe(...)` with `Event`-only handler
- `subscribeOnce(...)`
- `subscribeOnMain(...)`
- `unsubscribe(owner:from:)`
- `unsubscribeAll(for:)`
- `stream(_:bufferingPolicy:)`

## Thread Safety

- `EventBus` is thread-safe.
- Internal state is protected by `NSLock`.
- Dead subscriptions are cleaned lazily on subscribe and publish.
- `publish(_:)` uses snapshot delivery.
- Subscribers added during publish do not receive the current event.
- Subscribers removed during publish may already be in the snapshot, but `CancellationState` prevents cancelled handlers from running.
- Delivery order is registration order.

## Examples

See:

- `Sources/EventBus/Example/Demo.swift`
- `Sources/EventBus/Example/SwiftUIPlayground.swift`

## Tests

Unit tests are located in:

- `Tests/EventBusTests/EventBusTests.swift`

They cover delivery order, token-based cancellation, owner-based unsubscription, one-shot semantics, `MainActor` delivery, `AsyncStream`, and concurrent publishing.
