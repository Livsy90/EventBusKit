import Foundation

/// A thread-safe, type-safe event bus for Swift and iOS code.
///
/// Behavioral contract:
/// - Internal state is protected by `NSLock`.
/// - Dead subscriptions are cleaned lazily on subscribe and publish.
/// - Each `subscribe` call creates an independent subscription.
/// - `SubscriptionToken.cancel()` cancels one specific subscription.
/// - `unsubscribe(owner:from:)` removes all subscriptions for `owner` and one event type.
/// - `unsubscribeAll(for:)` removes all subscriptions for `owner`.
/// - `publish(_:)` uses snapshot delivery in registration order.
/// - Subscribers added during `publish(_:)` do not receive the current event.
/// - Subscribers removed during `publish(_:)` may already be in the snapshot, but
///   `CancellationState` prevents cancelled handlers from running.
/// - `.immediate` invokes handlers synchronously after the lock is released.
/// - `.mainActor` schedules delivery asynchronously on `MainActor`.
/// - Async handlers are fire-and-forget; `publish(_:)` does not await them.
public final class EventBus: @unchecked Sendable {
    private let lock = NSLock()
    private var subscriptionsByEvent: [ObjectIdentifier: [SubscriptionEntry]] = [:]

    /// Shared event bus instance.
    public static let `default` = EventBus()

    /// Creates a new event bus instance.
    public init() {}

    /// Publishes an event to all active subscribers of that event type.
    ///
    /// Dead subscriptions are removed before snapshot delivery.
    public func publish<Event: EventBusEvent>(_ event: Event) {
        let eventKey = ObjectIdentifier(Event.self)
        let receivers: [@Sendable (Any) -> Void] = lock.withLock {
            guard var bucket = subscriptionsByEvent[eventKey] else {
                return []
            }

            bucket = cleanDeadSubscriptions(in: bucket)
            subscriptionsByEvent[eventKey] = bucket.isEmpty ? nil : bucket
            return bucket.map(\.subscription.receive)
        }

        receivers.forEach { $0(event) }
    }

    /// Publishes an event from a new unstructured task.
    ///
    /// - Returns: The created task so callers can cancel or await completion.
    @discardableResult
    public func publishAsync<Event: EventBusEvent>(
        _ event: Event,
        priority: TaskPriority? = nil
    ) -> Task<Void, Never> {
        Task(priority: priority) { [self] in
            publish(event)
        }
    }

    /// Subscribes `owner` to events of inferred type `Event`.
    ///
    /// Each call creates a new independent subscription. Keep the returned token if
    /// you need to cancel one specific subscription later. Keeping the returned token
    /// is optional; the subscription is also removed automatically when `owner` is
    /// deallocated.
    @discardableResult
    public func subscribe<Owner: AnyObject & Sendable, Event: EventBusEvent>(
        owner: Owner,
        delivery: Delivery = .immediate,
        handler: @escaping @Sendable (Owner, Event) -> Void
    ) -> SubscriptionToken {
        subscribe(owner: owner, to: Event.self, delivery: delivery, handler: handler)
    }

    /// Subscribes `owner` with an async handler to events of inferred type `Event`.
    ///
    /// Async handlers are delivered via fire-and-forget `Task`.
    /// For UI-bound handlers that must be `MainActor`-isolated, prefer `subscribeOnMain`.
    @discardableResult
    public func subscribe<Owner: AnyObject & Sendable, Event: EventBusEvent>(
        owner: Owner,
        delivery: Delivery = .immediate,
        taskPriority: TaskPriority? = nil,
        handler: @escaping @Sendable (Owner, Event) async -> Void
    ) -> SubscriptionToken {
        subscribe(
            owner: owner,
            to: Event.self,
            delivery: delivery,
            taskPriority: taskPriority,
            handler: handler
        )
    }

    /// Subscribes `owner` to a specific event type using an event-only handler.
    @discardableResult
    public func subscribe<Owner: AnyObject & Sendable, Event: EventBusEvent>(
        owner: Owner,
        to eventType: Event.Type = Event.self,
        delivery: Delivery = .immediate,
        handler: @escaping @Sendable (Event) -> Void
    ) -> SubscriptionToken {
        subscribe(owner: owner, to: eventType, delivery: delivery) { _, event in
            handler(event)
        }
    }

    /// Subscribes `owner` to a specific event type using an async event-only handler.
    ///
    /// Async handlers are delivered via fire-and-forget `Task`.
    /// For UI-bound handlers that must be `MainActor`-isolated, prefer `subscribeOnMain`.
    @discardableResult
    public func subscribe<Owner: AnyObject & Sendable, Event: EventBusEvent>(
        owner: Owner,
        to eventType: Event.Type = Event.self,
        delivery: Delivery = .immediate,
        taskPriority: TaskPriority? = nil,
        handler: @escaping @Sendable (Event) async -> Void
    ) -> SubscriptionToken {
        subscribe(
            owner: owner,
            to: eventType,
            delivery: delivery,
            taskPriority: taskPriority
        ) { _, event in
            await handler(event)
        }
    }

    /// Subscribes `owner` to a specific event type using an async `(owner, event)` handler.
    ///
    /// Async handlers are delivered via fire-and-forget `Task`. Cancelling the token prevents
    /// new deliveries, but does not necessarily cancel a task that has already started.
    /// For UI-bound handlers that must be `MainActor`-isolated, prefer `subscribeOnMain`.
    @discardableResult
    public func subscribe<Owner: AnyObject & Sendable, Event: EventBusEvent>(
        owner: Owner,
        to eventType: Event.Type = Event.self,
        delivery: Delivery = .immediate,
        taskPriority: TaskPriority? = nil,
        handler: @escaping @Sendable (Owner, Event) async -> Void
    ) -> SubscriptionToken {
        subscribe(owner: owner, to: eventType, delivery: delivery) { owner, event in
            switch delivery {
            case .immediate:
                Task(priority: taskPriority) {
                    await handler(owner, event)
                }
            case .mainActor:
                Task(priority: taskPriority) { @MainActor in
                    await handler(owner, event)
                }
            }
        }
    }

    /// Subscribes `owner` to a specific event type.
    ///
    /// Each call creates a new independent subscription. One owner may have multiple
    /// subscriptions to the same event type. Keeping the returned token is optional;
    /// the subscription is also removed automatically when `owner` is deallocated.
    @discardableResult
    public func subscribe<Owner: AnyObject & Sendable, Event: EventBusEvent>(
        owner: Owner,
        to eventType: Event.Type = Event.self,
        delivery: Delivery = .immediate,
        handler: @escaping @Sendable (Owner, Event) -> Void
    ) -> SubscriptionToken {
        subscribeInternal(owner: owner, to: eventType, delivery: delivery, handler: handler)
    }

    /// Subscribes a `MainActor` owner without requiring `Sendable`.
    ///
    /// This overload is convenient for UI types such as view controllers or view models.
    @MainActor
    @discardableResult
    public func subscribeOnMain<Owner: AnyObject, Event: EventBusEvent>(
        owner: Owner,
        to eventType: Event.Type = Event.self,
        handler: @escaping @MainActor (Owner, Event) -> Void
    ) -> SubscriptionToken {
        subscribeMainActorInternal(owner: owner, to: eventType, handler: handler)
    }

    /// Subscribes once and automatically cancels after the first matching event.
    ///
    /// Even if multiple publishes race with the same subscription snapshot, `OnceGate`
    /// ensures the handler runs at most once. Keeping the returned token is optional;
    /// use it only if you need to cancel the one-shot subscription before the first
    /// matching event arrives.
    @discardableResult
    public func subscribeOnce<Owner: AnyObject & Sendable, Event: EventBusEvent>(
        owner: Owner,
        to eventType: Event.Type = Event.self,
        delivery: Delivery = .immediate,
        handler: @escaping @Sendable (Owner, Event) -> Void
    ) -> SubscriptionToken {
        let tokenBox = TokenBox()
        let onceGate = OnceGate()
        let token = subscribeInternal(owner: owner, to: eventType, delivery: delivery) { owner, event in
            guard onceGate.consumeFirstDelivery() else {
                return
            }
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
        delivery: Delivery = .immediate,
        handler: @escaping @Sendable (Event) -> Void
    ) -> SubscriptionToken {
        subscribeOnce(owner: owner, to: eventType, delivery: delivery) { _, event in
            handler(event)
        }
    }

    /// Subscribes once with an async event-only handler.
    ///
    /// Async handlers are delivered via fire-and-forget `Task`.
    /// For UI-bound handlers that must be `MainActor`-isolated, prefer `subscribeOnMain`.
    @discardableResult
    public func subscribeOnce<Owner: AnyObject & Sendable, Event: EventBusEvent>(
        owner: Owner,
        to eventType: Event.Type = Event.self,
        delivery: Delivery = .immediate,
        taskPriority: TaskPriority? = nil,
        handler: @escaping @Sendable (Event) async -> Void
    ) -> SubscriptionToken {
        subscribeOnce(
            owner: owner,
            to: eventType,
            delivery: delivery,
            taskPriority: taskPriority
        ) { _, event in
            await handler(event)
        }
    }

    /// Subscribes once with an async `(owner, event)` handler.
    ///
    /// Async handlers are delivered via fire-and-forget `Task`.
    /// For UI-bound handlers that must be `MainActor`-isolated, prefer `subscribeOnMain`.
    @discardableResult
    public func subscribeOnce<Owner: AnyObject & Sendable, Event: EventBusEvent>(
        owner: Owner,
        to eventType: Event.Type = Event.self,
        delivery: Delivery = .immediate,
        taskPriority: TaskPriority? = nil,
        handler: @escaping @Sendable (Owner, Event) async -> Void
    ) -> SubscriptionToken {
        subscribeOnce(owner: owner, to: eventType, delivery: delivery) { owner, event in
            switch delivery {
            case .immediate:
                Task(priority: taskPriority) {
                    await handler(owner, event)
                }
            case .mainActor:
                Task(priority: taskPriority) { @MainActor in
                    await handler(owner, event)
                }
            }
        }
    }

    /// Creates an `AsyncStream` for a specific event type.
    ///
    /// The stream keeps an internal owner alive and cancels its subscription on termination.
    public func stream<Event: EventBusEvent>(
        _ eventType: Event.Type = Event.self,
        delivery: Delivery = .immediate,
        bufferingPolicy: AsyncStream<Event>.Continuation.BufferingPolicy = .bufferingNewest(100)
    ) -> AsyncStream<Event> {
        let owner = StreamOwner()
        let tokenBox = TokenBox()
        tokenBox.retain(owner: owner)

        // AsyncStream invokes its builder synchronously.
        var continuation: AsyncStream<Event>.Continuation?
        let stream = AsyncStream<Event>(bufferingPolicy: bufferingPolicy) { streamContinuation in
            continuation = streamContinuation
            streamContinuation.onTermination = { @Sendable _ in
                tokenBox.cancelAndClear()
            }
        }
        
        guard let continuationRef = continuation else {
            assertionFailure("AsyncStream must provide continuation synchronously")
            return AsyncStream { $0.finish() }
        }

        let token = subscribe(owner: owner, to: eventType, delivery: delivery) { (_: StreamOwner, event: Event) in
            continuationRef.yield(event)
        }
        tokenBox.set(token)
        return stream
    }

    /// Unsubscribes `owner` from one event type.
    ///
    /// This removes every subscription created by `owner` for `eventType`.
    public func unsubscribe<Owner: AnyObject, Event: EventBusEvent>(
        owner: Owner,
        from eventType: Event.Type = Event.self
    ) {
        let eventKey = ObjectIdentifier(eventType)
        let ownerID = ObjectIdentifier(owner)

        lock.withLock {
            guard let bucket = subscriptionsByEvent[eventKey] else {
                return
            }

            var filtered: [SubscriptionEntry] = []
            filtered.reserveCapacity(bucket.count)

            for entry in bucket {
                guard entry.subscription.isAlive else {
                    continue
                }

                if entry.subscription.belongs(to: ownerID) {
                    entry.subscription.cancelDelivery()
                } else {
                    filtered.append(entry)
                }
            }

            subscriptionsByEvent[eventKey] = filtered.isEmpty ? nil : filtered
        }
    }

    /// Unsubscribes `owner` from all event types.
    public func unsubscribeAll(for owner: AnyObject) {
        let ownerID = ObjectIdentifier(owner)

        lock.withLock {
            for (eventKey, bucket) in subscriptionsByEvent {
                var filtered: [SubscriptionEntry] = []
                filtered.reserveCapacity(bucket.count)

                for entry in bucket {
                    guard entry.subscription.isAlive else {
                        continue
                    }

                    if entry.subscription.belongs(to: ownerID) {
                        entry.subscription.cancelDelivery()
                    } else {
                        filtered.append(entry)
                    }
                }

                subscriptionsByEvent[eventKey] = filtered.isEmpty ? nil : filtered
            }
        }
    }
}

extension EventBus {
    /// Where a subscriber handler is executed.
    public enum Delivery: Sendable {
        /// Executes the handler synchronously during `publish(_:)` after the lock is released.
        /// This does not imply `MainActor`.
        case immediate
        /// Schedules the handler asynchronously on `MainActor`.
        case mainActor
    }

    /// A cancellable handle for one specific subscription.
    public final class SubscriptionToken: @unchecked Sendable {
        private let lock = NSLock()
        private let cancellationState: CancellationState
        private let cancelClosure: @Sendable () -> Void
        private var isCancelled = false

        fileprivate init(
            cancellationState: CancellationState,
            cancelClosure: @escaping @Sendable () -> Void
        ) {
            self.cancellationState = cancellationState
            self.cancelClosure = cancelClosure
        }

        /// Cancels the associated subscription.
        public func cancel() {
            lock.lock()
            guard !isCancelled else {
                lock.unlock()
                return
            }
            isCancelled = true
            lock.unlock()

            cancellationState.cancel()
            cancelClosure()
        }
    }
}

private extension EventBus {
    struct SubscriptionEntry {
        let id: UUID
        let subscription: Subscription
    }

    func subscribeInternal<Owner: AnyObject & Sendable, Event: EventBusEvent>(
        owner: Owner,
        to eventType: Event.Type,
        delivery: Delivery,
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
        let entry = SubscriptionEntry(id: id, subscription: subscription)

        lock.withLock {
            var bucket = subscriptionsByEvent[eventKey] ?? []
            bucket = cleanDeadSubscriptions(in: bucket)
            bucket.append(entry)
            subscriptionsByEvent[eventKey] = bucket
        }

        return SubscriptionToken(cancellationState: cancellationState) { [weak self] in
            self?.removeSubscription(eventKey: eventKey, id: id)
        }
    }

    @MainActor
    func subscribeMainActorInternal<Owner: AnyObject, Event: EventBusEvent>(
        owner: Owner,
        to eventType: Event.Type,
        handler: @escaping @MainActor (Owner, Event) -> Void
    ) -> SubscriptionToken {
        let eventKey = ObjectIdentifier(eventType)
        let id = UUID()
        let cancellationState = CancellationState()
        let subscription = Subscription(
            mainActorOwner: owner,
            cancellationState: cancellationState,
            handler: handler
        )
        let entry = SubscriptionEntry(id: id, subscription: subscription)

        lock.withLock {
            var bucket = subscriptionsByEvent[eventKey] ?? []
            bucket = cleanDeadSubscriptions(in: bucket)
            bucket.append(entry)
            subscriptionsByEvent[eventKey] = bucket
        }

        return SubscriptionToken(cancellationState: cancellationState) { [weak self] in
            self?.removeSubscription(eventKey: eventKey, id: id)
        }
    }

    func cleanDeadSubscriptions(in bucket: [SubscriptionEntry]) -> [SubscriptionEntry] {
        bucket.filter { $0.subscription.isAlive }
    }

    func removeSubscription(eventKey: ObjectIdentifier, id: UUID) {
        lock.withLock {
            guard var bucket = subscriptionsByEvent[eventKey] else {
                return
            }

            guard let index = bucket.firstIndex(where: { $0.id == id }) else {
                return
            }

            bucket[index].subscription.cancelDelivery()
            bucket.remove(at: index)
            subscriptionsByEvent[eventKey] = bucket.isEmpty ? nil : bucket
        }
    }

    final class CancellationState: @unchecked Sendable {
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

    final class Subscription {
        private weak var owner: AnyObject?
        let cancellationState: CancellationState
        let receive: @Sendable (Any) -> Void

        init<Owner: AnyObject & Sendable, Event: EventBusEvent>(
            owner: Owner,
            delivery: Delivery,
            cancellationState: CancellationState,
            handler: @escaping @Sendable (Owner, Event) -> Void
        ) {
            self.owner = owner
            self.cancellationState = cancellationState

            switch delivery {
            case .immediate:
                self.receive = { [weak owner] rawEvent in
                    guard !cancellationState.cancelled(),
                          let owner,
                          let event = rawEvent as? Event else {
                        return
                    }
                    handler(owner, event)
                }
            case .mainActor:
                self.receive = { [weak owner] rawEvent in
                    guard !cancellationState.cancelled(),
                          let event = rawEvent as? Event else {
                        return
                    }

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

        @MainActor
        init<Owner: AnyObject, Event: EventBusEvent>(
            mainActorOwner owner: Owner,
            cancellationState: CancellationState,
            handler: @escaping @MainActor (Owner, Event) -> Void
        ) {
            let ownerRef = WeakOwnerRef(owner)
            self.owner = owner
            self.cancellationState = cancellationState
            self.receive = { rawEvent in
                guard !cancellationState.cancelled(),
                      let event = rawEvent as? Event else {
                    return
                }

                Task { @MainActor in
                    guard !cancellationState.cancelled(),
                          let owner = ownerRef.owner as? Owner else {
                        return
                    }
                    handler(owner, event)
                }
            }
        }

        func cancelDelivery() {
            cancellationState.cancel()
        }

        var isAlive: Bool {
            owner != nil
        }

        func belongs(to ownerID: ObjectIdentifier) -> Bool {
            guard let owner else {
                return false
            }
            return ObjectIdentifier(owner) == ownerID
        }
    }

    // Safe: token/owner references are only accessed under NSLock.
    final class TokenBox: @unchecked Sendable {
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
            owner = nil
            lock.unlock()
            token?.cancel()
        }
    }

    // Safe: mutable state is protected by NSLock.
    final class OnceGate: @unchecked Sendable {
        private let lock = NSLock()
        private var hasDelivered = false

        func consumeFirstDelivery() -> Bool {
            lock.lock()
            defer { lock.unlock() }
            guard !hasDelivered else {
                return false
            }
            hasDelivered = true
            return true
        }
    }

    @MainActor
    final class WeakOwnerRef {
        weak var owner: AnyObject?

        init(_ owner: AnyObject) {
            self.owner = owner
        }
    }

    final class StreamOwner: @unchecked Sendable {}
}

private extension NSLock {
    @discardableResult
    func withLock<T>(_ body: () -> T) -> T {
        lock()
        defer { unlock() }
        return body()
    }
}
