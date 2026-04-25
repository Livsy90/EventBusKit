import Foundation
import Testing
@testable import EventBusKit

private struct IntEvent: EventBusEvent, Sendable {
    let value: Int
}

private struct StringEvent: EventBusEvent, Sendable {
    let value: String
}

private final class TestOwner: @unchecked Sendable {}
@MainActor
private final class MainActorOwner {
    var values: [Int] = []
}

private final class BoolBox: @unchecked Sendable {
    private let lock = NSLock()
    private var value = false

    func set(_ newValue: Bool) {
        lock.lock()
        value = newValue
        lock.unlock()
    }

    func get() -> Bool {
        lock.lock()
        defer { lock.unlock() }
        return value
    }
}

private final class Recorder: @unchecked Sendable {
    private let lock = NSLock()
    private var values: [Int] = []

    func append(_ value: Int) {
        lock.lock()
        values.append(value)
        lock.unlock()
    }

    func snapshot() -> [Int] {
        lock.lock()
        defer { lock.unlock() }
        return values
    }

    func count() -> Int {
        lock.lock()
        defer { lock.unlock() }
        return values.count
    }
}

private func eventually(
    timeoutNanoseconds: UInt64 = 1_000_000_000,
    intervalNanoseconds: UInt64 = 10_000_000,
    condition: @escaping @Sendable () -> Bool
) async -> Bool {
    let start = DispatchTime.now().uptimeNanoseconds
    while DispatchTime.now().uptimeNanoseconds - start < timeoutNanoseconds {
        if condition() {
            return true
        }
        try? await Task.sleep(nanoseconds: intervalNanoseconds)
    }
    return condition()
}

@Test
func publishDeliversToSubscriber() async {
    let bus = EventBus()
    let owner = TestOwner()
    let recorder = Recorder()

    _ = bus.subscribe(owner: owner, to: IntEvent.self) { _, event in
        recorder.append(event.value)
    }

    bus.publish(IntEvent(value: 1))
    bus.publish(IntEvent(value: 2))

    #expect(recorder.snapshot() == [1, 2])
}

@Test
func subscribeWithoutRetainingTokenStaysActive() async {
    let bus = EventBus()
    let owner = TestOwner()
    let recorder = Recorder()

    _ = bus.subscribe(owner: owner, to: IntEvent.self) { _, event in
        recorder.append(event.value)
    }

    bus.publish(IntEvent(value: 5))

    #expect(recorder.snapshot() == [5])
}

@Test
func subscribeOnceDeliversOnlyFirstEvent() async {
    let bus = EventBus()
    let owner = TestOwner()
    let recorder = Recorder()

    _ = bus.subscribeOnce(owner: owner, to: IntEvent.self) { _, event in
        recorder.append(event.value)
    }

    bus.publish(IntEvent(value: 10))
    bus.publish(IntEvent(value: 20))

    #expect(recorder.snapshot() == [10])
}

@Test
func subscriptionsDeliverInRegistrationOrder() async {
    let bus = EventBus()
    let owner = TestOwner()
    let recorder = Recorder()

    let firstToken = bus.subscribe(owner: owner, to: IntEvent.self) { _, _ in
        recorder.append(1)
    }
    let secondToken = bus.subscribe(owner: owner, to: IntEvent.self) { _, _ in
        recorder.append(2)
    }

    bus.publish(IntEvent(value: 0))

    #expect(recorder.snapshot() == [1, 2])
    firstToken.cancel()
    secondToken.cancel()
}

@Test
func tokenCancelsOnlyOneSubscription() async {
    let bus = EventBus()
    let owner = TestOwner()
    let recorder = Recorder()

    let firstToken = bus.subscribe(owner: owner, to: IntEvent.self) { _, _ in
        recorder.append(1)
    }
    let secondToken = bus.subscribe(owner: owner, to: IntEvent.self) { _, _ in
        recorder.append(2)
    }

    firstToken.cancel()
    bus.publish(IntEvent(value: 0))

    #expect(recorder.snapshot() == [2])
    secondToken.cancel()
}

@Test
func subscribeOnceMainThreadDeliversOnlyOnceAcrossQueuedPublishes() async {
    let bus = EventBus()
    let owner = TestOwner()
    let recorder = Recorder()

    _ = bus.subscribeOnce(owner: owner, to: IntEvent.self, delivery: .mainActor) { _, event in
        recorder.append(event.value)
    }

    await withTaskGroup(of: Void.self) { group in
        group.addTask {
            bus.publish(IntEvent(value: 1))
        }
        group.addTask {
            bus.publish(IntEvent(value: 2))
        }
        group.addTask {
            bus.publish(IntEvent(value: 3))
        }
    }

    let delivered = await eventually {
        recorder.count() == 1
    }

    #expect(delivered)
    #expect(recorder.count() == 1)
}

@Test
func unsubscribeStopsDelivery() async {
    let bus = EventBus()
    let owner = TestOwner()
    let recorder = Recorder()

    _ = bus.subscribe(owner: owner, to: IntEvent.self) { _, event in
        recorder.append(event.value)
    }

    bus.unsubscribe(owner: owner, from: IntEvent.self)
    bus.publish(IntEvent(value: 7))

    #expect(recorder.count() == 0)
}

@Test
func unsubscribeAllRemovesOnlyMatchingOwner() async {
    let bus = EventBus()
    let ownerA = TestOwner()
    let ownerB = TestOwner()
    let recorderA = Recorder()
    let recorderB = Recorder()

    let tokenA = bus.subscribe(owner: ownerA, to: IntEvent.self) { _, event in
        recorderA.append(event.value)
    }
    let tokenB = bus.subscribe(owner: ownerB, to: IntEvent.self) { _, event in
        recorderB.append(event.value)
    }

    bus.unsubscribeAll(for: ownerA)
    bus.publish(IntEvent(value: 42))

    #expect(recorderA.count() == 0)
    #expect(recorderB.snapshot() == [42])
    tokenA.cancel()
    tokenB.cancel()
}

@Test
func unsubscribeRemovesOnlyMatchingEventType() async {
    let bus = EventBus()
    let owner = TestOwner()
    let intRecorder = Recorder()
    let stringRecorder = Recorder()

    let intToken = bus.subscribe(owner: owner, to: IntEvent.self) { _, event in
        intRecorder.append(event.value)
    }
    let stringToken = bus.subscribe(owner: owner, to: StringEvent.self) { _, event in
        stringRecorder.append(event.value.count)
    }

    bus.unsubscribe(owner: owner, from: IntEvent.self)
    bus.publish(IntEvent(value: 11))
    bus.publish(StringEvent(value: "ok"))

    #expect(intRecorder.count() == 0)
    #expect(stringRecorder.snapshot() == [2])
    intToken.cancel()
    stringToken.cancel()
}

@Test
func streamEmitsPublishedEvents() async {
    let bus = EventBus()
    let stream = bus.stream(IntEvent.self)

    let reader = Task { () -> [Int] in
        var received: [Int] = []
        for await event in stream {
            received.append(event.value)
            if received.count == 2 {
                break
            }
        }
        return received
    }

    bus.publish(IntEvent(value: 3))
    bus.publish(IntEvent(value: 4))

    let received = await reader.value
    #expect(received == [3, 4])
}
@Test
func mainThreadDeliveryRunsHandlerOnMainThread() async {
    let bus = EventBus()
    let owner = TestOwner()
    let recorder = Recorder()
    let isMainThread = BoolBox()

    _ = bus.subscribe(owner: owner, to: IntEvent.self, delivery: .mainActor) { _, event in
        isMainThread.set(Thread.isMainThread)
        recorder.append(event.value)
    }

    bus.publish(IntEvent(value: 1))

    let delivered = await eventually {
        recorder.count() == 1
    }

    #expect(delivered)
    #expect(isMainThread.get())
}

@Test
func mainThreadAsyncEventOnlyDeliveryRunsHandlerOnMainThread() async {
    let bus = EventBus()
    let owner = TestOwner()
    let recorder = Recorder()
    let isMainThread = BoolBox()

    _ = bus.subscribe(
        owner: owner,
        to: IntEvent.self,
        delivery: .mainActor
    ) { event in
        isMainThread.set(Thread.isMainThread)
        recorder.append(event.value)
    }

    bus.publish(IntEvent(value: 2))

    let delivered = await eventually {
        recorder.count() == 1
    }

    #expect(delivered)
    #expect(isMainThread.get())
}

@Test
func deallocatedOwnerDoesNotReceiveEvents() async {
    let bus = EventBus()
    var owner: TestOwner? = TestOwner()
    let recorder = Recorder()

    _ = bus.subscribe(owner: owner!, to: IntEvent.self) { _, event in
        recorder.append(event.value)
    }

    owner = nil
    bus.publish(IntEvent(value: 9))

    #expect(recorder.count() == 0)
}

@Test
func streamStopsAfterConsumerCancellation() async {
    let bus = EventBus()
    let stream = bus.stream(IntEvent.self)
    let recorder = Recorder()

    let reader = Task {
        for await event in stream {
            recorder.append(event.value)
        }
    }

    bus.publish(IntEvent(value: 1))

    let firstDelivered = await eventually {
        recorder.count() == 1
    }
    #expect(firstDelivered)

    reader.cancel()
    _ = await reader.value

    bus.publish(IntEvent(value: 2))
    try? await Task.sleep(nanoseconds: 50_000_000)

    #expect(recorder.snapshot() == [1])
}

@Test
func tokenCancelIsIdempotent() async {
    let bus = EventBus()
    let owner = TestOwner()
    let recorder = Recorder()

    let token = bus.subscribe(owner: owner, to: IntEvent.self) { _, event in
        recorder.append(event.value)
    }

    token.cancel()
    token.cancel()
    token.cancel()

    bus.publish(IntEvent(value: 100))

    #expect(recorder.count() == 0)
}

@Test
func subscribeOnMainSupportsNonSendableOwner() async {
    let bus = EventBus()
    let delivered = BoolBox()
    let owner = await MainActor.run { MainActorOwner() }
    let token = await MainActor.run {
        bus.subscribeOnMain(owner: owner, to: IntEvent.self) { owner, event in
            owner.values.append(event.value)
            delivered.set(true)
        }
    }

    bus.publish(IntEvent(value: 8))

    #expect(await eventually { delivered.get() })
    #expect(await MainActor.run { owner.values == [8] })
    token.cancel()
}

@Test
func concurrentPublishDeliversAllEventsWithoutLoss() async {
    let bus = EventBus()
    let owner = TestOwner()
    let recorder = Recorder()

    let token = bus.subscribe(owner: owner, to: IntEvent.self) { _, event in
        recorder.append(event.value)
    }

    let producers = 10
    let eventsPerProducer = 50
    let total = producers * eventsPerProducer

    await withTaskGroup(of: Void.self) { group in
        for producer in 0..<producers {
            group.addTask {
                for index in 0..<eventsPerProducer {
                    let value = producer * 1_000 + index
                    bus.publish(IntEvent(value: value))
                }
            }
        }
    }

    let allDelivered = await eventually(timeoutNanoseconds: 2_000_000_000) {
        recorder.count() == total
    }

    #expect(allDelivered)
    #expect(recorder.count() == total)
    token.cancel()
}
