import Testing

@testable import InfusedTea

struct RuntimeTests {
    @Test func runtimeStops() async throws {
        let program = Counter()
        let runtime = Runtime(program: program)

        let task = Task {
            await runtime.start()
            return true
        }

        try await Task.sleep(for: .milliseconds(10))

        await runtime.stop()
        let didStop = await task.value
        #expect(didStop)
    }

    @Test func programInit() async throws {
        let program = Counter()
        let runtime = Runtime(program: program)

        let (heartbeatStream, heartbeatCont) = AsyncStream<Void>.makeStream()
        await runtime.use { _, _ in
            heartbeatCont.yield(())
        }

        Task {
            await runtime.start()
        }

        var heartbeat = heartbeatStream.makeAsyncIterator()
        await heartbeat.next()  // runtime is initialized

        await #expect(runtime.currentModel == 0)

        await runtime.stop()
    }

    @Test func stateTransitions() async throws {
        let program = Counter()
        let runtime = Runtime(program: program)

        var history = [Int]()
        await runtime.use { newModel, _ in
            history.append(newModel)
        }

        let (heartbeatStream, heartbeatCont) = AsyncStream<Void>.makeStream()
        await runtime.use { _, _ in
            heartbeatCont.yield(())
        }

        Task {
            await runtime.start()
        }

        var heartbeat = heartbeatStream.makeAsyncIterator()
        await heartbeat.next()  // runtime is initialized

        await runtime.send(.increment)  // +1
        await heartbeat.next()

        await runtime.send(.decrement)  // -1
        await heartbeat.next()

        await runtime.send(.increment)  // +1
        await heartbeat.next()

        await runtime.send(.increment)  // +1
        await heartbeat.next()

        await runtime.send(.decrement)  // -1
        await heartbeat.next()

        #expect(history == [0, 1, 0, 1, 2, 1])

        await runtime.stop()
    }

    @Test func asyncCommands() async throws {
        let program = AsyncCounter()
        let runtime = Runtime(program: program)

        var history = [Int]()
        await runtime.use { newModel, _ in
            history.append(newModel)
        }

        Task {
            await runtime.start()
        }

        try await Task.sleep(for: .milliseconds(50))  // wait for async command chain
        #expect(history == [0, 1, 2, 3])

        await runtime.stop()
    }

    @Test func subscriptionReceivesMessages() async throws {
        let (forwardStream, forwardCont) = AsyncStream<SubscriptionCounter.Message>.makeStream()

        let program = SubscriptionCounter(isRunning: false) { _ in
            ["forward": forwardStream]
        }
        let runtime = Runtime(program: program)

        var history = [Int]()
        await runtime.use { newModel, _ in
            history.append(newModel.tickCount)
        }

        let (heartbeatStream, heartbeatCont) = AsyncStream<Void>.makeStream()
        await runtime.use { _, _ in
            heartbeatCont.yield(())
        }

        Task {
            await runtime.start()
        }

        var heartbeat = heartbeatStream.makeAsyncIterator()
        await heartbeat.next()  // runtime is initialized

        forwardCont.yield(.forwardTick)
        await heartbeat.next()
        forwardCont.yield(.forwardTick)
        await heartbeat.next()
        forwardCont.yield(.forwardTick)
        await heartbeat.next()

        #expect(history == [0, 1, 2, 3])

        await runtime.stop()
    }

    @Test func dynamicSubscriptionAddAndRemove() async throws {
        let (tickStream, tickCont) = AsyncStream<SubscriptionCounter.Message>.makeStream()

        let program = SubscriptionCounter(isRunning: false) { model in
            if model.isRunning {
                ["tick": tickStream]
            } else {
                [:]
            }
        }
        let runtime = Runtime(program: program)

        let (heartbeatStream, heartbeatCont) = AsyncStream<Void>.makeStream()
        await runtime.use { _, _ in
            heartbeatCont.yield(())
        }

        Task {
            await runtime.start()
        }

        var heartbeat = heartbeatStream.makeAsyncIterator()
        await heartbeat.next()  // runtime is initialized

        await #expect(runtime.isSubscribed(to: "tick") == false)

        await runtime.send(.toggleRunning)
        await heartbeat.next()  // subscription enabled
        await #expect(runtime.isSubscribed(to: "tick") == true)

        tickCont.yield(.forwardTick)
        await heartbeat.next()
        await #expect(runtime.currentModel?.tickCount == 1)

        tickCont.yield(.forwardTick)
        await heartbeat.next()
        await #expect(runtime.currentModel?.tickCount == 2)

        await runtime.send(.toggleRunning)
        await heartbeat.next()  // subscription disabled
        await #expect(runtime.isSubscribed(to: "tick") == false)

        await runtime.stop()
    }

    @Test func sameIdKeepsOriginalSubscription() async throws {
        let (forwardStream, forwardCont) = AsyncStream<SubscriptionCounter.Message>.makeStream()
        let (backwardStream, _) = AsyncStream<SubscriptionCounter.Message>.makeStream()

        let program = SubscriptionCounter(isRunning: true) { model in
            if model.isForward {
                ["stream": forwardStream]
            } else {
                ["stream": backwardStream]  // same ID = ignored
            }
        }
        let runtime = Runtime(program: program)

        let (heartbeatStream, heartbeatCont) = AsyncStream<Void>.makeStream()
        await runtime.use { _, _ in
            heartbeatCont.yield(())
        }

        Task {
            await runtime.start()
        }

        var heartbeat = heartbeatStream.makeAsyncIterator()
        await heartbeat.next()  // runtime is initialized

        await #expect(runtime.isSubscribed(to: "stream") == true)

        forwardCont.yield(.forwardTick)
        await heartbeat.next()
        await #expect(runtime.currentModel?.tickCount == 1)

        await runtime.send(.toggleDirection)
        await heartbeat.next()  // toggled to backward, but forward continues (same ID)
        await #expect(runtime.currentModel?.tickCount == 1)

        forwardCont.yield(.forwardTick)
        await heartbeat.next()
        await #expect(runtime.currentModel?.tickCount == 2)

        await runtime.stop()
    }

    @Test func subscriptionsRunConcurrently() async throws {
        let (forwardStream, forwardCont) = AsyncStream<SubscriptionCounter.Message>.makeStream()
        let (backwardStream, backwardCont) = AsyncStream<SubscriptionCounter.Message>.makeStream()

        let program = SubscriptionCounter(isRunning: true) { _ in
            ["forward": forwardStream, "backward": backwardStream]
        }
        let runtime = Runtime(program: program)

        let (heartbeatStream, heartbeatCont) = AsyncStream<Void>.makeStream()
        await runtime.use { _, _ in
            heartbeatCont.yield(())
        }

        Task {
            await runtime.start()
        }

        var heartbeat = heartbeatStream.makeAsyncIterator()
        await heartbeat.next()  // runtime is initialized

        await #expect(runtime.isSubscribed(to: "forward") == true)
        await #expect(runtime.isSubscribed(to: "backward") == true)

        forwardCont.yield(.forwardTick)
        await heartbeat.next()
        await #expect(runtime.currentModel?.tickCount == 1)

        backwardCont.yield(.backwardTick)
        await heartbeat.next()
        await #expect(runtime.currentModel?.tickCount == 0)

        forwardCont.yield(.forwardTick)
        await heartbeat.next()
        await #expect(runtime.currentModel?.tickCount == 1)

        backwardCont.yield(.backwardTick)
        await heartbeat.next()
        await #expect(runtime.currentModel?.tickCount == 0)

        await runtime.stop()
    }

    @Test func subscriptionCompletesNaturally() async throws {
        let (forwardStream, forwardCont) = AsyncStream<SubscriptionCounter.Message>.makeStream()
        let (backwardStream, backwardCont) = AsyncStream<SubscriptionCounter.Message>.makeStream()

        let program = SubscriptionCounter(isRunning: true) { _ in
            ["forward": forwardStream, "backward": backwardStream]
        }
        let runtime = Runtime(program: program)

        let (heartbeatStream, heartbeatCont) = AsyncStream<Void>.makeStream()
        await runtime.use { _, _ in
            heartbeatCont.yield(())
        }

        Task {
            await runtime.start()
        }

        var heartbeat = heartbeatStream.makeAsyncIterator()
        await heartbeat.next()  // runtime is initialized

        await #expect(runtime.isSubscribed(to: "forward") == true)
        await #expect(runtime.isSubscribed(to: "backward") == true)

        forwardCont.yield(.forwardTick)
        await heartbeat.next()
        await #expect(runtime.currentModel?.tickCount == 1)

        backwardCont.yield(.backwardTick)
        await heartbeat.next()
        await #expect(runtime.currentModel?.tickCount == 0)

        backwardCont.finish()

        forwardCont.yield(.forwardTick)
        await heartbeat.next()
        await #expect(runtime.currentModel?.tickCount == 1)
        await #expect(runtime.isSubscribed(to: "backward") == false)

        await runtime.stop()
    }
}

private struct Counter: Program {
    func initialize() -> (Int, Command<CounterMessage>) {
        (0, .none)
    }

    func update(_ model: Int, with message: CounterMessage) -> (Int, Command<CounterMessage>) {
        switch message {
        case .increment:
            (model + 1, .none)
        case .decrement:
            (model - 1, .none)
        }
    }
}

private struct AsyncCounter: Program {
    func initialize() -> (Int, Command<CounterMessage>) {
        (0, .task { .increment })
    }

    func update(_ model: Int, with _: CounterMessage) -> (Model, Command<CounterMessage>) {
        let newModel = model + 1

        return if newModel < 3 {
            (newModel, .task { .increment })
        } else {
            (newModel, .none)
        }
    }
}

private enum CounterMessage {
    case increment, decrement
}

private struct SubscriptionCounter: Program {
    enum Message {
        case toggleRunning, toggleDirection
        case forwardTick, backwardTick
    }

    let isRunning: Bool
    let subscriptions: (Model) -> [AnyHashable: AsyncStream<Message>]

    struct Model {
        var isRunning: Bool
        var isForward: Bool
        var tickCount: Int
    }

    func initialize() -> (Model, Command<Message>) {
        (.init(isRunning: isRunning, isForward: true, tickCount: 0), .none)
    }

    func update(_ model: Model, with message: Message) -> (Model, Command<Message>) {
        var newModel = model
        switch message {
        case .toggleRunning:
            newModel.isRunning.toggle()
            return (newModel, .none)
        case .toggleDirection:
            newModel.isForward.toggle()
            return (newModel, .none)
        case .forwardTick:
            newModel.tickCount += 1
            return (newModel, .none)
        case .backwardTick:
            newModel.tickCount -= 1
            return (newModel, .none)
        }
    }

    func subscriptions(_ model: Model) -> [AnyHashable: AsyncStream<Message>] {
        self.subscriptions(model)
    }
}
