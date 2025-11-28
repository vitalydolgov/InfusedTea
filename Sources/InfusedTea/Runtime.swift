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
    associatedtype Message: Sendable
    associatedtype Model

    func initialize() -> (Model, Command<Message>)
    func update(_ model: Model, with message: Message) -> (Model, Command<Message>)
}

/// A runtime that executes a TEA program. Manages the program's lifecycle, model state, message
/// dispatch, and command execution.  The runtime processes messages from both external sources and
/// commands.
actor Runtime<P: Program> {
    /// Program to be executed in the runtime.
    let program: P

    /// The current state of the program's model. Updated after each message is processed.
    private(set) var currentModel: P.Model?

    /// Middleware function called after each model update, receiving the new model and command.
    typealias Middleware = (P.Model, Command<P.Message>) -> Void
    private var middlewares = [Middleware]()

    private let messageStream: AsyncStream<P.Message>
    private let messageContinuation: AsyncStream<P.Message>.Continuation

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
        await execute(command)

        for await message in messageStream {
            guard let model = currentModel else { continue }
            let (newModel, newCommand) = program.update(model, with: message)

            for middleware in middlewares {
                middleware(newModel, newCommand)
            }

            currentModel = newModel
            await execute(newCommand)
        }
    }

    /// Forced termination of the program, cleans up resources.
    func stop() {
        messageContinuation.finish()
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
}
