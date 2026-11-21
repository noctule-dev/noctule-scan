# Fixtures

Recorded scanner responses (line replies and XML documents) used by tests. They are bundled as resources of the `NoctuleKitTestSupport` target and loaded with `fixture(_:)`. Contain no real hosts or addresses.

They are sanitized captures: every real value (system, list, site, and channel names, frequencies, unit IDs, NAC, Sys ID, RFSS and Site IDs, favorites indexes) was replaced with a fictional one of the same length, so the structure is exactly as captured: byte length, field count and widths (`STS`: 45 fields, 17 display lines), the two U+FFFD characters and `\x1a\x1b` glyph bytes in the `STS` reply, and the `Index="4294967295"` unprogrammed sentinel. Keep it that way: no real names or real-traffic values in tracked files (`config/real-names.txt.example`).
