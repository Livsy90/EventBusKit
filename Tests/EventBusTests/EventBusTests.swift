import Foundation
import Testing
@testable import EventBus

private struct IntEvent: EventBusEvent, Sendable {
    let value: Int
}

private struct StringEvent: EventBusEvent, Sendable {
    let value: String
}

private final class TestOwner: @unchecked Sendable {}

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

    await bus.subscribe(owner: owner, to: IntEvent.self) { _, event in
        recorder.append(event.value)
    }

    await bus.publish(IntEvent(value: 1))
    await bus.publish(IntEvent(value: 2))

    #expect(recorder.snapshot() == [1, 2])
}

@Test
func subscribeWithoutRetainingTokenStaysActive() async {
    let bus = EventBus()
    let owner = TestOwner()
    let recorder = Recorder()

    await bus.subscribe(owner: owner, to: IntEvent.self) { _, event in
        recorder.append(event.value)
    }

    await bus.publish(IntEvent(value: 5))

    #expect(recorder.snapshot() == [5])
}

@Test
func subscribeOnceDeliversOnlyFirstEvent() async {
    let bus = EventBus()
    let owner = TestOwner()
    let recorder = Recorder()

    await bus.subscribeOnce(owner: owner, to: IntEvent.self) { _, event in
        recorder.append(event.value)
    }

    await bus.publish(IntEvent(value: 10))
    await bus.publish(IntEvent(value: 20))

    #expect(recorder.snapshot() == [10])
}

@Test
func subscribeOnceMainThreadDeliversOnlyOnceAcrossQueuedPublishes() async {
    let bus = EventBus()
    let owner = TestOwner()
    let recorder = Recorder()

    await bus.subscribeOnce(owner: owner, to: IntEvent.self, delivery: .mainThread) { _, event in
        recorder.append(event.value)
    }

    await withTaskGroup(of: Void.self) { group in
        group.addTask {
            await bus.publish(IntEvent(value: 1))
        }
        group.addTask {
            await bus.publish(IntEvent(value: 2))
        }
        group.addTask {
            await bus.publish(IntEvent(value: 3))
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

    await bus.subscribe(owner: owner, to: IntEvent.self) { _, event in
        recorder.append(event.value)
    }

    await bus.unsubscribe(owner: owner, from: IntEvent.self)
    await bus.publish(IntEvent(value: 7))

    #expect(recorder.count() == 0)
}

@Test
func unsubscribeAllRemovesOnlyMatchingOwner() async {
    let bus = EventBus()
    let ownerA = TestOwner()
    let ownerB = TestOwner()
    let recorderA = Recorder()
    let recorderB = Recorder()

    await bus.subscribe(owner: ownerA, to: IntEvent.self) { _, event in
        recorderA.append(event.value)
    }
    await bus.subscribe(owner: ownerB, to: IntEvent.self) { _, event in
        recorderB.append(event.value)
    }

    await bus.unsubscribeAll(for: ownerA)
    await bus.publish(IntEvent(value: 42))

    #expect(recorderA.count() == 0)
    #expect(recorderB.snapshot() == [42])
}

@Test
func unsubscribeRemovesOnlyMatchingEventType() async {
    let bus = EventBus()
    let owner = TestOwner()
    let intRecorder = Recorder()
    let stringRecorder = Recorder()

    await bus.subscribe(owner: owner, to: IntEvent.self) { _, event in
        intRecorder.append(event.value)
    }
    await bus.subscribe(owner: owner, to: StringEvent.self) { _, event in
        stringRecorder.append(event.value.count)
    }

    await bus.unsubscribe(owner: owner, from: IntEvent.self)
    await bus.publish(IntEvent(value: 11))
    await bus.publish(StringEvent(value: "ok"))

    #expect(intRecorder.count() == 0)
    #expect(stringRecorder.snapshot() == [2])
}

@Test
func streamEmitsPublishedEvents() async {
    let bus = EventBus()
    let stream = await bus.stream(IntEvent.self)

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

    await bus.publish(IntEvent(value: 3))
    await bus.publish(IntEvent(value: 4))

    let received = await reader.value
    #expect(received == [3, 4])
}
@Test
func mainThreadDeliveryRunsHandlerOnMainThread() async {
    let bus = EventBus()
    let owner = TestOwner()
    let recorder = Recorder()
    let isMainThread = BoolBox()

    await bus.subscribe(owner: owner, to: IntEvent.self, delivery: .mainThread) { _, event in
        isMainThread.set(Thread.isMainThread)
        recorder.append(event.value)
    }

    await bus.publish(IntEvent(value: 1))

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

    await bus.subscribe(
        owner: owner,
        to: IntEvent.self,
        delivery: .mainThread
    ) { event in
        isMainThread.set(Thread.isMainThread)
        recorder.append(event.value)
    }

    await bus.publish(IntEvent(value: 2))

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

    await bus.subscribe(owner: owner!, to: IntEvent.self) { _, event in
        recorder.append(event.value)
    }

    owner = nil
    await bus.publish(IntEvent(value: 9))

    #expect(recorder.count() == 0)
}

@Test
func streamStopsAfterConsumerCancellation() async {
    let bus = EventBus()
    let stream = await bus.stream(IntEvent.self)
    let recorder = Recorder()

    let reader = Task {
        for await event in stream {
            recorder.append(event.value)
        }
    }

    await bus.publish(IntEvent(value: 1))

    let firstDelivered = await eventually {
        recorder.count() == 1
    }
    #expect(firstDelivered)

    reader.cancel()
    _ = await reader.value

    await bus.publish(IntEvent(value: 2))
    try? await Task.sleep(nanoseconds: 50_000_000)

    #expect(recorder.snapshot() == [1])
}

@Test
func unsubscribeIsIdempotent() async {
    let bus = EventBus()
    let owner = TestOwner()
    let recorder = Recorder()

    await bus.subscribe(owner: owner, to: IntEvent.self) { _, event in
        recorder.append(event.value)
    }

    await bus.unsubscribe(owner: owner, from: IntEvent.self)
    await bus.unsubscribe(owner: owner, from: IntEvent.self)
    await bus.unsubscribe(owner: owner, from: IntEvent.self)

    await bus.publish(IntEvent(value: 100))

    #expect(recorder.count() == 0)
}

@Test
func concurrentPublishDeliversAllEventsWithoutLoss() async {
    let bus = EventBus()
    let owner = TestOwner()
    let recorder = Recorder()

    await bus.subscribe(owner: owner, to: IntEvent.self) { _, event in
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
                    await bus.publish(IntEvent(value: value))
                }
            }
        }
    }

    let allDelivered = await eventually(timeoutNanoseconds: 2_000_000_000) {
        recorder.count() == total
    }

    #expect(allDelivered)
    #expect(recorder.count() == total)
}
