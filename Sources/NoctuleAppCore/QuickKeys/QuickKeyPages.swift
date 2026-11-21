// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Foundation

/// The pop-over's keypad pages (design `docs/specs/2026-11-18-quick-keys-design.md` §5.5 "The keypad",
/// "The tens", "Search"): quick keys 0–99 in ten tens of ten slots, each key in its own place. A list
/// without a quick key is in no ten (the pop-over lists those after the keypad).
public struct QuickKeyPages: Sendable, Equatable {
    /// One segment of the tens control.
    public struct Ten: Sendable, Equatable, Identifiable {
        /// 0 for keys 0–9, … 9 for 90–99.
        public var index: Int
        public var range: ClosedRange<Int>
        /// Lists whose key is in `range`.
        public var listCount: Int
        /// Those whose key reads on (the "n on" of the segment).
        public var onCount: Int
        /// A ten with no lists is disabled, and paging skips it.
        public var isEnabled: Bool
        /// It holds the list being scanned (the green dot).
        public var holdsScanning: Bool

        public var id: Int { index }
    }

    public let lists: [QuickKeyListItem]
    /// The `Index` of the list being scanned, if any (`QuickKeysModel.scanning.list`).
    public let scanningList: UInt32?
    /// Always ten.
    public let tens: [Ten]

    public init(lists: [QuickKeyListItem], scanningList: UInt32?) {
        self.lists = lists
        self.scanningList = scanningList
        let scanningKey = scanningList.flatMap { index in lists.first { $0.index == index }?.key }
        tens = (0..<10).map { ten in
            let range = (ten * 10)...(ten * 10 + 9)
            let held = lists.filter { $0.key.map(range.contains) ?? false }
            return Ten(index: ten, range: range, listCount: held.count,
                       onCount: held.filter { $0.state == .on }.count, isEnabled: !held.isEmpty,
                       holdsScanning: scanningKey.map(range.contains) ?? false)
        }
    }

    /// The ten the pop-over opens on: the one holding the list being scanned, else the first with lists
    /// (0 when none has).
    public func initialTen() -> Int {
        if let scanning = tens.first(where: { $0.holdsScanning && $0.isEnabled }) { return scanning.index }
        return tens.first(where: \.isEnabled)?.index ?? 0
    }

    /// The next ten after `ten` that has lists; nil when there is none.
    public func next(after ten: Int) -> Int? {
        tens.first { $0.index > ten && $0.isEnabled }?.index
    }

    /// The nearest ten before `ten` that has lists; nil when there is none.
    public func previous(before ten: Int) -> Int? {
        tens.last { $0.index < ten && $0.isEnabled }?.index
    }

    /// The ten slots of `ten`, slot n holding the list with key `ten * 10 + n` (the first in `GLT` order
    /// when several share it), nil for a key with no list (a faint placeholder). Ten nils outside 0–9.
    public func slots(inTen ten: Int) -> [QuickKeyListItem?] {
        (0..<10).map { slot in
            guard (0..<10).contains(ten) else { return nil }
            let key = ten * 10 + slot
            return lists.first { $0.key == key }
        }
    }

    /// The first row matching `text`: a list, else a system, else a department or site (each in `GLT`
    /// order, through the lists of the keypad and the trees `model` has), whose name contains `text`
    /// (ignoring case), or whose key equals it, given as a number (`12`) or as its tag (`F12` for a list,
    /// `S3` for a system, `D0` for a department or site). Nil for blank text or no match.
    @MainActor
    public static func search(_ text: String, in model: QuickKeysModel) -> QuickKeyRow? {
        let query = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !query.isEmpty else { return nil }
        let number = Int(query).flatMap { (0...99).contains($0) ? $0 : nil }
        func tagged(_ tag: Character) -> Int? {
            guard let first = query.first, first.lowercased() == tag.lowercased(),
                  let key = Int(query.dropFirst()), (0...99).contains(key) else { return nil }
            return key
        }
        func matches(_ name: String, _ key: Int?, _ tag: Character) -> Bool {
            if name.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil { return true }
            guard let key else { return false }
            return key == number || key == tagged(tag)
        }
        if let list = model.lists.first(where: { matches($0.name, $0.key, "F") }) { return .list(list.index) }
        let trees = model.lists.compactMap { list in model.trees[list.index].map { (list.index, $0) } }
        for (list, tree) in trees {
            if let system = tree.systems.first(where: { matches($0.name, $0.key, "S") }) {
                return .system(list: list, system: system.index)
            }
        }
        for (list, tree) in trees {
            for system in tree.systems {
                if let child = system.children.first(where: { matches($0.name, $0.key, "D") }) {
                    return .child(list: list, system: system.index, child: child.index)
                }
            }
        }
        return nil
    }
}

/// Number typing on the keypad (design §5.5 "Keyboard"): each digit jumps to that key at once, and a
/// second digit within a second makes a two-digit key with the first (`4` then `1` is 41); the digit
/// after that starts again.
public struct QuickKeyTyping: Sendable {
    /// How long after one digit the next one still joins it.
    public static let window: Duration = .seconds(1)

    private var pending: (digit: Int, at: ContinuousClock.Instant)?

    public init() {}

    /// The key to jump to after typing `digit` (0–9) at `instant`; nil for anything else.
    public mutating func type(_ digit: Int, at instant: ContinuousClock.Instant) -> Int? {
        guard (0...9).contains(digit) else {
            pending = nil
            return nil
        }
        if let first = pending, first.at.duration(to: instant) <= Self.window, first.at <= instant {
            pending = nil
            return first.digit * 10 + digit
        }
        pending = (digit, instant)
        return digit
    }
}
