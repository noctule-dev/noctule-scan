// SPDX-License-Identifier: Apache-2.0
// Copyright 2026 Sean Foley and the Noctule Scan contributors

/// Front-panel key codes accepted by the scanner's `KEY` command.
public enum FrontPanelKey: String, Sendable, CaseIterable {
    case menu = "M"
    case function = "F"
    case avoid = "L"
    case digit0 = "0", digit1 = "1", digit2 = "2", digit3 = "3", digit4 = "4"
    case digit5 = "5", digit6 = "6", digit7 = "7", digit8 = "8", digit9 = "9"
    case dotNo = "."
    case enterYes = "E"
    case scrollRight = ">"
    case scrollLeft = "<"
    case scrollPush = "^"
    case volumePush = "V"
    case squelchPush = "Q"
    case replay = "Y"
    case soft1 = "A"
    case soft2 = "B"
    case soft3 = "C"
    case zip = "Z"
    case serviceType = "T"
    case range = "R"
}
