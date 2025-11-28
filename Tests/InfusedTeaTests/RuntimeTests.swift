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

        Task {
            await runtime.start()
        }

        try await Task.sleep(for: .milliseconds(10))
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

        Task {
            await runtime.start()
        }

        await runtime.send(.increment) // +1
        await runtime.send(.decrement) // -1
        await runtime.send(.increment) // +1
        await runtime.send(.increment) // +1
        await runtime.send(.decrement) // -1

        try await Task.sleep(for: .milliseconds(50))
        #expect(history == [1, 0, 1, 2, 1])

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

        try await Task.sleep(for: .milliseconds(50))
        #expect(history == [1, 2, 3])

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
