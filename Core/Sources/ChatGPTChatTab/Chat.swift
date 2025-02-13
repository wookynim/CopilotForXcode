import ChatService
import ComposableArchitecture
import Foundation
import OpenAIService
import Preferences

public struct ChatMessage: Equatable {
    public enum Role {
        case user
        case assistant
        case function
        case ignored
    }

    public var id: String
    public var role: Role
    public var text: String

    public init(id: String, role: Role, text: String) {
        self.id = id
        self.role = role
        self.text = text
    }
}

struct Chat: ReducerProtocol {
    public typealias MessageID = String

    struct State: Equatable {
        var title: String = "Chat"
        @BindingState var typedMessage = ""
        var history: [ChatMessage] = []
        @BindingState var isReceivingMessage = false
        var chatMenu = ChatMenu.State()
    }

    enum Action: Equatable, BindableAction {
        case binding(BindingAction<State>)

        case appear
        case sendButtonTapped
        case returnButtonTapped
        case stopRespondingButtonTapped
        case clearButtonTap
        case deleteMessageButtonTapped(MessageID)
        case resendMessageButtonTapped(MessageID)
        case setAsExtraPromptButtonTapped(MessageID)

        case observeChatService
        case observeHistoryChange
        case observeIsReceivingMessageChange
        case observeSystemPromptChange
        case observeExtraSystemPromptChange

        case historyChanged
        case isReceivingMessageChanged
        case systemPromptChanged
        case extraSystemPromptChanged

        case chatMenu(ChatMenu.Action)
    }

    let service: ChatService
    let id = UUID()

    enum CancelID: Hashable {
        case observeHistoryChange(UUID)
        case observeIsReceivingMessageChange(UUID)
        case observeSystemPromptChange(UUID)
        case observeExtraSystemPromptChange(UUID)
    }

    var body: some ReducerProtocol<State, Action> {
        BindingReducer()

        Scope(state: \.chatMenu, action: /Action.chatMenu) {
            ChatMenu(service: service)
        }

        Reduce { state, action in
            switch action {
            case .appear:
                return .run { send in
                    await send(.observeChatService)
                    await send(.historyChanged)
                    await send(.isReceivingMessageChanged)
                    await send(.systemPromptChanged)
                    await send(.extraSystemPromptChanged)
                }

            case .sendButtonTapped:
                guard !state.typedMessage.isEmpty else { return .none }
                let message = state.typedMessage
                state.typedMessage = ""
                return .run { _ in
                    try await service.send(content: message)
                }

            case .returnButtonTapped:
                state.typedMessage += "\n"
                return .none

            case .stopRespondingButtonTapped:
                return .run { _ in
                    await service.stopReceivingMessage()
                }

            case .clearButtonTap:
                return .run { _ in
                    await service.clearHistory()
                }

            case let .deleteMessageButtonTapped(id):
                return .run { _ in
                    await service.deleteMessage(id: id)
                }

            case let .resendMessageButtonTapped(id):
                return .run { _ in
                    try await service.resendMessage(id: id)
                }

            case let .setAsExtraPromptButtonTapped(id):
                return .run { _ in
                    await service.setMessageAsExtraPrompt(id: id)
                }

            case .observeChatService:
                return .run { send in
                    await send(.observeHistoryChange)
                    await send(.observeIsReceivingMessageChange)
                    await send(.observeSystemPromptChange)
                    await send(.observeExtraSystemPromptChange)
                }

            case .observeHistoryChange:
                return .run { send in
                    let stream = AsyncStream<Void> { continuation in
                        let cancellable = service.$chatHistory.sink { _ in
                            continuation.yield()
                        }
                        continuation.onTermination = { _ in
                            cancellable.cancel()
                        }
                    }
                    for await _ in stream {
                        await send(.historyChanged)
                    }
                }.cancellable(id: CancelID.observeHistoryChange(id), cancelInFlight: true)

            case .observeIsReceivingMessageChange:
                return .run { send in
                    let stream = AsyncStream<Void> { continuation in
                        let cancellable = service.$isReceivingMessage
                            .sink { _ in
                                continuation.yield()
                            }
                        continuation.onTermination = { _ in
                            cancellable.cancel()
                        }
                    }
                    for await _ in stream {
                        await send(.isReceivingMessageChanged)
                    }
                }.cancellable(
                    id: CancelID.observeIsReceivingMessageChange(id),
                    cancelInFlight: true
                )

            case .observeSystemPromptChange:
                return .run { send in
                    let stream = AsyncStream<Void> { continuation in
                        let cancellable = service.$systemPrompt.sink { _ in
                            continuation.yield()
                        }
                        continuation.onTermination = { _ in
                            cancellable.cancel()
                        }
                    }
                    for await _ in stream {
                        await send(.systemPromptChanged)
                    }
                }.cancellable(id: CancelID.observeSystemPromptChange(id), cancelInFlight: true)

            case .observeExtraSystemPromptChange:
                return .run { send in
                    let stream = AsyncStream<Void> { continuation in
                        let cancellable = service.$extraSystemPrompt
                            .sink { _ in
                                continuation.yield()
                            }
                        continuation.onTermination = { _ in
                            cancellable.cancel()
                        }
                    }
                    for await _ in stream {
                        await send(.extraSystemPromptChanged)
                    }
                }.cancellable(id: CancelID.observeExtraSystemPromptChange(id), cancelInFlight: true)

            case .historyChanged:
                state.history = service.chatHistory.map { message in
                    .init(
                        id: message.id,
                        role: {
                            switch message.role {
                            case .system: return .ignored
                            case .user: return .user
                            case .assistant:
                                if let text = message.summary ?? message.content,
                                   !text.isEmpty
                                {
                                    return .assistant
                                }
                                return .ignored
                            case .function: return .function
                            }
                        }(),
                        text: message.summary ?? message.content ?? ""
                    )
                }

                state.title = {
                    let defaultTitle = "Chat"
                    guard let lastMessageText = state.history
                        .filter({ $0.role == .assistant || $0.role == .user })
                        .last?
                        .text else { return defaultTitle }
                    if lastMessageText.isEmpty { return defaultTitle }
                    let trimmed = lastMessageText
                        .trimmingCharacters(in: .punctuationCharacters)
                        .trimmingCharacters(in: .whitespacesAndNewlines)
                    if trimmed.starts(with: "```") {
                        return "Code Block"
                    } else {
                        return trimmed
                    }
                }()
                return .none

            case .isReceivingMessageChanged:
                state.isReceivingMessage = service.isReceivingMessage
                return .none

            case .systemPromptChanged:
                state.chatMenu.systemPrompt = service.systemPrompt
                return .none

            case .extraSystemPromptChanged:
                state.chatMenu.extraSystemPrompt = service.extraSystemPrompt
                return .none

            case .binding:
                return .none

            case .chatMenu:
                return .none
            }
        }
    }
}

struct ChatMenu: ReducerProtocol {
    struct State: Equatable {
        var systemPrompt: String = ""
        var extraSystemPrompt: String = ""
        var temperatureOverride: Double? = nil
        var chatModelIdOverride: String? = nil
    }

    enum Action: Equatable {
        case appear
        case resetPromptButtonTapped
        case temperatureOverrideSelected(Double?)
        case chatModelIdOverrideSelected(String?)
        case customCommandButtonTapped(CustomCommand)
    }

    let service: ChatService

    var body: some ReducerProtocol<State, Action> {
        Reduce { state, action in
            switch action {
            case .appear:
                state.temperatureOverride = service.configuration.overriding.temperature
                state.chatModelIdOverride = service.configuration.overriding.modelId
                return .none

            case .resetPromptButtonTapped:
                return .run { _ in
                    await service.resetPrompt()
                }
            case let .temperatureOverrideSelected(temperature):
                state.temperatureOverride = temperature
                return .run { _ in
                    service.configuration.overriding.temperature = temperature
                }
            case let .chatModelIdOverrideSelected(chatModelId):
                state.chatModelIdOverride = chatModelId
                return .run { _ in
                    service.configuration.overriding.modelId = chatModelId
                }
            case let .customCommandButtonTapped(command):
                return .run { _ in
                    try await service.handleCustomCommand(command)
                }
            }
        }
    }
}

