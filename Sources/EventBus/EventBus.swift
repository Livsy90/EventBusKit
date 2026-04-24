import Foundation

/// A type-safe event bus with automatic subscriber cleanup.
///
/// Behavioral contract:
/// - Access to internal state is serialized by actor isolation.
/// - Dead subscriptions are cleaned lazily on subscribe/publish operations.
/// - `publish(_:)` dispatches to subscribers in the current registration snapshot.
/// - Delivery across different tasks is best-effort and not globally ordered.
public actor EventBus {
    
    private var subscriptionsByEvent: [ObjectIdentifier: [UUID: Subscription]] = [:]
    
    /// Shared event bus instance.
    public static let `default` = EventBus()

    /// Creates a new event bus instance.
    public init() {}

    /// Publishes an event to all active subscribers of that event type.
    ///
    /// Dead subscribers (whose owner was deallocated) are removed before delivery.
    public func publish<Event: EventBusEvent>(_ event: Event) {
        let eventKey = ObjectIdentifier(Event.self)
        guard var bucket = subscriptionsByEvent[eventKey] else {
            return
        }

        bucket = bucket.filter { $0.value.owner != nil }
        subscriptionsByEvent[eventKey] = bucket.isEmpty ? nil : bucket

        let receivers = bucket.values.map(\.receive)
        receivers.forEach { $0(event) }
    }

    /// Publishes an event from a detached task.
    ///
    /// - Returns: The created task so callers can cancel or await completion.
    @discardableResult
    public nonisolated func publishDetached<Event: EventBusEvent>(
        _ event: Event,
        priority: TaskPriority? = nil
    ) -> Task<Void, Never> {
        Task.detached(priority: priority) { [self] in
            await self.publish(event)
        }
    }

    /// Subscribes `owner` to events of inferred type `Event`.
    ///
    /// The subscription is removed automatically when `owner` is deallocated.
    @discardableResult
    public func subscribe<Owner: AnyObject & Sendable, Event: EventBusEvent>(
        owner: Owner,
        delivery: Delivery = .postingTask,
        handler: @escaping @Sendable (Owner, Event) -> Void
    ) -> SubscriptionToken {
        subscribe(owner: owner, to: Event.self, delivery: delivery, handler: handler)
    }

    /// Subscribes `owner` with an async handler to events of inferred type `Event`.
    ///
    /// - Parameter taskPriority: Optional priority used for spawned handler tasks.
    @discardableResult
    public func subscribe<Owner: AnyObject & Sendable, Event: EventBusEvent>(
        owner: Owner,
        delivery: Delivery = .postingTask,
        taskPriority: TaskPriority? = nil,
        handler: @escaping @Sendable (Owner, Event) async -> Void
    ) -> SubscriptionToken {
        subscribe(owner: owner, to: Event.self, delivery: delivery, taskPriority: taskPriority, handler: handler)
    }

    /// Subscribes `owner` to a specific event type using an event-only handler.
    @discardableResult
    public func subscribe<Owner: AnyObject & Sendable, Event: EventBusEvent>(
        owner: Owner,
        to eventType: Event.Type = Event.self,
        delivery: Delivery = .postingTask,
        handler: @escaping @Sendable (Event) -> Void
    ) -> SubscriptionToken {
        subscribe(owner: owner, to: eventType, delivery: delivery) { _, event in
            handler(event)
        }
    }

    /// Subscribes `owner` to a specific event type using an async event-only handler.
    @discardableResult
    public func subscribe<Owner: AnyObject & Sendable, Event: EventBusEvent>(
        owner: Owner,
        to eventType: Event.Type = Event.self,
        delivery: Delivery = .postingTask,
        handler: @escaping @Sendable (Event) async -> Void
    ) -> SubscriptionToken {
        subscribe(owner: owner, to: eventType, delivery: delivery) { _, event in
            Task {
                await handler(event)
            }
        }
    }

    /// Subscribes `owner` to a specific event type using an async `(owner, event)` handler.
    ///
    /// - Parameter taskPriority: Optional priority used for spawned handler tasks.
    @discardableResult
    public func subscribe<Owner: AnyObject & Sendable, Event: EventBusEvent>(
        owner: Owner,
        to eventType: Event.Type = Event.self,
        delivery: Delivery = .postingTask,
        taskPriority: TaskPriority? = nil,
        handler: @escaping @Sendable (Owner, Event) async -> Void
    ) -> SubscriptionToken {
        subscribe(owner: owner, to: eventType, delivery: delivery) { owner, event in
            Task(priority: taskPriority) {
                await handler(owner, event)
            }
        }
    }

    /// Subscribes `owner` to a specific event type.
    ///
    /// - Important: The returned token can be used for early cancellation.
    @discardableResult
    public func subscribe<Owner: AnyObject & Sendable, Event: EventBusEvent>(
        owner: Owner,
        to eventType: Event.Type = Event.self,
        delivery: Delivery = .postingTask,
        handler: @escaping @Sendable (Owner, Event) -> Void
    ) -> SubscriptionToken {
        let eventKey = ObjectIdentifier(eventType)
        let id = UUID()
        let cancellationState = CancellationState()
        let subscription = Subscription(
            owner: owner,
            delivery: delivery,
            cancellationState: cancellationState,
            handler: handler
        )

        var bucket = subscriptionsByEvent[eventKey] ?? [:]
        bucket = bucket.filter { $0.value.owner != nil }
        bucket[id] = subscription
        subscriptionsByEvent[eventKey] = bucket

        return SubscriptionToken(cancellationState: cancellationState) { [weak self] in
            Task {
                await self?.unsubscribe(eventKey: eventKey, id: id)
            }
        }
    }

    /// Subscribes once and automatically cancels after the first matching event.
    @discardableResult
    public func subscribeOnce<Owner: AnyObject & Sendable, Event: EventBusEvent>(
        owner: Owner,
        to eventType: Event.Type = Event.self,
        delivery: Delivery = .postingTask,
        handler: @escaping @Sendable (Owner, Event) -> Void
    ) -> SubscriptionToken {
        let tokenBox = TokenBox()
        let token = subscribe(owner: owner, to: eventType, delivery: delivery) { owner, event in
            tokenBox.cancelAndClear()
            handler(owner, event)
        }
        tokenBox.set(token)
        return token
    }

    /// Subscribes once with an event-only handler.
    @discardableResult
    public func subscribeOnce<Owner: AnyObject & Sendable, Event: EventBusEvent>(
        owner: Owner,
        to eventType: Event.Type = Event.self,
        delivery: Delivery = .postingTask,
        handler: @escaping @Sendable (Event) -> Void
    ) -> SubscriptionToken {
        subscribeOnce(owner: owner, to: eventType, delivery: delivery) { _, event in
            handler(event)
        }
    }

    /// Subscribes once with an async event-only handler.
    ///
    /// - Parameter taskPriority: Optional priority used for spawned handler tasks.
    @discardableResult
    public func subscribeOnce<Owner: AnyObject & Sendable, Event: EventBusEvent>(
        owner: Owner,
        to eventType: Event.Type = Event.self,
        delivery: Delivery = .postingTask,
        taskPriority: TaskPriority? = nil,
        handler: @escaping @Sendable (Event) async -> Void
    ) -> SubscriptionToken {
        subscribeOnce(owner: owner, to: eventType, delivery: delivery) { _, event in
            Task(priority: taskPriority) {
                await handler(event)
            }
        }
    }

    /// Subscribes once with an async `(owner, event)` handler.
    ///
    /// - Parameter taskPriority: Optional priority used for spawned handler tasks.
    @discardableResult
    public func subscribeOnce<Owner: AnyObject & Sendable, Event: EventBusEvent>(
        owner: Owner,
        to eventType: Event.Type = Event.self,
        delivery: Delivery = .postingTask,
        taskPriority: TaskPriority? = nil,
        handler: @escaping @Sendable (Owner, Event) async -> Void
    ) -> SubscriptionToken {
        subscribeOnce(owner: owner, to: eventType, delivery: delivery) { owner, event in
            Task(priority: taskPriority) {
                await handler(owner, event)
            }
        }
    }

    /// Creates an `AsyncStream` for a specific event type.
    ///
    /// The stream keeps an internal owner alive and cancels its subscription on termination.
    public func stream<Event: EventBusEvent>(
        _ eventType: Event.Type = Event.self,
        delivery: Delivery = .postingTask,
        bufferingPolicy: AsyncStream<Event>.Continuation.BufferingPolicy = .bufferingNewest(100)
    ) -> AsyncStream<Event> {
        let owner = StreamOwner()
        let tokenBox = TokenBox()
        tokenBox.retain(owner: owner)

        var continuationRef: AsyncStream<Event>.Continuation?
        let stream = AsyncStream<Event>(bufferingPolicy: bufferingPolicy) { continuation in
            continuationRef = continuation
            continuation.onTermination = { @Sendable _ in
                tokenBox.cancelAndClear()
            }
        }

        guard let continuationRef else {
            assertionFailure("AsyncStream must provide continuation synchronously")
            return AsyncStream(bufferingPolicy: bufferingPolicy) { continuation in
                continuation.finish()
            }
        }

        let token = subscribe(owner: owner, to: eventType, delivery: delivery) { _, event in
            continuationRef.yield(event)
        }
        tokenBox.set(token)

        return stream
    }

    /// Unsubscribes `owner` from all event types.
    public func unsubscribeAll(for owner: AnyObject & Sendable) {
        let ownerID = ObjectIdentifier(owner)

        for (eventKey, bucket) in subscriptionsByEvent {
            let filtered = bucket.filter { _, subscription in
                guard let existingOwner = subscription.owner else {
                    return false
                }
                return ObjectIdentifier(existingOwner) != ownerID
            }
            subscriptionsByEvent[eventKey] = filtered.isEmpty ? nil : filtered
        }
    }

    private func unsubscribe(eventKey: ObjectIdentifier, id: UUID) {
        guard var bucket = subscriptionsByEvent[eventKey] else {
            return
        }

        bucket[id] = nil
        subscriptionsByEvent[eventKey] = bucket.isEmpty ? nil : bucket
    }
}

extension EventBus {
    /// Where a subscriber handler is executed.
    public enum Delivery: Sendable {
        /// Execute the handler inline on the current task context.
        case postingTask
        /// Dispatch the handler asynchronously on the main actor.
        case mainThread
    }

    /// A cancellable handle returned by subscription APIs.
    /// Cancellation is idempotent and thread-safe.
    // Safe: mutable state is protected by NSLock.
    fileprivate final class CancellationState: @unchecked Sendable {
        private let lock = NSLock()
        private var isCancelled = false

        func cancel() {
            lock.lock()
            isCancelled = true
            lock.unlock()
        }

        func cancelled() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            return isCancelled
        }
    }

    // Safe: all mutable state is protected by NSLock, cancellation closure is Sendable.
    public final class SubscriptionToken: @unchecked Sendable {
        private let cancelClosure: @Sendable () -> Void
        private let cancellationState: CancellationState
        private let lock = NSLock()
        private var isCancelled = false

        fileprivate init(
            cancellationState: CancellationState,
            cancelClosure: @escaping @Sendable () -> Void
        ) {
            self.cancellationState = cancellationState
            self.cancelClosure = cancelClosure
        }

        deinit {
            cancel()
        }

        /// Cancels the subscription associated with this token.
        public func cancel() {
            lock.lock()
            defer { lock.unlock() }
            guard !isCancelled else {
                return
            }
            isCancelled = true
            cancellationState.cancel()
            cancelClosure()
        }
    }

    private final class Subscription {
        weak var owner: AnyObject?
        let receive: @Sendable (Any) -> Void

        init<Owner: AnyObject & Sendable, Event: EventBusEvent>(
            owner: Owner,
            delivery: Delivery,
            cancellationState: CancellationState,
            handler: @escaping @Sendable (Owner, Event) -> Void
        ) {
            self.owner = owner
            self.receive = { [weak owner] rawEvent in
                guard !cancellationState.cancelled(),
                      let owner,
                      let event = rawEvent as? Event else {
                    return
                }

                switch delivery {
                case .postingTask:
                    handler(owner, event)
                case .mainThread:
                    Task { @MainActor [weak owner] in
                        guard !cancellationState.cancelled(),
                              let owner else {
                            return
                        }
                        handler(owner, event)
                    }
                }
            }
        }
    }

    // Safe: token/owner references are only accessed under NSLock.
    private final class TokenBox: @unchecked Sendable {
        private let lock = NSLock()
        private var token: SubscriptionToken?
        private var owner: AnyObject?
        private var isTerminated = false

        func set(_ token: SubscriptionToken) {
            lock.lock()
            if isTerminated {
                lock.unlock()
                token.cancel()
                return
            }
            self.token = token
            lock.unlock()
        }

        func retain(owner: AnyObject) {
            lock.lock()
            defer { lock.unlock() }
            self.owner = owner
        }

        func cancelAndClear() {
            lock.lock()
            isTerminated = true
            let token = self.token
            self.token = nil
            self.owner = nil
            lock.unlock()
            token?.cancel()
        }

        deinit {
            cancelAndClear()
        }
    }

    private actor StreamOwner {}
}
