import SwiftUI

/// Describes a side effect that will produce a message when executed. Commands are created by
/// `initialize()` and `update()` functions and executed by the runtime.
enum Command<Message>: Sendable {
    /// Executes an async task and sends the resulting message back to the runtime.
    case task(@Sendable () async -> Message)

    /// Executes multiple commands concurrently.
    case batch([Command<Message>])

    /// Represents no side effect.
    case none
}

/// Defines the behavior of a TEA (The Elm Architecture) component. Components can be composed
/// together. The top-level component passed to runtime is called a program.
protocol Component: Sendable {
    /// Represents state transitions in the domain of the component.
    associatedtype Message: Sendable

    /// Represents the component's state data.
    associatedtype Model: Sendable

    /// Represents the component's visual interface.
    associatedtype View: SwiftUI.View

    /// Initial state of the component and initial command to be executed when the component starts.
    func initialize() -> (Model, Command<Message>)

    /// Describes the next state of the component based on the current state and the incoming message.
    func update(_ model: Model, with message: Message) -> (Model, Command<Message>)

    /// External event sources (timers, network streams, etc.) active for the current state. Returns
    /// a dictionary of unique subscription IDs to async streams. Subscriptions with the same ID
    /// across model updates continue running; new IDs start, removed IDs cancel.
    func subscriptions(_ model: Model) -> [AnyHashable: AsyncStream<Message>]

    /// Renders the component's state as a SwiftUI view.
    @ViewBuilder func view(model: Model, send: @escaping (Message) -> Void) -> View
}

extension Component {
    func subscriptions(_: Model) -> [AnyHashable: AsyncStream<Message>] { [:] }
}

extension Component where View == Never {
    func view(model: Model, send: @escaping (Message) -> Void) -> Never {
        fatalError("This component has no view")
    }
}

/// A runtime that executes a TEA program. Manages the program's lifecycle, model state, message
/// dispatch, and command execution.  The runtime processes messages from both external sources and
/// commands.
actor Runtime<Program: Component> {
    /// Program to be executed in the runtime.
    let program: Program

    /// The current state of the program's model. Updated after each message is processed.
    private(set) var currentModel: Program.Model?

    private let messageStream: AsyncStream<Program.Message>
    private let messageContinuation: AsyncStream<Program.Message>.Continuation

    private var currentSubscriptions = [AnyHashable: Task<Void, Never>]()

    /// Emits the current model after initialization and each state update.
    internal let modelStream: AsyncStream<Program.Model>
    private let modelContinuation: AsyncStream<Program.Model>.Continuation

    /// Creates a runtime for executing the given program.
    init(program: Program) {
        self.program = program

        let (messageStream, messageContinuation) = AsyncStream<Program.Message>.makeStream()
        self.messageStream = messageStream
        self.messageContinuation = messageContinuation

        let (modelStream, modelContinuation) = AsyncStream<Program.Model>.makeStream()
        self.modelStream = modelStream
        self.modelContinuation = modelContinuation
    }

    /// Starts the program execution. Initializes the model, executes the initial command, and
    /// begins the message processing loop.
    func start() async {
        let (model, command) = program.initialize()
        currentModel = model

        for (id, subscription) in program.subscriptions(model) {
            startSubscription(subscription, with: id)
        }

        modelContinuation.yield(model)

        await execute(command)
        await messageLoop()
    }

    private func startSubscription(
        _ subscription: AsyncStream<Program.Message>, with id: AnyHashable
    ) {
        currentSubscriptions[id] = Task {
            for await message in subscription {
                self.messageContinuation.yield(message)
            }
            currentSubscriptions.removeValue(forKey: id)
        }
    }

    private func execute(_ command: Command<Program.Message>) async {
        switch command {
        case let .task(thunk):
            let message = await thunk()
            await send(message)
        case let .batch(commands):
            await withTaskGroup(of: Void.self) { group in
                for command in commands {
                    group.addTask {
                        await self.execute(command)
                    }
                }
            }
        case .none:
            break
        }
    }

    private func messageLoop() async {
        for await message in messageStream {
            guard let model = currentModel else { continue }
            let (newModel, newCommand) = program.update(model, with: message)

            currentModel = newModel
            updateSubscriptions(newModel)
            modelContinuation.yield(newModel)

            await execute(newCommand)
        }
    }

    private func updateSubscriptions(_ newModel: Program.Model) {
        let newSubscriptions = program.subscriptions(newModel)

        let curIds = Set<AnyHashable>(currentSubscriptions.keys)
        let newIds = Set<AnyHashable>(newSubscriptions.keys)

        for id in curIds.subtracting(newIds) {
            currentSubscriptions.removeValue(forKey: id)?.cancel()
        }

        for (id, subscription) in newSubscriptions where currentSubscriptions[id] == nil {
            startSubscription(subscription, with: id)
        }
    }

    /// Forced termination of the program, cleans up resources.
    func stop() {
        messageContinuation.finish()
        modelContinuation.finish()

        for (_, subscription) in currentSubscriptions {
            subscription.cancel()
        }
    }

    /// Sends a message to the runtime. Can be used for external events such as timer fires, network
    /// callbacks, user interactions, etc.
    func send(_ message: Program.Message) async {
        messageContinuation.yield(message)
    }

    /// Checks if a subscription with the given ID is currently active.
    internal func isSubscribed(to id: AnyHashable) async -> Bool {
        currentSubscriptions[id] != nil
    }
}

/// Main-actor-isolated runtime wrapper for use as a SwiftUI view model.
@MainActor @Observable final class UIRuntime<Program: Component> {
    private let runtime: Runtime<Program>

    /// The program's current model state. Observable by SwiftUI views.
    private(set) var currentModel: Program.Model?

    /// Creates a UI runtime that executes and observes the given program.
    init(program: Program) {
        self.runtime = Runtime(program: program)

        Task { @MainActor in
            for await model in runtime.modelStream {
                self.currentModel = model
            }
        }
    }

    /// Starts runtime execution in the background.
    func start() {
        Task {
            await runtime.start()
        }
    }

    /// Stops runtime execution and cleans up resources.
    func stop() {
        Task {
            await runtime.stop()
        }
    }

    /// Dispatches a message to the runtime, triggering a state update.
    func send(_ message: Program.Message) {
        Task {
            await runtime.send(message)
        }
    }
}
