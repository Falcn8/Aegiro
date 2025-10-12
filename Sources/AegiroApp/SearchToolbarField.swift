import SwiftUI
import AppKit

struct SearchToolbarField: NSViewRepresentable {
    @Binding var text: String
    var savedSearches: [SavedSearch]
    var onSubmit: (String) -> Void
    var onSelectSaved: (SavedSearch) -> Void

    func makeCoordinator() -> Coordinator {
        Coordinator(parent: self)
    }

    func makeNSView(context: Context) -> NSSearchField {
        let searchField = NSSearchField(frame: .zero)
        searchField.delegate = context.coordinator
        searchField.target = context.coordinator
        searchField.action = #selector(Coordinator.performSearch(_:))
        searchField.placeholderString = "Search"
        searchField.sendsWholeSearchString = true
        searchField.recentsAutosaveName = "aegiro.search.recents"
        searchField.searchMenuTemplate = context.coordinator.buildMenu(savedSearches: savedSearches)
        searchField.controlSize = .small
        searchField.focusRingType = .default
        searchField.stringValue = text
        context.coordinator.searchField = searchField
        return searchField
    }

    func updateNSView(_ nsView: NSSearchField, context: Context) {
        if nsView.stringValue != text {
            nsView.stringValue = text
        }
        nsView.searchMenuTemplate = context.coordinator.buildMenu(savedSearches: savedSearches)
        context.coordinator.parent = self
        context.coordinator.searchField = nsView
    }

    final class Coordinator: NSObject, NSSearchFieldDelegate {
        var parent: SearchToolbarField
        weak var searchField: NSSearchField?

        init(parent: SearchToolbarField) {
            self.parent = parent
        }

        func controlTextDidChange(_ obj: Notification) {
            guard let field = obj.object as? NSSearchField else { return }
            parent.text = field.stringValue
        }

        @objc func performSearch(_ sender: NSSearchField) {
            parent.text = sender.stringValue
            parent.onSubmit(sender.stringValue)
        }

        @objc func insertToken(_ sender: NSMenuItem) {
            guard let token = sender.representedObject as? String,
                  let field = searchField else { return }
            let insertion = token + " "
            if let editor = field.currentEditor() {
                let range = editor.selectedRange
                let current = field.stringValue as NSString
                let newString = current.replacingCharacters(in: range, with: insertion)
                field.stringValue = newString
                editor.selectedRange = NSRange(location: range.location + insertion.count, length: 0)
            } else {
                field.stringValue += insertion
            }
            parent.text = field.stringValue
            parent.onSubmit(field.stringValue)
        }

        @objc func selectSavedSearch(_ sender: NSMenuItem) {
            guard let saved = sender.representedObject as? SavedSearch,
                  let field = searchField else { return }
            field.stringValue = saved.query
            parent.text = saved.query
            parent.onSelectSaved(saved)
        }

        func buildMenu(savedSearches: [SavedSearch]) -> NSMenu {
            let menu = NSMenu()

            let header = NSMenuItem()
            header.title = "Search Tokens"
            header.isEnabled = false
            menu.addItem(header)

            menu.addItem(tokenItem(title: "Name", token: "name:", icon: "person.text.rectangle"))
            menu.addItem(tokenItem(title: "Kind", token: "kind:", icon: "doc.text"))
            menu.addItem(tokenItem(title: "Tag", token: "tag:", icon: "tag"))

            if !savedSearches.isEmpty {
                menu.addItem(.separator())
                let savedHeader = NSMenuItem()
                savedHeader.title = "Saved Filters"
                savedHeader.isEnabled = false
                menu.addItem(savedHeader)
                for saved in savedSearches {
                    let item = NSMenuItem(title: saved.name, action: #selector(selectSavedSearch(_:)), keyEquivalent: "")
                    item.representedObject = saved
                    item.target = self
                    menu.addItem(item)
                }
            }

            return menu
        }

        private func tokenItem(title: String, token: String, icon: String) -> NSMenuItem {
            let item = NSMenuItem(title: "\(title)…", action: #selector(insertToken(_:)), keyEquivalent: "")
            item.representedObject = token
            item.target = self
            if #available(macOS 11.0, *) {
                item.image = NSImage(systemSymbolName: icon, accessibilityDescription: nil)
            }
            return item
        }
    }
}
