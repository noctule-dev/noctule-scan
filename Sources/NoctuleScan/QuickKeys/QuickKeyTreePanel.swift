// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

#if os(macOS)
import NoctuleAppCore
import NoctuleKit
import SwiftUI

/// Which systems of a list start expanded (design §5.5 "The tree"): all of them when the list has three
/// or fewer, else none but the one being scanned.
enum QuickKeyTreeExpansion {
    static let expandAllUpTo = 3

    static func initial(systems: [UInt32], scanning: UInt32?) -> Set<UInt32> {
        if systems.count <= expandAllUpTo { return Set(systems) }
        guard let scanning, systems.contains(scanning) else { return [] }
        return [scanning]
    }
}

/// The open list's tree, under the keypad (design §5.5 "The tree"): a header with its key, name,
/// "n systems, m on" and a "Scan this list" switch (the tile's action); then its systems, each with a
/// disclosure triangle, its S tag, name and switch; under each its departments and sites, indented with
/// connecting lines, each with its D tag, name, a "site" tag for sites, and switch. A green dot marks the
/// system and department or site being scanned. Rows under an off parent are dimmed: they keep their
/// switches, but nothing under an off parent scans.
struct QuickKeyTreePanel: View {
    let model: QuickKeysModel
    let list: QuickKeyListItem
    @Bindable var state: QuickKeysViewState

    private var tree: QuickKeyListTree? { model.trees[list.index] }
    private var listRow: QuickKeyRow { .list(list.index) }

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            header
            Divider()
            if list.key != nil, !list.monitored {
                note(QuickKeysText.notMonitoredLine, tint: .orange)
            }
            if let tree {
                if tree.freshness != .fresh { checkingLine }
                if let line = Self.readErrorLine(tree) { note(line, tint: .secondary).lineLimit(2) }
                rows(tree)
            } else {
                checkingLine
                Spacer(minLength: 0)
            }
        }
        .background(Color.primary.opacity(0.04), in: RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(QuickKeyColors.offBorder, lineWidth: 1))
        .clipShape(RoundedRectangle(cornerRadius: 10))
    }

    // MARK: Header

    private var header: some View {
        let switchState = model.switchState(for: listRow)
        let look = QuickKeySwitchLook(state: switchState, raw: list.state)
        let sharing = model.sharing(for: listRow)
        return HStack(spacing: 8) {
            if let key = list.key {
                QuickKeyBadge(text: QuickKeysText.keyTag(listRow, key: key), isOn: look.isOn)
            } else {
                QuickKeyTag(text: QuickKeysText.noQuickKeyTag)
            }
            Text(list.name).font(.system(size: 14, weight: .bold)).lineLimit(1)
            if let tree {
                Text("· " + QuickKeysText.headerDetail(systems: tree.systems.count, on: Self.onCount(tree)))
                    .font(.system(size: 11))
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            if sharing > 1, let key = list.key {
                QuickKeyTag(text: QuickKeysText.sharedTag)
                    .help(QuickKeysText.sharingHelp(count: sharing, tag: QuickKeysText.keyTag(listRow, key: key)))
            }
            Spacer(minLength: 4)
            if list.key != nil {
                Text(QuickKeysText.scanThisList).font(.system(size: 11, weight: .medium)).foregroundStyle(.secondary)
                QuickKeySwitch(look: look, accessibilityLabel: QuickKeysText.scanThisList) { toggle(listRow) }
                    .help(QuickKeysText.help(for: switchState) ?? "")
            }
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 8)
        .background(Color.primary.opacity(0.05))
    }

    /// The systems on, once the tree's states are read; nil before.
    static func onCount(_ tree: QuickKeyListTree) -> Int? {
        guard tree.freshness == .fresh, tree.systems.contains(where: { $0.state != nil }) else { return nil }
        return tree.systems.filter { $0.state == .on }.count
    }

    /// Why the list's last read failed, while it isn't `.fresh`; nil otherwise.
    static func readErrorLine(_ tree: QuickKeyListTree) -> String? {
        guard tree.freshness != .fresh, let error = tree.readError else { return nil }
        return QuickKeysText.listReadError(error)
    }

    private var checkingLine: some View {
        HStack(spacing: 6) {
            ProgressView().controlSize(.mini)
            Text(QuickKeysText.checking).font(.system(size: 11)).foregroundStyle(.secondary)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 5)
    }

    private func note(_ text: String, tint: some ShapeStyle) -> some View {
        Text(text)
            .font(.system(size: 11))
            .foregroundStyle(tint)
            .padding(.horizontal, 12)
            .padding(.vertical, 5)
            .fixedSize(horizontal: false, vertical: true)
    }

    // MARK: Rows

    private func rows(_ tree: QuickKeyListTree) -> some View {
        let listOn = QuickKeySwitchLook(state: model.switchState(for: listRow), raw: list.state).isOn
        return ScrollViewReader { proxy in
            ScrollView {
                VStack(alignment: .leading, spacing: 0) {
                    ForEach(Array(tree.systems.enumerated()), id: \.element.index) { position, system in
                        let isLast = position == tree.systems.count - 1
                        systemRow(system, isLast: isLast, dimmed: listOn == false)
                        if state.expanded.contains(system.index) {
                            let systemOn = QuickKeySwitchLook(
                                state: model.switchState(for: .system(list: list.index, system: system.index)),
                                raw: system.state).isOn
                            ForEach(Array(system.children.enumerated()), id: \.element.index) { childPosition, child in
                                childRow(child, of: system, systemIsLast: isLast,
                                         isLast: childPosition == system.children.count - 1,
                                         dimmed: listOn == false || systemOn == false)
                            }
                        }
                    }
                }
                .padding(.vertical, 4)
            }
            .onChange(of: state.searchHit) { _, hit in
                guard let hit, hit.list == list.index else { return }
                withAnimation { proxy.scrollTo(hit, anchor: .center) }
            }
        }
    }

    private func systemRow(_ system: QuickKeyListTree.SystemRow, isLast: Bool, dimmed: Bool) -> some View {
        let row = QuickKeyRow.system(list: list.index, system: system.index)
        let switchState = model.switchState(for: row)
        let look = QuickKeySwitchLook(state: switchState, raw: system.state)
        let expanded = state.expanded.contains(system.index)
        let sharing = model.sharing(for: row)
        return HStack(spacing: 8) {
            Button {
                if expanded { state.expanded.remove(system.index) } else { state.expanded.insert(system.index) }
            } label: {
                Image(systemName: expanded ? "chevron.down" : "chevron.right")
                    .font(.system(size: 9, weight: .semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: 12, height: 16)
                    .contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .tracksKeyboardFocus()
            .opacity(system.children.isEmpty ? 0 : 1)
            .disabled(system.children.isEmpty)
            .accessibilityLabel(expanded ? "Collapse \(system.name)" : "Expand \(system.name)")
            keyLabel(row, key: system.key, isOn: look.isOn)
            Text(system.name).font(.system(size: 13, weight: .semibold)).lineLimit(1).help(system.name)
            tags(avoided: system.avoided, site: false, sharing: sharing, row: row, key: system.key)
            if model.scanning.list == list.index, model.scanning.system == system.index { scanningDot }
            Spacer(minLength: 4)
            if system.key != nil, list.key != nil {
                QuickKeySwitch(look: look, accessibilityLabel: switchLabel(system.name, row: row, key: system.key)) {
                    toggle(row)
                }
                .help(QuickKeysText.help(for: switchState) ?? "")
            }
        }
        .padding(.leading, 26)
        .padding(.trailing, 12)
        .padding(.vertical, 5)
        .background(alignment: .leading) { QuickKeyTreeLines(level: 1, outerContinues: !isLast, innerContinues: false) }
        .background(searchBackground(row))
        .opacity(dimmed ? 0.45 : 1)
        .id(row)
    }

    private func childRow(_ child: QuickKeyListTree.ChildRow, of system: QuickKeyListTree.SystemRow,
                          systemIsLast: Bool, isLast: Bool, dimmed: Bool) -> some View {
        let row = QuickKeyRow.child(list: list.index, system: system.index, child: child.index)
        let switchState = model.switchState(for: row)
        let look = QuickKeySwitchLook(state: switchState, raw: child.state)
        let sharing = model.sharing(for: row)
        return HStack(spacing: 8) {
            keyLabel(row, key: child.key, isOn: look.isOn)
            Text(child.name).font(.system(size: 12.5)).lineLimit(1).help(child.name)
            tags(avoided: child.avoided, site: child.kind == .site, sharing: sharing, row: row, key: child.key)
            if model.scanning.list == list.index, model.scanning.system == system.index,
               model.scanning.child == child.index { scanningDot }
            Spacer(minLength: 4)
            if child.key != nil, system.key != nil, list.key != nil {
                QuickKeySwitch(look: look, accessibilityLabel: switchLabel(child.name, row: row, key: child.key)) {
                    toggle(row)
                }
                .help(QuickKeysText.help(for: switchState) ?? "")
            }
        }
        .padding(.leading, 56)
        .padding(.trailing, 12)
        .padding(.vertical, 4)
        .background(alignment: .leading) {
            QuickKeyTreeLines(level: 2, outerContinues: !systemIsLast, innerContinues: !isLast)
        }
        .background(searchBackground(row))
        .opacity(dimmed ? 0.45 : 1)
        .id(row)
    }

    @ViewBuilder
    private func keyLabel(_ row: QuickKeyRow, key: Int?, isOn: Bool?) -> some View {
        if let key {
            QuickKeyBadge(text: QuickKeysText.keyTag(row, key: key), isOn: isOn)
        } else {
            QuickKeyTag(text: QuickKeysText.noQuickKeyTag)
        }
    }

    @ViewBuilder
    private func tags(avoided: Bool, site: Bool, sharing: Int, row: QuickKeyRow, key: Int?) -> some View {
        if site { QuickKeyTag(text: QuickKeysText.siteTag) }
        if avoided { QuickKeyTag(text: QuickKeysText.avoidedTag, tint: .orange) }
        if sharing > 1, let key {
            QuickKeyTag(text: QuickKeysText.sharedTag)
                .help(QuickKeysText.sharingHelp(count: sharing, tag: QuickKeysText.keyTag(row, key: key)))
        }
    }

    private var scanningDot: some View {
        Circle().fill(QuickKeyColors.scanning).frame(width: 8, height: 8).accessibilityLabel("Scanning now")
    }

    private func searchBackground(_ row: QuickKeyRow) -> Color {
        state.searchHit == row ? Color.accentColor.opacity(0.18) : .clear
    }

    private func switchLabel(_ name: String, row: QuickKeyRow, key: Int?) -> String {
        guard let key else { return name }
        return "\(name), quick key \(QuickKeysText.keyTag(row, key: key))"
    }

    private func toggle(_ row: QuickKeyRow) {
        Task { await model.toggle(row) }
    }
}

/// The connecting lines of a tree row (the mockup's): level 1 (a system) draws the trunk at x 14 down to
/// its middle (through the row when more systems follow) and a stub to the right; level 2 (a department
/// or site) continues the trunk when more systems follow, and draws its own line at x 40 with a stub.
struct QuickKeyTreeLines: View {
    let level: Int
    /// More systems follow this one.
    let outerContinues: Bool
    /// More departments or sites follow this one (level 2).
    let innerContinues: Bool

    var body: some View {
        Canvas { context, size in
            var path = Path()
            let mid = size.height / 2
            if level == 1 {
                path.move(to: CGPoint(x: 14.5, y: 0))
                path.addLine(to: CGPoint(x: 14.5, y: outerContinues ? size.height : mid))
                path.move(to: CGPoint(x: 14.5, y: mid))
                path.addLine(to: CGPoint(x: 22, y: mid))
            } else {
                if outerContinues {
                    path.move(to: CGPoint(x: 14.5, y: 0))
                    path.addLine(to: CGPoint(x: 14.5, y: size.height))
                }
                path.move(to: CGPoint(x: 40.5, y: 0))
                path.addLine(to: CGPoint(x: 40.5, y: innerContinues ? size.height : mid))
                path.move(to: CGPoint(x: 40.5, y: mid))
                path.addLine(to: CGPoint(x: 50, y: mid))
            }
            context.stroke(path, with: .color(QuickKeyColors.lines), lineWidth: 1)
        }
        .frame(width: 56)
        .accessibilityHidden(true)
    }
}
#endif
