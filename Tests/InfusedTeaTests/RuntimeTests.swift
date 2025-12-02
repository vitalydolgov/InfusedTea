import Testing

@testable import InfusedTea

struct RuntimeTests {
    @Test func runtimeStops() async throws {
        let runtime = Runtime(program: Counter())

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
        let runtime = Runtime(program: Counter())
        var iterator = await runtime.modelStream.makeAsyncIterator()

        Task {
            await runtime.start()
        }

        _ = await iterator.next()  // runtime is initialized

        await #expect(runtime.currentModel == 0)

        await runtime.stop()
    }

    @Test func stateTransitions() async throws {
        let runtime = Runtime(program: Counter())
        var iterator = await runtime.modelStream.makeAsyncIterator()

        Task {
            await runtime.start()
        }

        var history = [Int]()

        if let initialValue = await iterator.next() {
            history.append(initialValue)
        }

        await runtime.send(.increment)  // +1
        if let value = await iterator.next() {
            history.append(value)
        }

        await runtime.send(.decrement)  // -1
        if let value = await iterator.next() {
            history.append(value)
        }

        await runtime.send(.increment)  // +1
        if let value = await iterator.next() {
            history.append(value)
        }

        await runtime.send(.increment)  // +1
        if let value = await iterator.next() {
            history.append(value)
        }

        await runtime.send(.decrement)  // -1
        if let value = await iterator.next() {
            history.append(value)
        }

        #expect(history == [0, 1, 0, 1, 2, 1])

        await runtime.stop()
    }

    @Test func asyncCommand() async throws {
        let runtime = Runtime(program: SingleAsyncIncrement())
        var iterator = await runtime.modelStream.makeAsyncIterator()

        Task {
            await runtime.start()
        }

        _ = await iterator.next()  // runtime is initialized

        let afterAsync = await iterator.next()
        #expect(afterAsync == 1)

        await runtime.stop()
    }

    @Test func subscriptionReceivesMessages() async throws {
        let (forwardStream, forwardCont) = AsyncStream<SubscriptionCounter.Message>.makeStream()

        let program = SubscriptionCounter(isRunning: false) { _ in
            ["forward": forwardStream]
        }
        let runtime = Runtime(program: program)
        var iterator = await runtime.modelStream.makeAsyncIterator()

        Task {
            await runtime.start()
        }

        var history = [Int]()

        if let initialModel = await iterator.next() {
            history.append(initialModel.tickCount)
        }

        forwardCont.yield(.forwardTick)
        if let model = await iterator.next() {
            history.append(model.tickCount)
        }

        forwardCont.yield(.forwardTick)
        if let model = await iterator.next() {
            history.append(model.tickCount)
        }

        forwardCont.yield(.forwardTick)
        if let model = await iterator.next() {
            history.append(model.tickCount)
        }

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
        var iterator = await runtime.modelStream.makeAsyncIterator()

        Task {
            await runtime.start()
        }

        _ = await iterator.next()  // runtime is initialized

        await #expect(runtime.isSubscribed(to: "tick") == false)

        await runtime.send(.toggleRunning)
        _ = await iterator.next()  // subscription enabled
        await #expect(runtime.isSubscribed(to: "tick") == true)

        tickCont.yield(.forwardTick)
        _ = await iterator.next()
        await #expect(runtime.currentModel?.tickCount == 1)

        tickCont.yield(.forwardTick)
        _ = await iterator.next()
        await #expect(runtime.currentModel?.tickCount == 2)

        await runtime.send(.toggleRunning)
        _ = await iterator.next()  // subscription disabled
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
        var iterator = await runtime.modelStream.makeAsyncIterator()

        Task {
            await runtime.start()
        }

        _ = await iterator.next()  // runtime is initialized

        await #expect(runtime.isSubscribed(to: "stream") == true)

        forwardCont.yield(.forwardTick)
        _ = await iterator.next()
        await #expect(runtime.currentModel?.tickCount == 1)

        await runtime.send(.toggleDirection)
        _ = await iterator.next()  // toggled to backward, but forward continues (same ID)
        await #expect(runtime.currentModel?.tickCount == 1)

        forwardCont.yield(.forwardTick)
        _ = await iterator.next()
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
        var iterator = await runtime.modelStream.makeAsyncIterator()

        Task {
            await runtime.start()
        }

        _ = await iterator.next()  // runtime is initialized

        await #expect(runtime.isSubscribed(to: "forward") == true)
        await #expect(runtime.isSubscribed(to: "backward") == true)

        forwardCont.yield(.forwardTick)
        _ = await iterator.next()
        await #expect(runtime.currentModel?.tickCount == 1)

        backwardCont.yield(.backwardTick)
        _ = await iterator.next()
        await #expect(runtime.currentModel?.tickCount == 0)

        forwardCont.yield(.forwardTick)
        _ = await iterator.next()
        await #expect(runtime.currentModel?.tickCount == 1)

        backwardCont.yield(.backwardTick)
        _ = await iterator.next()
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
        var iterator = await runtime.modelStream.makeAsyncIterator()

        Task {
            await runtime.start()
        }

        _ = await iterator.next()  // runtime is initialized

        await #expect(runtime.isSubscribed(to: "forward") == true)
        await #expect(runtime.isSubscribed(to: "backward") == true)

        forwardCont.yield(.forwardTick)
        _ = await iterator.next()
        await #expect(runtime.currentModel?.tickCount == 1)

        backwardCont.yield(.backwardTick)
        _ = await iterator.next()
        await #expect(runtime.currentModel?.tickCount == 0)

        backwardCont.finish()

        forwardCont.yield(.forwardTick)
        _ = await iterator.next()
        await #expect(runtime.currentModel?.tickCount == 1)
        await #expect(runtime.isSubscribed(to: "backward") == false)

        await runtime.stop()
    }

    @Test @MainActor func uiRuntimeUpdatesModel() async throws {
        let uiRuntime = UIRuntime(program: Counter())

        uiRuntime.start()

        try await Task.sleep(for: .milliseconds(20))
        #expect(uiRuntime.currentModel == 0)

        uiRuntime.send(.increment)
        try await Task.sleep(for: .milliseconds(20))
        #expect(uiRuntime.currentModel == 1)
    }
}

private struct Counter: Component {
    typealias View = Never

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

private struct SingleAsyncIncrement: Component {
    typealias View = Never

    func initialize() -> (Int, Command<CounterMessage>) {
        (
            0,
            .task {
                try? await Task.sleep(for: .milliseconds(10))
                return .increment
            }
        )
    }

    func update(_ model: Int, with message: CounterMessage) -> (Model, Command<CounterMessage>) {
        switch message {
        case .increment:
            return (model + 1, .none)
        case .decrement:
            return (model - 1, .none)
        }
    }
}

private enum CounterMessage {
    case increment, decrement
}

private struct SubscriptionCounter: Component {
    typealias View = Never

    enum Message {
        case toggleRunning, toggleDirection
        case forwardTick, backwardTick
    }

    let isRunning: Bool
    let subscriptions: @Sendable (Model) -> [AnyHashable: AsyncStream<Message>]

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
