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

/// Defines the behavior of a TEA (The Elm Architecture) program.
protocol Program {
    /// Represents state transitions in the domain of the program.
    associatedtype Message: Sendable

    /// Represents the program's state data.
    associatedtype Model

    /// Initial state of the program and initial command to be executed when the program starts.
    func initialize() -> (Model, Command<Message>)

    /// Describes the next state of the program based on the current state and the incoming message.
    func update(_ model: Model, with message: Message) -> (Model, Command<Message>)

    /// External event sources (timers, network streams, etc.) active for the current state. Returns
    /// a dictionary of unique subscription IDs to async streams. Subscriptions with the same ID
    /// across model updates continue running; new IDs start, removed IDs cancel.
    func subscriptions(_ model: Model) -> [AnyHashable: AsyncStream<Message>]
}

extension Program {
    func subscriptions(_: Model) -> [AnyHashable: AsyncStream<Message>] { [:] }
}

/// A runtime that executes a TEA program. Manages the program's lifecycle, model state, message
/// dispatch, and command execution.  The runtime processes messages from both external sources and
/// commands.
actor Runtime<P: Program> {
    /// Program to be executed in the runtime.
    let program: P

    /// The current state of the program's model. Updated after each message is processed.
    private(set) var currentModel: P.Model?

    /// Middleware function called on initialization and after each model update, receiving the new
    /// model and command.
    typealias Middleware = (P.Model, Command<P.Message>) -> Void
    private var middlewares = [Middleware]()

    private let messageStream: AsyncStream<P.Message>
    private let messageContinuation: AsyncStream<P.Message>.Continuation

    private var currentSubscriptions = [AnyHashable: Task<Void, Never>]()

    init(program: P) {
        self.program = program

        let (messageStream, messageContinuation) = AsyncStream<P.Message>.makeStream()
        self.messageStream = messageStream
        self.messageContinuation = messageContinuation
    }

    /// Starts the program execution. Initializes the model, executes the initial command, and
    /// begins the message processing loop.
    func start() async {
        let (model, command) = program.initialize()
        currentModel = model

        for (id, subscription) in program.subscriptions(model) {
            startSubscription(subscription, with: id)
        }

        for middleware in middlewares {
            middleware(model, command)
        }

        await execute(command)
        await messageLoop()
    }

    private func startSubscription(_ subscription: AsyncStream<P.Message>, with id: AnyHashable) {
        currentSubscriptions[id] = Task {
            for await message in subscription {
                self.messageContinuation.yield(message)
            }
            currentSubscriptions.removeValue(forKey: id)
        }
    }

    private func execute(_ command: Command<P.Message>) async {
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

            for middleware in middlewares {
                middleware(newModel, newCommand)
            }

            await execute(newCommand)
        }
    }

    private func updateSubscriptions(_ newModel: P.Model) {
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

        for (_, subscription) in currentSubscriptions {
            subscription.cancel()
        }
    }

    /// Registers middleware to observe model updates and commands during program execution.
    /// Useful for logging, debugging, and testing.
    func use(middleware: @escaping Middleware) {
        middlewares.append(middleware)
    }

    /// Sends a message to the runtime. Can be used for external events such as timer fires, network
    /// callbacks, user interactions, etc.
    func send(_ message: P.Message) async {
        messageContinuation.yield(message)
    }

    /// Checks if a subscription with the given ID is currently active.
    internal func isSubscribed(to id: AnyHashable) async -> Bool {
        currentSubscriptions[id] != nil
    }
}
