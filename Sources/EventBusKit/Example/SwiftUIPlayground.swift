import SwiftUI

@available(iOS 15.0, *)
private struct EventBusPlaygroundView: View {
    @StateObject private var model = EventBusPlaygroundModel()
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
                        model.startClassic()
                    }
                    Button("Start Once Subscribe") {
                        model.startOnce()
                    }
                    Button("Start Stream Subscribe") {
                        model.startStream()
                    }
                    Button("Publish One") {
                        model.publishOne(source: source)
                    }
                    Button("Publish Burst (5)") {
                        model.publishBurst(count: 5, source: source)
                    }
                    Button("Stop All") {
                        model.stopAll()
                    }
                    Button("Reset State") {
                        model.resetState()
                    }
                }

                Group {
                    Text("Active: classic=\(model.classicActive.description), once=\(model.onceActive.description), stream=\(model.streamActive.description)")
                    Text("Emitted: \(model.emittedCount)")
                    Text("Received: classic=\(model.classicCount), once=\(model.onceCount), stream=\(model.streamCount)")
                }
                .font(.caption.monospaced())

                Divider()

                Text("Logs")
                    .font(.headline)

                ForEach(Array(model.logs.enumerated()), id: \.offset) { _, line in
                    Text(line)
                        .font(.caption.monospaced())
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
            }
            .padding()
        }
    }
}

private final class PlaygroundOwner {}

@MainActor
private final class EventBusPlaygroundModel: ObservableObject {
    @Published private(set) var classicActive = false
    @Published private(set) var onceActive = false
    @Published private(set) var streamActive = false
    @Published private(set) var emittedCount = 0
    @Published private(set) var classicCount = 0
    @Published private(set) var onceCount = 0
    @Published private(set) var streamCount = 0
    @Published private(set) var logs: [String] = []

    private let eventBus: EventBus
    private let sessionService: SessionService

    private let classicOwner = PlaygroundOwner()
    private let onceOwner = PlaygroundOwner()

    private var classicToken: EventBus.SubscriptionToken?
    private var onceToken: EventBus.SubscriptionToken?
    private var streamTask: Task<Void, Never>?
    private var nextUserIndex = 1

    init(eventBus: EventBus = .default) {
        self.eventBus = eventBus
        self.sessionService = SessionService(eventBus: eventBus)
    }

    func startClassic() {
        guard classicToken == nil else {
            return
        }

        classicToken = eventBus.subscribeOnMain(owner: classicOwner, to: UserDidLoginEvent.self) { [weak self] _, event in
            guard let self else {
                return
            }

            self.classicCount += 1
            self.addLog("classic received: \(event.userID.rawValue)")
        }
        classicActive = true
        addLog("classic subscribed")
    }

    func startOnce() {
        guard onceToken == nil else {
            return
        }

        onceToken = eventBus.subscribeOnMain(owner: onceOwner, to: UserDidLoginEvent.self) { [weak self] _, event in
            guard let self else {
                return
            }

            self.onceCount += 1
            self.onceToken?.cancel()
            self.onceToken = nil
            self.onceActive = false
            self.addLog("once received: \(event.userID.rawValue)")
        }
        onceActive = true
        addLog("once subscribed")
    }

    func startStream() {
        guard streamTask == nil else {
            return
        }

        let stream = eventBus.stream(
            UserDidLoginEvent.self,
            bufferingPolicy: .bufferingNewest(20)
        )

        streamTask = Task { @MainActor [weak self] in
            guard let self else {
                return
            }

            for await event in stream {
                self.streamCount += 1
                self.addLog("stream received: \(event.userID.rawValue)")
            }
        }
        streamActive = true
        addLog("stream subscribed")
    }

    func publishOne(source: UserDidLoginEvent.Source) {
        emittedCount += 1
        sessionService.login(userID: UserID("user-\(nextUserIndex)"), source: source)
        nextUserIndex += 1
        addLog("published 1 event [\(source.rawValue)]")
    }

    func publishBurst(count: Int, source: UserDidLoginEvent.Source) {
        guard count > 0 else {
            return
        }

        for _ in 0..<count {
            publishOne(source: source)
        }
        addLog("burst published: \(count)")
    }

    func stopAll() {
        classicToken?.cancel()
        classicToken = nil
        classicActive = false

        onceToken?.cancel()
        onceToken = nil
        onceActive = false

        streamTask?.cancel()
        streamTask = nil
        streamActive = false

        addLog("all subscriptions stopped")
    }

    func resetState() {
        emittedCount = 0
        classicCount = 0
        onceCount = 0
        streamCount = 0
        nextUserIndex = 1
        logs = ["state reset"]
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
