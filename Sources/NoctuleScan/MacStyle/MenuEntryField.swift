// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

#if os(macOS)
import AppKit
import NoctuleAppCore
import NoctuleKit
import SwiftUI

/// The Mac-style menu's entry field: an AppKit `NSTextField` that always shows exactly the
/// sanitized text (`MenuInput.sanitize`). A SwiftUI `TextField` whose binding declines an edit
/// keeps showing the refused characters while its field editor is active, so the scanner could be
/// sent something other than what the user sees (Plan 6 Task 5, fix round 2).
///
/// Each edit is filtered *before* the field editor applies it (`filteredReplacement`, from the
/// field editor's `shouldChangeTextIn`): an edit that keeps the text valid goes through; one that
/// would add nothing allowed (a refused letter, a comma, a keystroke at `MaxLength`) doesn't
/// happen; a paste is cut to its allowed characters that fit, applied as one undoable insert.
/// So the undo stack only ever holds accepted edits. Replacing the field editor's string directly
/// broke its undo stack: Undo then threw `NSRangeException` (fix round 3). Input-method marked text
/// isn't filtered while it is being composed (it may show for a moment); whatever it commits is
/// sanitized through the text system (`controlTextDidChange`), and the undo stack is then cleared.
///
/// The field and the draft are kept equal in two directions, with nothing remembered in between
/// (fix round 4: a remembered "last reported" text went stale and swallowed a real change).
/// Field to draft: every change to the editor's text is given to `onChange`, whether or not it
/// looks like a repeat, and so is the text editing ends with, sanitized in the field first.
/// Draft to field: `updateNSView` writes the draft into the field, and reports nothing back while
/// it does.
///
/// It takes keyboard focus when it first appears; while it has focus the key monitor stands aside
/// (its first responder is the field editor, an `NSText`), and `onFocusChange` tells the view so it
/// can drop the menu's key handler. Return calls `onSubmit` and Esc `onCancel`, once per key-down
/// (the actions themselves ignore key repeats).
struct MenuEntryField: NSViewRepresentable {
    /// The draft; shown whenever it differs from the field's text (a new entry screen).
    let text: String
    let rules: MenuScreen.InputRules
    let onChange: (String) -> Void
    let onSubmit: () -> Void
    let onCancel: () -> Void
    let onFocusChange: (Bool) -> Void

    enum Replacement: Equatable {
        /// Apply the edit as asked.
        case accept
        /// Don't apply it: nothing in it is allowed, or there is no room.
        case refuse
        /// Apply this instead: the allowed characters of the replacement that fit.
        case replace(String)
    }

    /// What to do with an edit that replaces `range` (UTF-16) of `current` (already valid) with
    /// `replacement`: keep only the replacement's allowed characters (never a comma, CR or LF),
    /// cut to the room `MaxLength` leaves.
    static func filteredReplacement(current: String, range: NSRange, replacement: String,
                                    rules: MenuScreen.InputRules) -> Replacement {
        let text = current as NSString
        guard range.location != NSNotFound, NSMaxRange(range) <= text.length else { return .refuse }
        let remaining = text.replacingCharacters(in: range, with: "")
        var allowed = MenuInput.sanitize(replacement, rules: MenuScreen.InputRules(allowedCharacters: rules.allowedCharacters))
        if let maxLength = rules.maxLength {
            let room = max(0, maxLength - remaining.count)
            if allowed.count > room { allowed = String(allowed.prefix(room)) }
        }
        if allowed == replacement { return .accept }
        // Deleting (an empty replacement) is always accepted above; an insert of nothing is refused.
        return allowed.isEmpty ? .refuse : .replace(allowed)
    }

    /// `raw` sanitized, with the caret moved back by the characters dropped before it (best effort:
    /// typing and pasting drop characters at the caret, and a cut to `MaxLength` drops at the end).
    static func sanitizedEdit(_ raw: String, selection: NSRange, rules: MenuScreen.InputRules)
        -> (text: String, selection: NSRange) {
        let clean = MenuInput.sanitize(raw, rules: rules)
        guard clean != raw else { return (raw, selection) }
        let rawUTF16 = (raw as NSString).length
        let cleanUTF16 = (clean as NSString).length
        let caret = selection.location + selection.length
        let afterCaret = max(0, rawUTF16 - caret)
        let location = min(cleanUTF16, max(0, cleanUTF16 - afterCaret))
        return (clean, NSRange(location: location, length: 0))
    }

    final class Field: NSTextField {
        var onFocusChange: ((Bool) -> Void)?
        /// Editing ended; the field holds the editor's last text.
        var onEndEditing: (() -> Void)?
        var rules = MenuScreen.InputRules()

        /// The field editor asks its delegate (this field) before every edit: typing, pasting,
        /// deleting, undo and redo. Undo and redo restore text that was valid, so they pass as is.
        /// `NSTextField` implements this `NSTextViewDelegate` method without declaring it to
        /// Swift, so the override is by selector and the superclass's version is called through
        /// its implementation pointer.
        @objc(textView:shouldChangeTextInRange:replacementString:)
        func fieldEditor(_ textView: NSTextView, shouldChangeTextIn range: NSRange, replacementString: String?) -> Bool {
            guard let replacement = replacementString, !textView.hasMarkedText(),
                  !(textView.undoManager?.isUndoing ?? false), !(textView.undoManager?.isRedoing ?? false) else {
                return superShouldChange(textView, range, replacementString)
            }
            switch MenuEntryField.filteredReplacement(current: textView.string, range: range,
                                                      replacement: replacement, rules: rules) {
            case .accept:
                return superShouldChange(textView, range, replacement)
            case .refuse:
                return false
            case .replace(let allowed):
                // One undoable insert of what is allowed, through the text system (this method
                // accepts it when it asks again), in place of the edit asked for.
                textView.insertText(allowed, replacementRange: range)
                return false
            }
        }

        private func superShouldChange(_ textView: NSTextView, _ range: NSRange, _ replacement: String?) -> Bool {
            let selector = #selector(fieldEditor(_:shouldChangeTextIn:replacementString:))
            guard let implementation = class_getMethodImplementation(NSTextField.self, selector),
                  NSTextField.instancesRespond(to: selector) else { return true }
            typealias Function = @convention(c) (AnyObject, Selector, NSTextView, NSRange, NSString?) -> Bool
            return unsafeBitCast(implementation, to: Function.self)(self, selector, textView, range, replacement as NSString?)
        }

        override func becomeFirstResponder() -> Bool {
            let became = super.becomeFirstResponder()
            if became { onFocusChange?(true) }
            return became
        }

        override func textDidEndEditing(_ notification: Notification) {
            super.textDidEndEditing(notification)
            onEndEditing?()
            onFocusChange?(false)
        }
    }

    @MainActor final class Coordinator: NSObject, NSTextFieldDelegate {
        var parent: MenuEntryField
        var focusedOnce = false
        weak var field: Field?
        /// Set while `updateNSView` writes the draft into the field: that text is the draft, so
        /// there is nothing to report.
        var showingDraft = false

        init(_ parent: MenuEntryField) {
            self.parent = parent
            super.init()
            // Undo and redo change the field editor's text without the control's text-change
            // callback; the text storage reports every change, so follow it for this field's editor.
            NotificationCenter.default.addObserver(self, selector: #selector(storageDidProcessEditing(_:)),
                                                   name: NSTextStorage.didProcessEditingNotification, object: nil)
        }

        /// Posted for every text storage in the process, on the thread that edited it. This
        /// field's editor is only ever edited on the main thread, so any other thread's is not ours.
        @objc nonisolated private func storageDidProcessEditing(_ note: Notification) {
            guard Thread.isMainThread, let object = note.object as AnyObject? else { return }
            let edited = ObjectIdentifier(object)
            MainActor.assumeIsolated { storageEdited(edited) }
        }

        /// `edited`: the text storage that posted; only this field's editor's counts.
        private func storageEdited(_ edited: ObjectIdentifier) {
            guard let editor = field?.currentEditor() as? NSTextView, let storage = editor.textStorage,
                  ObjectIdentifier(storage) == edited,
                  !editor.hasMarkedText(), storage.editedMask.contains(.editedCharacters) else { return }
            // Only ever valid text here (the undo stack holds accepted edits, and every rewrite and
            // every draft from outside clears it); sanitized for safety.
            report(MenuInput.sanitize(storage.string, rules: parent.rules))
        }

        /// Always passed on, repeat or not: the draft is the view's, and only it knows its value.
        private func report(_ text: String) {
            guard !showingDraft else { return }
            parent.onChange(text)
        }

        /// The text editing ended with never went through `controlTextDidChange` if an input
        /// method was still composing (the composition is kept as it is), so it is sanitized here.
        func editingEnded() {
            guard let field, !showingDraft else { return }
            let clean = MenuInput.sanitize(field.stringValue, rules: parent.rules)
            if field.stringValue != clean { field.stringValue = clean }
            report(clean)
        }

        func controlTextDidChange(_ notification: Notification) {
            guard let editor = notification.userInfo?["NSFieldEditor"] as? NSTextView else { return }
            // While an input method composes, wait for it to commit.
            guard !editor.hasMarkedText() else { return }
            let edit = MenuEntryField.sanitizedEdit(editor.string, selection: editor.selectedRange(), rules: parent.rules)
            if edit.text != editor.string {
                // A backstop for what got past the filter (committed marked text): replaced through
                // the text system, then the undo stack is cleared, since undoing the rewrite would
                // bring back the unsanitized commit. Its own change notification comes back here
                // with valid text.
                let all = NSRange(location: 0, length: (editor.string as NSString).length)
                if editor.shouldChangeText(in: all, replacementString: edit.text) {
                    editor.replaceCharacters(in: all, with: edit.text)
                    editor.didChangeText()
                    editor.setSelectedRange(edit.selection)
                    editor.breakUndoCoalescing()
                    editor.undoManager?.removeAllActions()
                }
                return
            }
            report(edit.text)
        }

        func control(_ control: NSControl, textView: NSTextView, doCommandBy selector: Selector) -> Bool {
            switch selector {
            case #selector(NSResponder.insertNewline(_:)):
                parent.onSubmit()
                return true
            case #selector(NSResponder.cancelOperation(_:)):
                parent.onCancel()
                return true
            default:
                return false
            }
        }
    }

    func makeCoordinator() -> Coordinator { Coordinator(self) }

    func makeNSView(context: Context) -> Field {
        let field = Field()
        field.delegate = context.coordinator
        context.coordinator.field = field
        field.font = .preferredFont(forTextStyle: .title3)
        field.isBezeled = true
        field.bezelStyle = .roundedBezel
        field.lineBreakMode = .byClipping
        field.cell?.isScrollable = true
        field.cell?.wraps = false
        field.setAccessibilityLabel("Value")
        field.stringValue = text
        field.onFocusChange = onFocusChange
        field.onEndEditing = { [weak coordinator = context.coordinator] in coordinator?.editingEnded() }
        field.rules = rules
        // Focus on appear, once the field is in its window.
        DispatchQueue.main.async { [weak field] in
            guard let field, let window = field.window, !context.coordinator.focusedOnce else { return }
            context.coordinator.focusedOnce = true
            window.makeFirstResponder(field)
        }
        return field
    }

    func updateNSView(_ field: Field, context: Context) {
        context.coordinator.parent = self
        field.onFocusChange = onFocusChange
        field.rules = rules
        context.coordinator.showingDraft = true
        defer { context.coordinator.showingDraft = false }
        if let editor = field.currentEditor() as? NSTextView {
            if editor.string != text {
                // A draft from outside (a new entry screen): a fresh start, so the undo stack,
                // which describes the old text, is cleared.
                editor.string = text
                editor.setSelectedRange(NSRange(location: (text as NSString).length, length: 0))
                editor.undoManager?.removeAllActions()
            }
        } else if field.stringValue != text {
            field.stringValue = text
        }
    }
}
#endif
