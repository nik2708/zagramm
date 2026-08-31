import Foundation
import UIKit
import Display
import AsyncDisplayKit
import SwiftSignalKit
import TelegramCore
import Postbox
import TelegramPresentationData
import ItemListUI
import AccountContext
import PresentationDataUtils
import ComponentFlow
import SliderComponent
import AlertUI

private let minDeletedMessageTransparencyPercent: Int32 = Int32(AntiDeleteManager.minDeletedMessageTransparency * 100.0)
private let maxDeletedMessageTransparencyPercent: Int32 = Int32(AntiDeleteManager.maxDeletedMessageTransparency * 100.0)

private func clampDeletedMessageTransparencyPercent(_ value: Int32) -> Int32 {
    return max(minDeletedMessageTransparencyPercent, min(maxDeletedMessageTransparencyPercent, value))
}

// MARK: - Entry Definition

private enum DeletedMessagesSection: Int32 {
    case settings
}

private enum DeletedMessagesEntry: ItemListNodeEntry {
    case enableToggle(PresentationTheme, String, Bool)
    case archiveMediaToggle(PresentationTheme, String, Bool)
    case fetchMissingMediaToggle(PresentationTheme, String, Bool)
    case history(PresentationTheme, String, String)
    case markInput(PresentationTheme, String, String)
    case transparencySlider(PresentationTheme, Int32, Bool)
    case settingsInfo(PresentationTheme, String)

    var section: ItemListSectionId {
        return DeletedMessagesSection.settings.rawValue
    }

    var stableId: Int32 {
        switch self {
        case .enableToggle:
            return 0
        case .archiveMediaToggle:
            return 1
        case .history:
            return 2
        case .markInput:
            return 3
        case .fetchMissingMediaToggle:
            return 4
        case .transparencySlider:
            return 5
        case .settingsInfo:
            return 6
        }
    }
    
    static func ==(lhs: DeletedMessagesEntry, rhs: DeletedMessagesEntry) -> Bool {
        switch lhs {
        case let .enableToggle(lhsTheme, lhsText, lhsValue):
            if case let .enableToggle(rhsTheme, rhsText, rhsValue) = rhs,
               lhsTheme === rhsTheme, lhsText == rhsText, lhsValue == rhsValue {
                return true
            }
            return false
        case let .archiveMediaToggle(lhsTheme, lhsText, lhsValue):
            if case let .archiveMediaToggle(rhsTheme, rhsText, rhsValue) = rhs,
               lhsTheme === rhsTheme, lhsText == rhsText, lhsValue == rhsValue {
                return true
            }
            return false
        case let .history(lhsTheme, lhsText, lhsValue):
            if case let .history(rhsTheme, rhsText, rhsValue) = rhs,
               lhsTheme === rhsTheme, lhsText == rhsText, lhsValue == rhsValue {
                return true
            }
            return false
        case let .markInput(lhsTheme, lhsText, lhsValue):
            if case let .markInput(rhsTheme, rhsText, rhsValue) = rhs,
               lhsTheme === rhsTheme, lhsText == rhsText, lhsValue == rhsValue {
                return true
            }
            return false
        case let .fetchMissingMediaToggle(lhsTheme, lhsText, lhsValue):
            if case let .fetchMissingMediaToggle(rhsTheme, rhsText, rhsValue) = rhs,
               lhsTheme === rhsTheme, lhsText == rhsText, lhsValue == rhsValue {
                return true
            }
            return false
        case let .transparencySlider(lhsTheme, lhsValue, lhsIsEnabled):
            if case let .transparencySlider(rhsTheme, rhsValue, rhsIsEnabled) = rhs,
               lhsTheme === rhsTheme, lhsValue == rhsValue, lhsIsEnabled == rhsIsEnabled {
                return true
            }
            return false
        case let .settingsInfo(lhsTheme, lhsText):
            if case let .settingsInfo(rhsTheme, rhsText) = rhs, lhsTheme === rhsTheme, lhsText == rhsText {
                return true
            }
            return false
        }
    }
    
    static func <(lhs: DeletedMessagesEntry, rhs: DeletedMessagesEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }
    
    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! DeletedMessagesControllerArguments
        switch self {
        case let .enableToggle(_, text, value):
            return ItemListSwitchItem(
                presentationData: presentationData,
                title: text,
                value: value,
                sectionId: self.section,
                style: .blocks,
                updated: { value in
                    arguments.toggleEnabled(value)
                }
            )
        case let .archiveMediaToggle(_, text, value):
            return ItemListSwitchItem(
                presentationData: presentationData,
                title: text,
                value: value,
                sectionId: self.section,
                style: .blocks,
                updated: { value in
                    arguments.toggleArchiveMedia(value)
                }
            )
        case let .history(_, text, value):
            return ItemListDisclosureItem(
                presentationData: presentationData,
                title: text,
                label: value,
                sectionId: self.section,
                style: .blocks,
                action: {
                    arguments.openHistory()
                }
            )
        case let .fetchMissingMediaToggle(_, text, value):
            return ItemListSwitchItem(
                presentationData: presentationData,
                title: text,
                value: value,
                sectionId: self.section,
                style: .blocks,
                updated: { value in
                    arguments.toggleFetchMissingMedia(value)
                }
            )
        case let .markInput(_, text, value):
            return ItemListSingleLineInputItem(
                presentationData: presentationData,
                title: NSAttributedString(string: text, textColor: presentationData.theme.list.itemPrimaryTextColor),
                text: value,
                placeholder: "🗑️",
                type: .regular(capitalization: false, autocorrection: false),
                maxLength: 8,
                sectionId: self.section,
                textUpdated: { value in
                    arguments.updateMarkText(value)
                },
                action: {}
            )
        case let .transparencySlider(theme, value, isEnabled):
            return DeletedMessagesTransparencySliderItem(
                theme: theme,
                value: value,
                isEnabled: isEnabled,
                sectionId: self.section,
                updated: { value in
                    arguments.updateTransparency(value)
                }
            )
        case let .settingsInfo(_, text):
            return ItemListTextItem(presentationData: presentationData, text: .plain(text), sectionId: self.section)
        }
    }
}

// MARK: - Arguments

private final class DeletedMessagesControllerArguments {
    let toggleEnabled: (Bool) -> Void
    let toggleArchiveMedia: (Bool) -> Void
    let toggleFetchMissingMedia: (Bool) -> Void
    let openHistory: () -> Void
    let updateMarkText: (String) -> Void
    let updateTransparency: (Int32) -> Void

    init(
        toggleEnabled: @escaping (Bool) -> Void,
        toggleArchiveMedia: @escaping (Bool) -> Void,
        toggleFetchMissingMedia: @escaping (Bool) -> Void,
        openHistory: @escaping () -> Void,
        updateMarkText: @escaping (String) -> Void,
        updateTransparency: @escaping (Int32) -> Void
    ) {
        self.toggleEnabled = toggleEnabled
        self.toggleArchiveMedia = toggleArchiveMedia
        self.toggleFetchMissingMedia = toggleFetchMissingMedia
        self.openHistory = openHistory
        self.updateMarkText = updateMarkText
        self.updateTransparency = updateTransparency
    }
}

// MARK: - State

private struct DeletedMessagesControllerState: Equatable {
    var isEnabled: Bool
    var archiveMedia: Bool
    var fetchMissingMedia: Bool
    var archivedCount: Int
    var markText: String
    var transparencyPercent: Int32

    static func ==(lhs: DeletedMessagesControllerState, rhs: DeletedMessagesControllerState) -> Bool {
        return lhs.isEnabled == rhs.isEnabled &&
               lhs.archiveMedia == rhs.archiveMedia &&
               lhs.fetchMissingMedia == rhs.fetchMissingMedia &&
               lhs.archivedCount == rhs.archivedCount &&
               lhs.markText == rhs.markText &&
               lhs.transparencyPercent == rhs.transparencyPercent
    }
}

// MARK: - Entries builder

private func deletedMessagesControllerEntries(
    presentationData: PresentationData,
    state: DeletedMessagesControllerState
) -> [DeletedMessagesEntry] {
    var entries: [DeletedMessagesEntry] = []
    
    entries.append(.enableToggle(presentationData.theme, "Сохранять удалённые сообщения", state.isEnabled))
    entries.append(.archiveMediaToggle(presentationData.theme, "Архивировать медиа", state.archiveMedia))
    entries.append(.fetchMissingMediaToggle(presentationData.theme, "Докачивать медиа при удалении", state.fetchMissingMedia))
    entries.append(.history(presentationData.theme, "История удалений", state.archivedCount == 0 ? "Пусто" : "\(state.archivedCount)"))
    entries.append(.markInput(presentationData.theme, "Метка удалённых", state.markText))
    entries.append(.transparencySlider(presentationData.theme, state.transparencyPercent, state.isEnabled))
    entries.append(.settingsInfo(presentationData.theme, "Когда включено, сообщения, удалённые другими пользователями, будут сохраняться локально. «Архивировать медиа» копирует медиа в защищённую папку, «докачивать» — скачивает ещё не загруженные файлы в момент удаления. История переживает очистку кэша и хранится в SQLite-базе. Метка показывается рядом с удалёнными сообщениями."))
    
    return entries
}

// MARK: - Controller

public func deletedMessagesController(context: AccountContext) -> ViewController {
    var pushControllerImpl: ((ViewController, Bool) -> Void)?
    
    let initialState = DeletedMessagesControllerState(
        isEnabled: AntiDeleteManager.shared.isEnabled,
        archiveMedia: AntiDeleteManager.shared.archiveMedia,
        fetchMissingMedia: AntiDeleteManager.shared.fetchMissingMedia,
        archivedCount: AntiDeleteManager.shared.archivedCount,
        markText: AntiDeleteManager.shared.deletedMarkText,
        transparencyPercent: clampDeletedMessageTransparencyPercent(Int32(round(AntiDeleteManager.shared.deletedMessageTransparency * 100.0)))
    )
    
    let statePromise = ValuePromise(initialState, ignoreRepeated: true)
    let stateValue = Atomic(value: initialState)
    let updateState: ((DeletedMessagesControllerState) -> DeletedMessagesControllerState) -> Void = { f in
        statePromise.set(stateValue.modify { f($0) })
    }
    
    let arguments = DeletedMessagesControllerArguments(
        toggleEnabled: { value in
            AntiDeleteManager.shared.isEnabled = value
            updateState { state in
                var state = state
                state.isEnabled = value
                return state
            }
        },
        toggleArchiveMedia: { value in
            AntiDeleteManager.shared.archiveMedia = value
            updateState { state in
                var state = state
                state.archiveMedia = value
                return state
            }
        },
        toggleFetchMissingMedia: { value in
            AntiDeleteManager.shared.fetchMissingMedia = value
            updateState { state in
                var state = state
                state.fetchMissingMedia = value
                return state
            }
        },
        openHistory: {
            pushControllerImpl?(deletedMessagesHistoryController(context: context), true)
        },
        updateMarkText: { value in
            AntiDeleteManager.shared.deletedMarkText = value
            updateState { state in
                var state = state
                state.markText = value
                return state
            }
        },
        updateTransparency: { value in
            let clampedValue = clampDeletedMessageTransparencyPercent(value)
            AntiDeleteManager.shared.deletedMessageTransparency = Double(clampedValue) / 100.0
            updateState { state in
                var state = state
                state.transparencyPercent = clampedValue
                return state
            }
        }
    )
    
    let signal = combineLatest(
        context.sharedContext.presentationData,
        statePromise.get()
    )
    |> map { presentationData, state -> (ItemListControllerState, (ItemListNodeState, Any)) in
        let entries = deletedMessagesControllerEntries(presentationData: presentationData, state: state)
        
        let controllerState = ItemListControllerState(
            presentationData: ItemListPresentationData(presentationData),
            title: .text("Удалённые сообщения"),
            leftNavigationButton: nil,
            rightNavigationButton: nil,
            backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back),
            animateChanges: false
        )
        
        let listState = ItemListNodeState(
            presentationData: ItemListPresentationData(presentationData),
            entries: entries,
            style: .blocks,
            animateChanges: false
        )
        
        return (controllerState, (listState, arguments))
    }
    
    let controller = ItemListController(context: context, state: signal)
    controller.didAppear = { _ in
        updateState { state in
            var state = state
            state.isEnabled = AntiDeleteManager.shared.isEnabled
            state.archiveMedia = AntiDeleteManager.shared.archiveMedia
            state.fetchMissingMedia = AntiDeleteManager.shared.fetchMissingMedia
            state.archivedCount = AntiDeleteManager.shared.archivedCount
            state.markText = AntiDeleteManager.shared.deletedMarkText
            state.transparencyPercent = clampDeletedMessageTransparencyPercent(Int32(round(AntiDeleteManager.shared.deletedMessageTransparency * 100.0)))
            return state
        }
    }
    pushControllerImpl = { [weak controller] c, _ in
        controller?.push(c)
    }
    return controller
}

// MARK: - Deleted History

private enum DeletedMessagesHistorySection: Int32 {
    case actions
    case messages
}

private enum DeletedMessagesHistoryEntry: ItemListNodeEntry {
    case clear(PresentationTheme, Bool)
    case message(PresentationTheme, Int32, String, String)
    case empty(PresentationTheme, String)
    
    var section: ItemListSectionId {
        switch self {
        case .clear:
            return DeletedMessagesHistorySection.actions.rawValue
        case .message, .empty:
            return DeletedMessagesHistorySection.messages.rawValue
        }
    }
    
    var stableId: Int32 {
        switch self {
        case .clear:
            return 0
        case let .message(_, index, _, _):
            return 1000 + index
        case .empty:
            return 1
        }
    }
    
    static func ==(lhs: DeletedMessagesHistoryEntry, rhs: DeletedMessagesHistoryEntry) -> Bool {
        switch lhs {
        case let .clear(lhsTheme, lhsEnabled):
            if case let .clear(rhsTheme, rhsEnabled) = rhs, lhsTheme === rhsTheme, lhsEnabled == rhsEnabled {
                return true
            }
            return false
        case let .message(lhsTheme, lhsIndex, lhsTitle, lhsLabel):
            if case let .message(rhsTheme, rhsIndex, rhsTitle, rhsLabel) = rhs, lhsTheme === rhsTheme, lhsIndex == rhsIndex, lhsTitle == rhsTitle, lhsLabel == rhsLabel {
                return true
            }
            return false
        case let .empty(lhsTheme, lhsText):
            if case let .empty(rhsTheme, rhsText) = rhs, lhsTheme === rhsTheme, lhsText == rhsText {
                return true
            }
            return false
        }
    }
    
    static func <(lhs: DeletedMessagesHistoryEntry, rhs: DeletedMessagesHistoryEntry) -> Bool {
        return lhs.stableId < rhs.stableId
    }
    
    func item(presentationData: ItemListPresentationData, arguments: Any) -> ListViewItem {
        let arguments = arguments as! DeletedMessagesHistoryControllerArguments
        
        switch self {
        case let .clear(_, enabled):
            return ItemListActionItem(
                presentationData: presentationData,
                systemStyle: .glass,
                title: "Очистить историю",
                kind: enabled ? .destructive : .disabled,
                alignment: .natural,
                sectionId: self.section,
                style: .blocks,
                action: {
                    if enabled {
                        arguments.clearHistory()
                    }
                }
            )
        case let .message(_, _, title, label):
            return ItemListTextItem(
                presentationData: presentationData,
                text: .plain("\(label)\n\(title)"),
                sectionId: self.section
            )
        case let .empty(_, text):
            return ItemListTextItem(
                presentationData: presentationData,
                text: .plain(text),
                sectionId: self.section
            )
        }
    }
}

private final class DeletedMessagesHistoryControllerArguments {
    let clearHistory: () -> Void
    
    init(clearHistory: @escaping () -> Void) {
        self.clearHistory = clearHistory
    }
}

private struct DeletedMessagesHistoryControllerState: Equatable {
    var messages: [AntiDeleteManager.ArchivedMessage]
    
    static func ==(lhs: DeletedMessagesHistoryControllerState, rhs: DeletedMessagesHistoryControllerState) -> Bool {
        if lhs.messages.count != rhs.messages.count {
            return false
        }
        for (lhsMessage, rhsMessage) in zip(lhs.messages, rhs.messages) {
            if lhsMessage.globalId != rhsMessage.globalId ||
                lhsMessage.peerId != rhsMessage.peerId ||
                lhsMessage.messageId != rhsMessage.messageId ||
                lhsMessage.timestamp != rhsMessage.timestamp ||
                lhsMessage.deletedAt != rhsMessage.deletedAt ||
                lhsMessage.authorId != rhsMessage.authorId ||
                lhsMessage.text != rhsMessage.text ||
                lhsMessage.forwardAuthorId != rhsMessage.forwardAuthorId ||
                lhsMessage.mediaDescription != rhsMessage.mediaDescription {
                return false
            }
        }
        return true
    }
}

private func deletedMessagesHistoryDateString(timestamp: Int32) -> String {
    let formatter = DateFormatter()
    formatter.locale = Locale.current
    formatter.dateStyle = .short
    formatter.timeStyle = .medium
    return formatter.string(from: Date(timeIntervalSince1970: TimeInterval(timestamp)))
}

private func deletedMessagesHistoryEntries(
    presentationData: PresentationData,
    state: DeletedMessagesHistoryControllerState
) -> [DeletedMessagesHistoryEntry] {
    var entries: [DeletedMessagesHistoryEntry] = []
    entries.append(.clear(presentationData.theme, !state.messages.isEmpty))
    
    if state.messages.isEmpty {
        entries.append(.empty(presentationData.theme, "История удалений пуста."))
        return entries
    }
    
    for (index, message) in state.messages.enumerated() {
        var preview = message.text.trimmingCharacters(in: .whitespacesAndNewlines)
        if preview.isEmpty {
            preview = message.mediaDescription ?? "Сообщение без текста"
        }
        preview = preview.replacingOccurrences(of: "\n", with: " ")
        if preview.count > 80 {
            preview = String(preview.prefix(80)) + "..."
        }
        
        let mark = AntiDeleteManager.shared.deletedMarkText
        let mediaFlag = message.mediaPath != nil ? " 📎" : ""
        let title = "\(mark) Чат \(message.peerId): \(preview)\(mediaFlag)"
        let label = deletedMessagesHistoryDateString(timestamp: message.deletedAt)
        
        entries.append(.message(presentationData.theme, Int32(index), title, label))
    }
    
    return entries
}

private func deletedMessagesHistoryController(context: AccountContext) -> ViewController {
    var presentControllerImpl: ((ViewController, ViewControllerPresentationArguments?) -> Void)?
    
    let initialState = DeletedMessagesHistoryControllerState(
        messages: AntiDeleteManager.shared.getAllArchivedMessages()
    )
    
    let statePromise = ValuePromise(initialState, ignoreRepeated: true)
    let stateValue = Atomic(value: initialState)
    let updateState: ((DeletedMessagesHistoryControllerState) -> DeletedMessagesHistoryControllerState) -> Void = { f in
        statePromise.set(stateValue.modify { f($0) })
    }
    
    let arguments = DeletedMessagesHistoryControllerArguments(
        clearHistory: {
            let presentationData = context.sharedContext.currentPresentationData.with { $0 }
            let alert = textAlertController(
                context: context,
                title: "Очистить историю?",
                text: "Это удалит локально сохранённые удалённые сообщения.",
                actions: [
                    TextAlertAction(type: .genericAction, title: presentationData.strings.Common_Cancel, action: {}),
                    TextAlertAction(type: .destructiveAction, title: "Очистить", action: {
                        AntiDeleteManager.shared.clearArchive()
                        updateState { state in
                            var state = state
                            state.messages = AntiDeleteManager.shared.getAllArchivedMessages()
                            return state
                        }
                    })
                ]
            )
            presentControllerImpl?(alert, nil)
        }
    )
    
    let signal: Signal<(ItemListControllerState, (ItemListNodeState, DeletedMessagesHistoryControllerArguments)), NoError> = combineLatest(
        context.sharedContext.presentationData,
        statePromise.get()
    )
    |> map { presentationData, state -> (ItemListControllerState, (ItemListNodeState, DeletedMessagesHistoryControllerArguments)) in
        let entries = deletedMessagesHistoryEntries(presentationData: presentationData, state: state)
        
        let controllerState = ItemListControllerState(
            presentationData: ItemListPresentationData(presentationData),
            title: .text("История удалений"),
            leftNavigationButton: nil,
            rightNavigationButton: nil,
            backNavigationButton: ItemListBackButton(title: presentationData.strings.Common_Back),
            animateChanges: false
        )
        
        let listState = ItemListNodeState(
            presentationData: ItemListPresentationData(presentationData),
            entries: entries,
            style: .blocks,
            animateChanges: false
        )
        
        return (controllerState, (listState, arguments))
    }
    
    let controller = ItemListController(context: context, state: signal)
    controller.didAppear = { _ in
        updateState { state in
            var state = state
            state.messages = AntiDeleteManager.shared.getAllArchivedMessages()
            return state
        }
    }
    presentControllerImpl = { [weak controller] c, a in
        controller?.present(c, in: .window(.root), with: a)
    }
    return controller
}

private final class DeletedMessagesTransparencySliderItem: ListViewItem, ItemListItem {
    let theme: PresentationTheme
    let value: Int32
    let isEnabled: Bool
    let sectionId: ItemListSectionId
    let updated: (Int32) -> Void
    
    init(theme: PresentationTheme, value: Int32, isEnabled: Bool, sectionId: ItemListSectionId, updated: @escaping (Int32) -> Void) {
        self.theme = theme
        self.value = clampDeletedMessageTransparencyPercent(value)
        self.isEnabled = isEnabled
        self.sectionId = sectionId
        self.updated = updated
    }
    
    func nodeConfiguredForParams(async: @escaping (@escaping () -> Void) -> Void, params: ListViewItemLayoutParams, synchronousLoads: Bool, previousItem: ListViewItem?, nextItem: ListViewItem?, completion: @escaping (ListViewItemNode, @escaping () -> (Signal<Void, NoError>?, (ListViewItemApply) -> Void)) -> Void) {
        async {
            let node = DeletedMessagesTransparencySliderItemNode()
            let (layout, apply) = node.asyncLayout()(self, params, itemListNeighbors(item: self, topItem: previousItem as? ItemListItem, bottomItem: nextItem as? ItemListItem))
            
            node.contentSize = layout.contentSize
            node.insets = layout.insets
            
            Queue.mainQueue().async {
                completion(node, {
                    return (nil, { _ in apply() })
                })
            }
        }
    }
    
    func updateNode(async: @escaping (@escaping () -> Void) -> Void, node: @escaping () -> ListViewItemNode, params: ListViewItemLayoutParams, previousItem: ListViewItem?, nextItem: ListViewItem?, animation: ListViewItemUpdateAnimation, completion: @escaping (ListViewItemNodeLayout, @escaping (ListViewItemApply) -> Void) -> Void) {
        Queue.mainQueue().async {
            if let nodeValue = node() as? DeletedMessagesTransparencySliderItemNode {
                let makeLayout = nodeValue.asyncLayout()
                
                async {
                    let (layout, apply) = makeLayout(self, params, itemListNeighbors(item: self, topItem: previousItem as? ItemListItem, bottomItem: nextItem as? ItemListItem))
                    Queue.mainQueue().async {
                        completion(layout, { _ in
                            apply()
                        })
                    }
                }
            }
        }
    }
}

private final class DeletedMessagesTransparencySliderItemNode: ListViewItemNode {
    private let backgroundNode: ASDisplayNode
    private let topStripeNode: ASDisplayNode
    private let bottomStripeNode: ASDisplayNode
    private let maskNode: ASImageNode
    
    private let leftTextNode: ImmediateTextNode
    private let rightTextNode: ImmediateTextNode
    private let centerTextNode: ImmediateTextNode
    private let slider = ComponentView<Empty>()
    
    private var item: DeletedMessagesTransparencySliderItem?
    
    init() {
        self.backgroundNode = ASDisplayNode()
        self.backgroundNode.isLayerBacked = true
        
        self.topStripeNode = ASDisplayNode()
        self.topStripeNode.isLayerBacked = true
        
        self.bottomStripeNode = ASDisplayNode()
        self.bottomStripeNode.isLayerBacked = true
        
        self.maskNode = ASImageNode()
        
        self.leftTextNode = ImmediateTextNode()
        self.rightTextNode = ImmediateTextNode()
        self.centerTextNode = ImmediateTextNode()
        
        super.init(layerBacked: false)
        
        self.addSubnode(self.leftTextNode)
        self.addSubnode(self.rightTextNode)
        self.addSubnode(self.centerTextNode)
    }
    
    func asyncLayout() -> (_ item: DeletedMessagesTransparencySliderItem, _ params: ListViewItemLayoutParams, _ neighbors: ItemListNeighbors) -> (ListViewItemNodeLayout, () -> Void) {
        return { item, params, neighbors in
            let separatorHeight = UIScreenPixel
            let contentSize = CGSize(width: params.width, height: 88.0)
            let insets = itemListNeighborsGroupedInsets(neighbors, params)
            
            let layout = ListViewItemNodeLayout(contentSize: contentSize, insets: insets)
            let layoutSize = layout.size
            
            return (layout, { [weak self] in
                guard let strongSelf = self else {
                    return
                }
                
                strongSelf.item = item
                
                strongSelf.backgroundNode.backgroundColor = item.theme.list.itemBlocksBackgroundColor
                strongSelf.topStripeNode.backgroundColor = item.theme.list.itemBlocksSeparatorColor
                strongSelf.bottomStripeNode.backgroundColor = item.theme.list.itemBlocksSeparatorColor
                
                if strongSelf.backgroundNode.supernode == nil {
                    strongSelf.insertSubnode(strongSelf.backgroundNode, at: 0)
                }
                if strongSelf.topStripeNode.supernode == nil {
                    strongSelf.insertSubnode(strongSelf.topStripeNode, at: 1)
                }
                if strongSelf.bottomStripeNode.supernode == nil {
                    strongSelf.insertSubnode(strongSelf.bottomStripeNode, at: 2)
                }
                if strongSelf.maskNode.supernode == nil {
                    strongSelf.insertSubnode(strongSelf.maskNode, at: 3)
                }
                
                let hasCorners = itemListHasRoundedBlockLayout(params)
                var hasTopCorners = false
                var hasBottomCorners = false
                
                switch neighbors.top {
                case .sameSection(false):
                    strongSelf.topStripeNode.isHidden = true
                default:
                    hasTopCorners = true
                    strongSelf.topStripeNode.isHidden = hasCorners
                }
                
                let bottomStripeInset: CGFloat
                let bottomStripeOffset: CGFloat
                switch neighbors.bottom {
                case .sameSection(false):
                    bottomStripeInset = 0.0
                    bottomStripeOffset = -separatorHeight
                    strongSelf.bottomStripeNode.isHidden = false
                default:
                    bottomStripeInset = 0.0
                    bottomStripeOffset = 0.0
                    hasBottomCorners = true
                    strongSelf.bottomStripeNode.isHidden = hasCorners
                }
                
                strongSelf.maskNode.image = hasCorners ? PresentationResourcesItemList.cornersImage(item.theme, top: hasTopCorners, bottom: hasBottomCorners) : nil
                
                strongSelf.backgroundNode.frame = CGRect(origin: CGPoint(x: 0.0, y: -min(insets.top, separatorHeight)), size: CGSize(width: params.width, height: contentSize.height + min(insets.top, separatorHeight) + min(insets.bottom, separatorHeight)))
                strongSelf.maskNode.frame = strongSelf.backgroundNode.frame.insetBy(dx: params.leftInset, dy: 0.0)
                strongSelf.topStripeNode.frame = CGRect(origin: CGPoint(x: 0.0, y: -min(insets.top, separatorHeight)), size: CGSize(width: layoutSize.width, height: separatorHeight))
                strongSelf.bottomStripeNode.frame = CGRect(origin: CGPoint(x: bottomStripeInset, y: contentSize.height + bottomStripeOffset), size: CGSize(width: layoutSize.width - bottomStripeInset, height: separatorHeight))
                
                let sideTextColor = item.theme.list.itemSecondaryTextColor.withAlphaComponent(item.isEnabled ? 1.0 : 0.6)
                let centerTextColor = item.isEnabled ? item.theme.list.itemPrimaryTextColor : item.theme.list.itemDisabledTextColor
                
                strongSelf.leftTextNode.attributedText = NSAttributedString(string: "Меньше", font: Font.regular(13.0), textColor: sideTextColor)
                strongSelf.rightTextNode.attributedText = NSAttributedString(string: "Больше", font: Font.regular(13.0), textColor: sideTextColor)
                strongSelf.centerTextNode.attributedText = NSAttributedString(string: "Прозрачность \(item.value)%", font: Font.regular(16.0), textColor: centerTextColor)
                
                let leftTextSize = strongSelf.leftTextNode.updateLayout(CGSize(width: 120.0, height: 100.0))
                let rightTextSize = strongSelf.rightTextNode.updateLayout(CGSize(width: 120.0, height: 100.0))
                let centerTextSize = strongSelf.centerTextNode.updateLayout(CGSize(width: params.width - params.leftInset - params.rightInset - 60.0, height: 100.0))
                
                let sideInset: CGFloat = 18.0
                strongSelf.leftTextNode.frame = CGRect(origin: CGPoint(x: params.leftInset + sideInset, y: 15.0), size: leftTextSize)
                strongSelf.rightTextNode.frame = CGRect(origin: CGPoint(x: params.width - params.leftInset - sideInset - rightTextSize.width, y: 15.0), size: rightTextSize)
                strongSelf.centerTextNode.frame = CGRect(origin: CGPoint(x: floorToScreenPixels((params.width - centerTextSize.width) / 2.0), y: 11.0), size: centerTextSize)
                
                let maxRange = CGFloat(maxDeletedMessageTransparencyPercent - minDeletedMessageTransparencyPercent)
                let normalizedValue: CGFloat
                if maxRange.isZero {
                    normalizedValue = 0.0
                } else {
                    normalizedValue = CGFloat(item.value - minDeletedMessageTransparencyPercent) / maxRange
                }
                
                let sliderSize = strongSelf.slider.update(
                    transition: .immediate,
                    component: AnyComponent(
                        SliderComponent(
                            content: .continuous(.init(
                                value: normalizedValue,
                                minValue: nil,
                                valueUpdated: { [weak self] value in
                                    guard let self, let item = self.item, item.isEnabled else {
                                        return
                                    }
                                    
                                    let transparencyValue = Int32((CGFloat(minDeletedMessageTransparencyPercent) + maxRange * value).rounded())
                                    item.updated(clampDeletedMessageTransparencyPercent(transparencyValue))
                                }
                            )),
                            useNative: true,
                            trackBackgroundColor: item.theme.list.itemSwitchColors.frameColor,
                            trackForegroundColor: item.isEnabled ? item.theme.list.itemAccentColor : item.theme.list.itemDisabledTextColor
                        )
                    ),
                    environment: {},
                    containerSize: CGSize(width: params.width - params.leftInset - params.rightInset - 15.0 * 2.0, height: 44.0)
                )
                
                if let sliderView = strongSelf.slider.view {
                    if sliderView.superview == nil {
                        strongSelf.view.addSubview(sliderView)
                    }
                    
                    sliderView.frame = CGRect(origin: CGPoint(x: floorToScreenPixels((params.width - sliderSize.width) / 2.0), y: 36.0), size: sliderSize)
                    sliderView.isUserInteractionEnabled = item.isEnabled
                    sliderView.alpha = item.isEnabled ? 1.0 : 0.55
                }
            })
        }
    }
    
    override func animateInsertion(_ currentTimestamp: Double, duration: Double, options: ListViewItemAnimationOptions) {
        self.layer.animateAlpha(from: 0.0, to: 1.0, duration: 0.2)
    }
    
    override func animateRemoved(_ currentTimestamp: Double, duration: Double) {
        self.layer.animateAlpha(from: 1.0, to: 0.0, duration: 0.15, removeOnCompletion: false)
    }
}
