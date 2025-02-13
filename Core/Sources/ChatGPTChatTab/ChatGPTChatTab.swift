import ChatService
import ChatTab
import Combine
import ComposableArchitecture
import Foundation
import OpenAIService
import Preferences
import SwiftUI

/// A chat tab that provides a context aware chat bot, powered by ChatGPT.
public class ChatGPTChatTab: ChatTab {
    public static var name: String { "Chat" }

    public let service: ChatService
    let chat: StoreOf<Chat>
    let viewStore: ViewStoreOf<Chat>
    private var cancellable = Set<AnyCancellable>()

    struct RestorableState: Codable {
        var history: [OpenAIService.ChatMessage]
        var configuration: OverridingChatGPTConfiguration.Overriding
        var systemPrompt: String
        var extraSystemPrompt: String
    }

    struct Builder: ChatTabBuilder {
        var title: String
        var customCommand: CustomCommand?
        var afterBuild: (ChatGPTChatTab) async -> Void = { _ in }

        func build(store: StoreOf<ChatTabItem>) async -> (any ChatTab)? {
            let tab = await ChatGPTChatTab(store: store)
            if let customCommand {
                try? await tab.service.handleCustomCommand(customCommand)
            }
            await afterBuild(tab)
            return tab
        }
    }

    public func buildView() -> any View {
        ChatPanel(chat: chat)
    }

    public func buildTabItem() -> any View {
        ChatTabItemView(chat: chat)
    }

    public func buildMenu() -> any View {
        ChatContextMenu(store: chat.scope(state: \.chatMenu, action: Chat.Action.chatMenu))
    }

    public func restorableState() async -> Data {
        let state = RestorableState(
            history: await service.memory.history,
            configuration: service.configuration.overriding,
            systemPrompt: service.systemPrompt,
            extraSystemPrompt: service.extraSystemPrompt
        )
        return (try? JSONEncoder().encode(state)) ?? Data()
    }

    public static func restore(
        from data: Data,
        externalDependency: Void
    ) async throws -> any ChatTabBuilder {
        let state = try JSONDecoder().decode(RestorableState.self, from: data)
        let builder = Builder(title: "Chat") { @MainActor tab in
            tab.service.configuration.overriding = state.configuration
            tab.service.mutateSystemPrompt(state.systemPrompt)
            tab.service.mutateExtraSystemPrompt(state.extraSystemPrompt)
            await tab.service.memory.mutateHistory { history in
                history = state.history
            }
        }
        return builder
    }

    public static func chatBuilders(externalDependency: Void) -> [ChatTabBuilder] {
        let customCommands = UserDefaults.shared.value(for: \.customCommands).compactMap {
            command in
            if case .customChat = command.feature {
                return Builder(title: command.name, customCommand: command)
            }
            return nil
        }

        return [Builder(title: "New Chat", customCommand: nil)] + customCommands
    }

    @MainActor
    public init(service: ChatService = .init(), store: StoreOf<ChatTabItem>) {
        self.service = service
        chat = .init(initialState: .init(), reducer: Chat(service: service))
        viewStore = .init(chat)
        super.init(store: store)
    }

    public func start() {
        chatTabViewStore.send(.updateTitle("Chat"))

        service.$systemPrompt.removeDuplicates().sink { _ in
            Task { @MainActor [weak self] in
                self?.chatTabViewStore.send(.tabContentUpdated)
            }
        }.store(in: &cancellable)

        service.$extraSystemPrompt.removeDuplicates().sink { _ in
            Task { @MainActor [weak self] in
                self?.chatTabViewStore.send(.tabContentUpdated)
            }
        }.store(in: &cancellable)

        viewStore.publisher.map(\.title).removeDuplicates().sink { [weak self] title in
            Task { @MainActor [weak self] in
                self?.chatTabViewStore.send(.updateTitle(title))
            }
        }.store(in: &cancellable)

        viewStore.publisher.removeDuplicates()
            .sink { [weak self] _ in
                Task { @MainActor [weak self] in
                    self?.chatTabViewStore.send(.tabContentUpdated)
                }
            }.store(in: &cancellable)
    }
}
