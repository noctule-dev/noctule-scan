// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

import Testing
import NoctuleKit
@testable import NoctuleAppCore

// MenuShortcutText (Plan 24, Task 4; services-range design §5.4 "Feedback"): what the Scanner view
// says when a Services or Range walk fails. The destination comes from the shortcut, never from
// the error's `expected` (the screen needed at the failing step).

@Suite(.timeLimit(.minutes(1))) struct MenuShortcutTextTests {
    @Test func alreadyInAMenu() {
        for shortcut in MenuShortcut.allCases {
            #expect(MenuShortcutText.message(for: .alreadyInMenu, shortcut: shortcut) == "Already in a menu. Exit it first.")
        }
    }

    @Test func funcPending() {
        for shortcut in MenuShortcut.allCases {
            #expect(MenuShortcutText.message(for: .functionPending, shortcut: shortcut)
                    == "Func is on. Press a key to clear it first.")
        }
    }

    @Test func walkStoppedNamesTheDestinationAndWhatTheScannerShowed() {
        #expect(MenuShortcutText.message(for: .walkStopped(expected: "Menu", found: "Settings"), shortcut: .range)
                == "Couldn't open Set Range: the scanner showed Settings.")
        #expect(MenuShortcutText.message(for: .walkStopped(expected: "Set Your Location", found: "Menu"),
                                         shortcut: .serviceTypes)
                == "Couldn't open Select Service Types: the scanner showed Menu.")
    }

    @Test func walkStoppedOutsideAMenu() {
        #expect(MenuShortcutText.message(for: .walkStopped(expected: "Menu", found: nil), shortcut: .range)
                == "Couldn't open Set Range: the scanner didn't show the expected screen.")
        #expect(MenuShortcutText.message(for: .walkStopped(expected: "Menu", found: nil), shortcut: .serviceTypes)
                == "Couldn't open Select Service Types: the scanner didn't show the expected screen.")
    }

    @Test func noAnswer() {
        #expect(MenuShortcutText.message(for: .noAnswer, shortcut: .range)
                == "Couldn't open Set Range: the scanner didn't answer.")
        #expect(MenuShortcutText.message(for: .noAnswer, shortcut: .serviceTypes)
                == "Couldn't open Select Service Types: the scanner didn't answer.")
    }

    @Test func rejected() {
        #expect(MenuShortcutText.message(for: .rejected("MSV,NG"), shortcut: .range)
                == "Couldn't open Set Range: the scanner refused a step.")
        #expect(MenuShortcutText.message(for: .rejected("KEY,NG"), shortcut: .serviceTypes)
                == "Couldn't open Select Service Types: the scanner refused a step.")
    }

    @Test func busyIsSilent() {
        for shortcut in MenuShortcut.allCases {
            #expect(MenuShortcutText.message(for: .busy, shortcut: shortcut) == nil)
        }
    }

    @Test func everythingElseNamesTheDestination() {
        let others: [MenuActionError] = [.notConnected, .notInMenu, .menuChanged, .invalidValue,
                                         .needsConfirmation(itemName: "Fictional")]
        for error in others {
            #expect(MenuShortcutText.message(for: error, shortcut: .range) == "Couldn't open Set Range.", "\(error)")
            #expect(MenuShortcutText.message(for: error, shortcut: .serviceTypes)
                    == "Couldn't open Select Service Types.", "\(error)")
        }
    }

    @Test func destinationsMatchTheProfilesPaths() {
        for model in ScannerModel.allCases {
            let profile = ModelProfile.profile(for: model)
            for shortcut in MenuShortcut.allCases {
                if let path = profile.menuShortcuts[shortcut] {
                    #expect(MenuShortcutText.destination(of: shortcut) == path.destination, "\(model) \(shortcut)")
                }
            }
        }
    }
}
