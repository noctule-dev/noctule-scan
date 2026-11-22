// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

#if os(macOS)
import AppKit
import NoctuleAppCore
import NoctuleKit
import SwiftUI
import Testing
@testable import NoctuleScan

/// The Mac-style menu's entry field (fix round 2): what it shows is always the sanitized draft,
/// whatever is typed or pasted, while its field editor is active.
@MainActor @Suite(.serialized, .timeLimit(.minutes(3))) struct MenuEntryFieldTests {
    private let number = MenuScreen.InputRules(maxLength: 5, allowedCharacters: "0123456789.", addedInformation: "(mile)")
    private let name = MenuScreen.InputRules(maxLength: 12, allowedCharacters: "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789 ,")

    @Test func sanitizedEditKeepsTheCaretWhereTheTypingWas() {
        // A refused letter typed after "30.0": the text and caret go back.
        var edit = MenuEntryField.sanitizedEdit("30.0x", selection: NSRange(location: 5, length: 0), rules: number)
        #expect(edit.text == "30.0")
        #expect(edit.selection == NSRange(location: 4, length: 0))
        // A comma typed in the middle of a name (allowed by EnableKeys, never by MenuInput).
        edit = MenuEntryField.sanitizedEdit("Cus,tom", selection: NSRange(location: 4, length: 0), rules: name)
        #expect(edit.text == "Custom")
        #expect(edit.selection == NSRange(location: 3, length: 0))
        // A paste past MaxLength is cut to it.
        edit = MenuEntryField.sanitizedEdit("123456789", selection: NSRange(location: 9, length: 0), rules: number)
        #expect(edit.text == "12345")
        #expect(edit.selection == NSRange(location: 5, length: 0))
        // Nothing refused: unchanged.
        edit = MenuEntryField.sanitizedEdit("30.5", selection: NSRange(location: 2, length: 0), rules: number)
        #expect(edit.text == "30.5")
        #expect(edit.selection == NSRange(location: 2, length: 0))
    }

    @Test func filteredReplacementDecidesBeforeTheEdit() {
        func decide(_ current: String, _ location: Int, _ length: Int, _ replacement: String,
                    _ rules: MenuScreen.InputRules) -> MenuEntryField.Replacement {
            MenuEntryField.filteredReplacement(current: current, range: NSRange(location: location, length: length),
                                               replacement: replacement, rules: rules)
        }
        #expect(decide("30.0", 4, 0, "5", number) == .accept)
        #expect(decide("30.05", 2, 0, "1", number) == .refuse, "no room at MaxLength, even in the middle")
        #expect(decide("30.0", 4, 0, "x", number) == .refuse, "a refused letter")
        #expect(decide("30.05", 0, 5, "1234567890", number) == .replace("12345"), "a paste cut to MaxLength")
        #expect(decide("30.0", 4, 0, "7a8", number) == .replace("7"), "allowed characters that fit")
        #expect(decide("30.05", 4, 1, "", number) == .accept, "deleting")
        #expect(decide("Custom 9", 8, 0, ",", name) == .refuse, "a comma, though EnableKeys lists it")
        #expect(decide("Custom 9", 8, 0, "A,B", name) == .replace("AB"))
        #expect(decide("Custom 9", 8, 0, "\r\n", name) == .refuse)
        #expect(decide("30.0", 9, 0, "1", number) == .refuse, "a range outside the text")
    }

    final class KeyWindow: NSWindow {
        override var isKeyWindow: Bool { true }
        override var canBecomeKey: Bool { true }
    }

    final class Box {
        var draft = ""; var submits = 0; var cancels = 0; var focus: [Bool] = []
        /// What `MacMenuActions.save` would have sent: the draft, when it is valid.
        var sent: [String] = []
        var changes = 0
    }

    /// Types through the real field editor (`insertText`, as the keyboard does) and checks after
    /// every step that the field shows exactly the draft.
    @Test func theFieldShowsOnlyTheSanitizedDraft() throws {
        _ = NSApplication.shared
        let window = KeyWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 60), styleMask: [.titled],
                               backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        defer { window.close() }
        let box = Box()
        box.draft = "30.0"
        func field(_ rules: MenuScreen.InputRules) -> MenuEntryField {
            MenuEntryField(text: box.draft, rules: rules, onChange: { box.draft = $0 }, onSubmit: { box.submits += 1 },
                           onCancel: { box.cancels += 1 }, onFocusChange: { box.focus.append($0) })
        }
        let host = NSHostingView(rootView: field(number))
        host.frame = NSRect(x: 0, y: 0, width: 300, height: 60)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
        let textField = try #require(all(host).compactMap { $0 as? NSTextField }.first)
        #expect(window.makeFirstResponder(textField))
        let editor = try #require(textField.currentEditor() as? NSTextView)
        #expect(box.focus.last == true, "focus reported")

        func type(_ text: String) {
            editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
            editor.insertText(text, replacementRange: editor.selectedRange())
        }
        func shows() -> String { editor.string }

        type("5")
        #expect(shows() == "30.05" && box.draft == "30.05")
        type("x")
        #expect(shows() == "30.05", "a refused letter isn't shown")
        #expect(box.draft == "30.05")
        type("7")
        #expect(shows() == "30.05", "past MaxLength isn't shown")
        #expect(box.draft == "30.05")
        editor.selectAll(nil)
        editor.insertText("123456789", replacementRange: editor.selectedRange())
        #expect(shows() == "12345", "a long paste is cut to MaxLength")
        #expect(box.draft == "12345")

        // The name field: a comma never shows.
        box.draft = "Custom 9"
        host.rootView = field(name)
        host.layoutSubtreeIfNeeded()
        #expect(shows() == "Custom 9", "a new draft from outside replaces the text")
        type(",")
        #expect(shows() == "Custom 9")
        #expect(box.draft == "Custom 9")
        type("A")
        #expect(shows() == "Custom 9A" && box.draft == "Custom 9A")

        // Return submits once, Esc cancels once.
        editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        editor.doCommand(by: #selector(NSResponder.cancelOperation(_:)))
        #expect(box.submits == 1)
        #expect(box.cancels == 1)

        // Focus leaving is reported.
        #expect(window.makeFirstResponder(nil))
        #expect(box.focus.last == false)
    }

    // MARK: Undo (fix round 3)

    struct Hosted {
        let window: NSWindow
        let host: NSHostingView<MenuEntryField>
        let textField: NSTextField
        let editor: NSTextView
    }

    /// The field wired the way `MacMenuView` wires it: `onChange` sets the sanitized draft
    /// (`MacMenuState.setDraft`), and a submit sends the draft when it is valid (`MacMenuActions.save`).
    private func entry(_ box: Box, rules: MenuScreen.InputRules) -> MenuEntryField {
        MenuEntryField(
            text: box.draft, rules: rules,
            onChange: { box.changes += 1; box.draft = MenuInput.sanitize($0, rules: rules) },
            onSubmit: {
                box.submits += 1
                if MenuInput.isValid(box.draft, rules: rules) { box.sent.append(box.draft) }
            },
            onCancel: { box.cancels += 1 }, onFocusChange: { box.focus.append($0) })
    }

    private func hosted(_ box: Box, rules: MenuScreen.InputRules) throws -> Hosted {
        _ = NSApplication.shared
        let window = KeyWindow(contentRect: NSRect(x: 0, y: 0, width: 300, height: 60), styleMask: [.titled],
                               backing: .buffered, defer: false)
        window.isReleasedWhenClosed = false
        let host = NSHostingView(rootView: entry(box, rules: rules))
        host.frame = NSRect(x: 0, y: 0, width: 300, height: 60)
        window.contentView = host
        host.layoutSubtreeIfNeeded()
        func all(_ view: NSView) -> [NSView] { [view] + view.subviews.flatMap(all) }
        let textField = try #require(all(host).compactMap { $0 as? NSTextField }.first)
        #expect(window.makeFirstResponder(textField))
        let editor = try #require(textField.currentEditor() as? NSTextView)
        return Hosted(window: window, host: host, textField: textField, editor: editor)
    }

    /// The re-review's sequence: typing in the middle at MaxLength, a refused letter, Undo, Undo,
    /// Redo. Before the fix the field editor's undo threw `NSRangeException` (an exception a Swift
    /// test can't catch: the process dies). After every step the field shows the draft.
    @Test func undoAfterRefusedEditsIsSafe() throws {
        let box = Box()
        box.draft = "30.0"
        let h = try hosted(box, rules: number)
        defer { h.window.close() }
        let editor = h.editor
        let undo = try #require(editor.undoManager)

        editor.setSelectedRange(NSRange(location: 4, length: 0))
        editor.insertText("5", replacementRange: editor.selectedRange())
        #expect(editor.string == "30.05" && box.draft == "30.05")
        // In the middle at MaxLength: the keystroke is refused, nothing is dropped, the caret stays.
        editor.setSelectedRange(NSRange(location: 2, length: 0))
        editor.insertText("1", replacementRange: editor.selectedRange())
        #expect(editor.string == "30.05", "a keystroke past MaxLength is refused, not the last character dropped")
        #expect(box.draft == "30.05")
        #expect(editor.selectedRange() == NSRange(location: 2, length: 0))
        // A refused letter.
        editor.insertText("x", replacementRange: editor.selectedRange())
        #expect(editor.string == "30.05" && box.draft == "30.05")
        #expect(editor.selectedRange() == NSRange(location: 2, length: 0))

        undo.undo()
        #expect(editor.string == box.draft, "after Undo: field \(editor.string), draft \(box.draft)")
        #expect(editor.string == "30.0", "Undo takes back the accepted 5")
        undo.undo()
        #expect(editor.string == box.draft, "after a second Undo: field \(editor.string), draft \(box.draft)")
        undo.redo()
        #expect(editor.string == box.draft, "after Redo: field \(editor.string), draft \(box.draft)")
        #expect(MenuInput.isValid(editor.string, rules: number) || editor.string.isEmpty)
    }

    /// A paste with refused characters keeps the allowed ones; Undo takes the paste back.
    @Test func undoAfterAFilteredPasteIsSafe() throws {
        let box = Box()
        box.draft = "Custom 9"
        let h = try hosted(box, rules: name)
        defer { h.window.close() }
        let editor = h.editor
        let undo = try #require(editor.undoManager)
        editor.setSelectedRange(NSRange(location: 8, length: 0))
        editor.insertText("A,B", replacementRange: editor.selectedRange())
        #expect(editor.string == "Custom 9AB" && box.draft == "Custom 9AB")
        #expect(editor.selectedRange() == NSRange(location: 10, length: 0))
        undo.undo()
        #expect(editor.string == box.draft, "after Undo: field \(editor.string), draft \(box.draft)")
        #expect(editor.string == "Custom 9")
        undo.redo()
        #expect(editor.string == box.draft, "after Redo: field \(editor.string), draft \(box.draft)")

        // A new draft from outside (a new entry screen), then Undo: nothing throws, field == draft.
        box.draft = "Custom 3"
        h.host.rootView = MenuEntryField(
            text: box.draft, rules: name, onChange: { box.draft = $0 }, onSubmit: {}, onCancel: {}, onFocusChange: { _ in })
        h.host.layoutSubtreeIfNeeded()
        #expect(editor.string == "Custom 3")
        undo.undo()
        #expect(editor.string == box.draft, "after Undo past an outside draft: field \(editor.string), draft \(box.draft)")
    }

    /// Input-method marked text isn't filtered while composing; on commit it is sanitized, and an
    /// Undo afterwards can't bring the unsanitized text back.
    @Test func committedMarkedTextIsSanitizedAndUndoIsSafe() throws {
        let box = Box()
        box.draft = "9."
        let h = try hosted(box, rules: number)
        defer { h.window.close() }
        let editor = h.editor
        editor.setSelectedRange(NSRange(location: 2, length: 0))
        editor.setMarkedText("q", selectedRange: NSRange(location: 1, length: 0), replacementRange: editor.selectedRange())
        #expect(box.draft == "9.", "composing text isn't the draft")
        editor.insertText("q", replacementRange: editor.markedRange())
        #expect(editor.string == "9." && box.draft == "9.")
        try #require(editor.undoManager).undo()
        #expect(editor.string == box.draft, "after Undo: field \(editor.string), draft \(box.draft)")
        #expect(MenuInput.isValid(editor.string, rules: number))
    }

    // MARK: The field and the draft never part (fix round 4)

    /// What the field shows: its editor's text while it is being edited, else its own value.
    private func shown(_ h: Hosted) -> String {
        (h.textField.currentEditor() as? NSTextView)?.string ?? h.textField.stringValue
    }

    /// Field == draft, and a submit (Return in the field) sends exactly what the field shows when
    /// that is valid, and nothing otherwise.
    private func expectInStep(_ h: Hosted, _ box: Box, rules: MenuScreen.InputRules, _ step: String,
                              sourceLocation: SourceLocation = #_sourceLocation) {
        let text = shown(h)
        #expect(text == box.draft, "\(step): field \"\(text)\", draft \"\(box.draft)\"", sourceLocation: sourceLocation)
        let before = box.sent.count
        if let editor = h.textField.currentEditor() as? NSTextView {
            editor.doCommand(by: #selector(NSResponder.insertNewline(_:)))
        } else if MenuInput.isValid(box.draft, rules: rules) {
            // No editor: the Save button, which sends the draft.
            box.sent.append(box.draft)
        }
        let sent = box.sent.count > before ? box.sent.last : nil
        let expected: String? = MenuInput.isValid(text, rules: rules) ? text : nil
        #expect(sent == expected, "\(step): a submit sent \(sent ?? "nothing"), the field shows \"\(text)\"",
                sourceLocation: sourceLocation)
    }

    /// Focus leaves, a new entry screen sets the draft from outside, focus comes back.
    private func outsideDraftWhileUnfocused(_ h: Hosted, _ box: Box, _ draft: String, rules: MenuScreen.InputRules,
                                            sourceLocation: SourceLocation = #_sourceLocation) throws -> NSTextView {
        #expect(h.window.makeFirstResponder(nil), sourceLocation: sourceLocation)
        expectInStep(h, box, rules: rules, "focus left", sourceLocation: sourceLocation)
        box.draft = draft
        h.host.rootView = entry(box, rules: rules)
        h.host.layoutSubtreeIfNeeded()
        expectInStep(h, box, rules: rules, "outside draft, unfocused", sourceLocation: sourceLocation)
        #expect(h.window.makeFirstResponder(h.textField), sourceLocation: sourceLocation)
        let editor = try #require(h.textField.currentEditor() as? NSTextView, sourceLocation: sourceLocation)
        expectInStep(h, box, rules: rules, "refocused", sourceLocation: sourceLocation)
        return editor
    }

    /// QA's first reproduction: the field last reported "", a draft "12" arrives while it is
    /// unfocused, then select all + delete. The field showed "" while Return sent "12".
    @Test func emptiedAfterAnOutsideDraftWhileUnfocused() throws {
        let box = Box()
        box.draft = "5"
        let h = try hosted(box, rules: number)
        defer { h.window.close() }
        h.editor.selectAll(nil)
        h.editor.deleteBackward(nil)
        expectInStep(h, box, rules: number, "emptied")
        let editor = try outsideDraftWhileUnfocused(h, box, "12", rules: number)
        editor.selectAll(nil)
        editor.deleteBackward(nil)
        #expect(editor.string == "")
        let sentBefore = box.sent.count
        expectInStep(h, box, rules: number, "select all + delete")
        #expect(box.sent.count == sentBefore, "an empty field sends nothing: \(box.sent)")
    }

    /// QA's second: the field last reported "7", the outside draft is "30.0", then one keystroke
    /// makes the text "7" again. Return sent "30.0".
    @Test func oneKeystrokeAfterAnOutsideDraftWhileUnfocused() throws {
        let box = Box()
        box.draft = ""
        let h = try hosted(box, rules: number)
        defer { h.window.close() }
        h.editor.insertText("7", replacementRange: h.editor.selectedRange())
        expectInStep(h, box, rules: number, "typed 7")
        let editor = try outsideDraftWhileUnfocused(h, box, "30.0", rules: number)
        editor.selectAll(nil)
        editor.insertText("7", replacementRange: editor.selectedRange())
        #expect(editor.string == "7")
        expectInStep(h, box, rules: number, "select all, typed 7")
        #expect(box.sent.last == "7")
    }

    /// QA's third: the field last reported "30.05", the outside draft is "12", then a paste makes
    /// the text "30.05" again. Return sent "12".
    @Test func pasteAfterAnOutsideDraftWhileUnfocused() throws {
        let box = Box()
        box.draft = "30.0"
        let h = try hosted(box, rules: number)
        defer { h.window.close() }
        h.editor.setSelectedRange(NSRange(location: 4, length: 0))
        h.editor.insertText("5", replacementRange: h.editor.selectedRange())
        expectInStep(h, box, rules: number, "typed 5")
        let editor = try outsideDraftWhileUnfocused(h, box, "12", rules: number)
        editor.selectAll(nil)
        editor.insertText("30.05x", replacementRange: editor.selectedRange())
        #expect(editor.string == "30.05")
        expectInStep(h, box, rules: number, "select all, pasted 30.05x")
        #expect(box.sent.last == "30.05")
    }

    /// The same staleness while focused: an outside draft, then an edit back to the text last
    /// reported, then Undo and Redo across it.
    @Test func editBackToTheLastReportedTextAfterAnOutsideDraftWhileFocused() throws {
        let box = Box()
        box.draft = ""
        let h = try hosted(box, rules: number)
        defer { h.window.close() }
        let editor = h.editor
        editor.insertText("7", replacementRange: editor.selectedRange())
        expectInStep(h, box, rules: number, "typed 7")
        box.changes = 0
        box.draft = "30.0"
        h.host.rootView = entry(box, rules: number)
        h.host.layoutSubtreeIfNeeded()
        #expect(box.changes == 0, "showing a draft from outside reports nothing back (it would set state during a view update)")
        expectInStep(h, box, rules: number, "outside draft, focused")
        editor.selectAll(nil)
        editor.insertText("7", replacementRange: editor.selectedRange())
        expectInStep(h, box, rules: number, "select all, typed 7")
        try #require(editor.undoManager).undo()
        expectInStep(h, box, rules: number, "Undo")
        try #require(editor.undoManager).redo()
        expectInStep(h, box, rules: number, "Redo")
    }

    /// A draft from the scanner that breaks the screen's own rules (too long) is shown as it is and
    /// is never sent; writing it into the field must not change the draft behind the user's back.
    @Test func anOutsideDraftThatBreaksTheRulesIsShownAndNeverSent() throws {
        let box = Box()
        box.draft = "30.0"
        let h = try hosted(box, rules: number)
        defer { h.window.close() }
        let editor = h.editor
        box.changes = 0
        box.draft = "123456789"
        h.host.rootView = entry(box, rules: number)
        h.host.layoutSubtreeIfNeeded()
        #expect(box.changes == 0, "showing a draft from outside reports nothing back")
        expectInStep(h, box, rules: number, "outside draft over MaxLength, focused")
        // The first edit brings the text inside the rules, in the field and the draft alike.
        editor.setSelectedRange(NSRange(location: 9, length: 0))
        editor.deleteBackward(nil)
        expectInStep(h, box, rules: number, "deleted one character")
        #expect(MenuInput.isValid(editor.string, rules: number))
        try #require(editor.undoManager).undo()
        expectInStep(h, box, rules: number, "Undo")

        // The same while unfocused, then focus.
        let again = try outsideDraftWhileUnfocused(h, box, "1234567", rules: number)
        again.setSelectedRange(NSRange(location: 7, length: 0))
        again.insertText("8", replacementRange: again.selectedRange())
        expectInStep(h, box, rules: number, "typed 8 past MaxLength")
    }

    /// Focus leaving while an input method is still composing commits the composition; what is
    /// left in the field is the draft.
    @Test func focusLeavingWhileComposingLeavesTheDraftInTheField() throws {
        let box = Box()
        box.draft = "9."
        let h = try hosted(box, rules: number)
        defer { h.window.close() }
        let editor = h.editor
        editor.setSelectedRange(NSRange(location: 2, length: 0))
        editor.setMarkedText("q", selectedRange: NSRange(location: 1, length: 0), replacementRange: editor.selectedRange())
        #expect(h.window.makeFirstResponder(nil))
        expectInStep(h, box, rules: number, "focus left while composing")
        // And with a composition the rules allow.
        #expect(h.window.makeFirstResponder(h.textField))
        let again = try #require(h.textField.currentEditor() as? NSTextView)
        again.setSelectedRange(NSRange(location: (again.string as NSString).length, length: 0))
        again.setMarkedText("5", selectedRange: NSRange(location: 1, length: 0), replacementRange: again.selectedRange())
        #expect(h.window.makeFirstResponder(nil))
        expectInStep(h, box, rules: number, "focus left while composing an allowed character")
    }

    /// A composition can also end without a commit through `insertText` (`unmarkText`: the input
    /// source changes, or the input context is told to discard its marked text).
    @Test func aCompositionEndedWithoutACommitLeavesTheDraftInTheField() throws {
        let box = Box()
        box.draft = "9."
        let h = try hosted(box, rules: number)
        defer { h.window.close() }
        let editor = h.editor
        editor.setSelectedRange(NSRange(location: 2, length: 0))
        editor.setMarkedText("q", selectedRange: NSRange(location: 1, length: 0), replacementRange: editor.selectedRange())
        editor.unmarkText()
        #expect(!editor.hasMarkedText())
        expectInStep(h, box, rules: number, "unmarked a refused character")
        editor.setSelectedRange(NSRange(location: (editor.string as NSString).length, length: 0))
        editor.setMarkedText("5", selectedRange: NSRange(location: 1, length: 0), replacementRange: editor.selectedRange())
        editor.unmarkText()
        expectInStep(h, box, rules: number, "unmarked an allowed character")
    }

    /// Consecutive entry screens reuse the view: the rules change with the draft, focused or not.
    @Test func consecutiveEntryScreensReuseTheField() throws {
        let box = Box()
        box.draft = "30.0"
        let h = try hosted(box, rules: number)
        defer { h.window.close() }
        let editor = h.editor
        box.draft = "Custom 9"
        h.host.rootView = entry(box, rules: name)
        h.host.layoutSubtreeIfNeeded()
        expectInStep(h, box, rules: name, "name screen, focused")
        editor.setSelectedRange(NSRange(location: 8, length: 0))
        editor.insertText("A", replacementRange: editor.selectedRange())
        expectInStep(h, box, rules: name, "typed A")
        #expect(h.window.makeFirstResponder(nil))
        box.draft = "30.0"
        h.host.rootView = entry(box, rules: number)
        h.host.layoutSubtreeIfNeeded()
        expectInStep(h, box, rules: number, "number screen, unfocused")
        #expect(h.window.makeFirstResponder(h.textField))
        let again = try #require(h.textField.currentEditor() as? NSTextView)
        again.setSelectedRange(NSRange(location: 4, length: 0))
        again.insertText("A", replacementRange: again.selectedRange())
        expectInStep(h, box, rules: number, "typed A (refused by the number rules)")
        again.insertText("5", replacementRange: again.selectedRange())
        expectInStep(h, box, rules: number, "typed 5")
        #expect(box.sent.last == "30.05")
    }
}
#endif
