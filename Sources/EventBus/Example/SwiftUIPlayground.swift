import SwiftUI

@available(iOS 15.0, *)
private struct EventBusPlaygroundView: View {
    @State private var harness = EventBusPlaygroundHarness()
    @State private var snapshot = EventBusPlaygroundHarness.Snapshot.empty
    @State private var source: UserDidLoginEvent.Source = .password

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 12) {
                Text("Event Bus Playground")
                    .font(.title2.weight(.semibold))

                Picker("Source", selection: $source) {
                    ForEach(UserDidLoginEvent.Source.allCases, id: \.self) { item in
                        Text(item.rawValue.capitalized).tag(item)
                    }
                }
                .pickerStyle(.segmented)

                VStack(alignment: .leading, spacing: 8) {
                    Button("Start Classic Subscribe") {
                        run { await $0.startClassic() }
                    }
                    Button("Start Async Subscribe") {
                        run { await $0.startAsync() }
                    }
                    Button("Start Once Subscribe") {
                        run { await $0.startOnce() }
                    }
                    Button("Start Stream Subscribe") {
                        run { await $0.startStream() }
                    }
                    Button("Publish One") {
                        run { await $0.publishOne(source: source) }
                    }
                    Button("Publish Burst (5)") {
                        run { await $0.publishBurst(count: 5, source: source) }
                    }
                    Button("Stop All") {
                        run { await $0.stopAll() }
                    }
                    Button("Reset State") {
                        run { await $0.resetState() }
                    }
                }

                Group {
                    Text("Active: classic=\(snapshot.classicActive.description), async=\(snapshot.asyncActive.description), once=\(snapshot.onceActive.description), stream=\(snapshot.streamActive.description)")
                    Text("Emitted: \(snapshot.emittedCount)")
                    Text("Received: classic=\(snapshot.classicCount), async=\(snapshot.asyncCount), once=\(snapshot.onceCount), stream=\(snapshot.streamCount)")
                }
                .font(.caption.monospaced())

                Divider()

                Text("Logs")
                    .font(.headline)

                ForEach(Array(snapshot.logs.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.caption.monospaced())
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding()
        }
        .task {
            let initial = await harness.snapshot()
            snapshot = initial
        }
    }

    private func run(_ action: @escaping @Sendable (EventBusPlaygroundHarness) async -> Void) {
        Task {
            await action(harness)
            let latest = await harness.snapshot()
            await MainActor.run {
                snapshot = latest
            }
        }
    }
}

private final class PlaygroundOwner: @unchecked Sendable {}

private actor EventBusPlaygroundHarness {
    struct Snapshot: Sendable {
        let classicActive: Bool
        let asyncActive: Bool
        let onceActive: Bool
        let streamActive: Bool
        let emittedCount: Int
        let classicCount: Int
        let asyncCount: Int
        let onceCount: Int
        let streamCount: Int
        let logs: [String]

        static let empty = Snapshot(
            classicActive: false,
            asyncActive: false,
            onceActive: false,
            streamActive: false,
            emittedCount: 0,
            classicCount: 0,
            asyncCount: 0,
            onceCount: 0,
            streamCount: 0,
            logs: []
        )
    }

    private let eventBus: EventBus
    private let sessionService: SessionService

    private let classicOwner = PlaygroundOwner()
    private let asyncOwner = PlaygroundOwner()
    private let onceOwner = PlaygroundOwner()

    private var classicToken: EventBus.SubscriptionToken?
    private var asyncToken: EventBus.SubscriptionToken?
    private var onceToken: EventBus.SubscriptionToken?
    private var streamTask: Task<Void, Never>?

    private var emittedCount = 0
    private var classicCount = 0
    private var asyncCount = 0
    private var onceCount = 0
    private var streamCount = 0
    private var logs: [String] = []
    private var nextUserIndex = 1

    init(eventBus: EventBus = .default) {
        self.eventBus = eventBus
        self.sessionService = SessionService(eventBus: eventBus)
    }

    func startClassic() async {
        guard classicToken == nil else {
            return
        }

        classicToken = await eventBus.subscribe(owner: classicOwner, to: UserDidLoginEvent.self) { [weak self] _, event in
            Task {
                await self?.record(channel: "classic", event: event)
            }
        }
        addLog("classic subscribed")
    }

    func startAsync() async {
        guard asyncToken == nil else {
            return
        }

        asyncToken = await eventBus.subscribe(
            owner: asyncOwner,
            to: UserDidLoginEvent.self,
            delivery: .postingTask,
            taskPriority: .utility
        ) { [weak self] _, event in
            await self?.record(channel: "async", event: event)
        }
        addLog("async subscribed")
    }

    func startOnce() async {
        guard onceToken == nil else {
            return
        }

        onceToken = await eventBus.subscribeOnce(owner: onceOwner, to: UserDidLoginEvent.self) { [weak self] _, event in
            Task {
                await self?.record(channel: "once", event: event)
            }
        }
        addLog("once subscribed")
    }

    func startStream() {
        guard streamTask == nil else {
            return
        }

        streamTask = Task { [eventBus, weak self] in
            let stream = await eventBus.stream(
                UserDidLoginEvent.self,
                delivery: .postingTask,
                bufferingPolicy: .bufferingNewest(20)
            )

            for await event in stream {
                await self?.record(channel: "stream", event: event)
            }
        }
        addLog("stream subscribed")
    }

    func stopAll() {
        classicToken?.cancel()
        classicToken = nil

        asyncToken?.cancel()
        asyncToken = nil

        onceToken?.cancel()
        onceToken = nil

        streamTask?.cancel()
        streamTask = nil

        addLog("all subscriptions stopped")
    }

    func resetState() {
        emittedCount = 0
        classicCount = 0
        asyncCount = 0
        onceCount = 0
        streamCount = 0
        nextUserIndex = 1
        logs = ["state reset"]
    }

    private func login(userID: UserID, source: UserDidLoginEvent.Source) async {
        await sessionService.login(userID: userID, source: source)
    }

    func publishOne(source: UserDidLoginEvent.Source) async {
        emittedCount += 1
        await login(userID: UserID("user-\(nextUserIndex)"), source: source)
        nextUserIndex += 1
        addLog("published 1 event [\(source.rawValue)]")
    }

    func publishBurst(count: Int, source: UserDidLoginEvent.Source) async {
        guard count > 0 else {
            return
        }

        for _ in 0..<count {
            await publishOne(source: source)
        }
        addLog("burst published: \(count)")
    }

    func snapshot() -> Snapshot {
        Snapshot(
            classicActive: classicToken != nil,
            asyncActive: asyncToken != nil,
            onceActive: onceToken != nil,
            streamActive: streamTask != nil,
            emittedCount: emittedCount,
            classicCount: classicCount,
            asyncCount: asyncCount,
            onceCount: onceCount,
            streamCount: streamCount,
            logs: logs
        )
    }

    private func record(channel: String, event: UserDidLoginEvent) {
        switch channel {
        case "classic":
            classicCount += 1
        case "async":
            asyncCount += 1
        case "once":
            onceCount += 1
        case "stream":
            streamCount += 1
        default:
            break
        }

        addLog("\(channel) received: \(event.userID.rawValue)")
    }

    private func addLog(_ message: String) {
        logs.insert(message, at: 0)
        if logs.count > 30 {
            logs.removeLast(logs.count - 30)
        }
    }
}

#Preview("EventBus Playground") {
    if #available(iOS 15.0, *) {
        EventBusPlaygroundView()
    }
}

