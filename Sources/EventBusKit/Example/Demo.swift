import Foundation

/// Strongly-typed user identifier used by auth-related events.
struct UserID: Hashable, Sendable, Codable {
    /// Raw user identifier string.
    let rawValue: String

    /// Creates a `UserID` from a raw string value.
    nonisolated init(_ rawValue: String) {
        self.rawValue = rawValue
    }
}

/// Event emitted when a user login succeeds.
struct UserDidLoginEvent: EventBusEvent, Equatable, Codable {
    /// Authentication source used for login.
    enum Source: String, Sendable, Codable, CaseIterable {
        case password
        case oauth
        case biometrics
    }

    /// Logged-in user identifier.
    let userID: UserID
    /// Event creation time.
    let occurredAt: Date
    /// Correlation identifier for tracing this flow.
    let correlationID: UUID
    /// Login source.
    let source: Source

    /// Creates a new login event.
    nonisolated init(
        userID: UserID,
        occurredAt: Date = Date(),
        correlationID: UUID = UUID(),
        source: Source
    ) {
        self.userID = userID
        self.occurredAt = occurredAt
        self.correlationID = correlationID
        self.source = source
    }
}

/// Example publisher that emits authentication events.
final class SessionService: Sendable {
    private let eventBus: EventBus

    /// Creates a new session service.
    nonisolated init(eventBus: EventBus = .default) {
        self.eventBus = eventBus
    }

    /// Emits `UserDidLoginEvent` for a successful login.
    nonisolated func login(userID: UserID, source: UserDidLoginEvent.Source) {
        eventBus.publish(UserDidLoginEvent(userID: userID, source: source))
    }
}

/// Example subscriber that tracks the most recent logged-in user.
actor AnalyticsSubscriber {
    private let eventBus: EventBus
    private var subscriptionToken: EventBus.SubscriptionToken?

    /// The last user ID observed in login events.
    private(set) var lastTrackedUserID: UserID?

    /// Creates a new analytics subscriber.
    init(eventBus: EventBus = .default) {
        self.eventBus = eventBus
    }

    /// Starts listening for login events.
    ///
    /// Calling this multiple times is safe; repeated calls are ignored after the first subscription.
    func start() {
        guard subscriptionToken == nil else {
            return
        }

        subscriptionToken = eventBus.subscribe(
            owner: self,
            to: UserDidLoginEvent.self,
            delivery: .immediate
        ) { owner, event in
            await owner.track(userID: event.userID)
        }
    }

    /// Stops listening for login events.
    func stop() {
        subscriptionToken?.cancel()
        subscriptionToken = nil
    }

    private func track(userID: UserID) {
        lastTrackedUserID = userID
    }
}
/// Example subscriber that consumes the event stream using `for await`.
actor StreamAnalyticsSubscriber {
    private let eventBus: EventBus
    private var streamTask: Task<Void, Never>?

    /// The last event observed from the stream consumer.
    private(set) var lastEvent: UserDidLoginEvent?

    /// Creates a new stream-based subscriber.
    init(eventBus: EventBus = .default) {
        self.eventBus = eventBus
    }

    /// Starts consuming `UserDidLoginEvent` values from `AsyncStream`.
    ///
    /// Calling this multiple times is safe; repeated calls are ignored while already running.
    func start() {
        guard streamTask == nil else {
            return
        }

        streamTask = Task { [eventBus] in
            let events = eventBus.stream(
                UserDidLoginEvent.self,
                delivery: .immediate,
                bufferingPolicy: .bufferingNewest(50)
            )

            for await event in events {
                self.track(event)
            }
        }
    }

    /// Stops consuming events from the stream.
    func stop() {
        streamTask?.cancel()
        streamTask = nil
    }

    private func track(_ event: UserDidLoginEvent) {
        lastEvent = event
    }
}
