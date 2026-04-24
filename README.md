# EventBus

A lightweight, type-safe event bus for Swift Concurrency.

`EventBus` is implemented as an `actor`, supports automatic cleanup of dead owners, multiple delivery modes, one-shot subscriptions, and `AsyncStream` consumption.

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

let bus = EventBus.shared

final class AnalyticsOwner: @unchecked Sendable {}
let owner = AnalyticsOwner()

let token = await bus.subscribe(owner: owner, to: UserDidLoginEvent.self) { _, event in
    print("Logged in:", event.userID)
}

await bus.publish(UserDidLoginEvent(userID: "u-1"))

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

### Delivery Modes

- `.postingTask`: executes handler inline in posting task context.
- `.mainThread`: dispatches handler asynchronously on `MainActor`.

### Subscriptions

- `subscribe(...)`: regular subscription.
- `subscribeOnce(...)`: auto-cancels after first matching event.
- `SubscriptionToken.cancel()`: early manual cancellation.
- `unsubscribeAll(for:)`: remove all subscriptions for an owner.

### AsyncStream

Consume events with `for await`:

```swift
let stream = await bus.stream(AppReadyEvent.self)

Task {
    for await event in stream {
        print(event.timestamp)
    }
}
```

## API Overview

- `publish(_:)`
- `publishDetached(_:priority:)`
- `subscribe(...)` (sync and async handlers)
- `subscribeOnce(...)` (sync and async handlers)
- `stream(_:delivery:bufferingPolicy:)`
- `unsubscribeAll(for:)`

## Concurrency Notes

- Internal state is actor-isolated.
- Delivery ordering across different tasks is best-effort.
- Cancellation is idempotent.

## Examples

See:

- `Sources/EventBus/Example/Demo.swift`
- `Sources/EventBus/Example/SwiftUIPlayground.swift`

## Tests

Unit tests are located in:

- `Tests/EventBusTests/EventBusTests.swift`

They cover baseline delivery, cancellation, one-shot subscriptions, stream behavior, main-thread delivery, and concurrent publishing.
