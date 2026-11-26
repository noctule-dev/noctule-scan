# Uniden reference documents

The PDFs in this folder are Uniden's copyrighted manuals. They are git-ignored and kept locally only. Download them from Uniden's support pages and place them here:

- `uniden-sds200-owners-manual.pdf` (SDS200 owner's manual)
- `uniden-sds150-owners-manual.pdf` (SDS150 owner's manual)
- `uniden-sds-series-remote-command-spec-v2.00.pdf` (*SDS Series Remote Command Specification* V2.00, dated 2025-07-07: the remote commands for the SDS100, SDS150 and SDS200, including `GCS` and the `MDL` names). Get it from Uniden's support pages for the SDS-series scanners; the exact download page wasn't recorded when this copy was saved, so search for the title. Where it and the owner's hardware disagree (the SDS150's `MDL` name, for one), the protocol notes mark which is which (**[spec]**, **[hw]**).
- `uniden-bcdx36hp-remote-command-spec-v1.03.pdf` and `uniden-bcdx36hp-remote-command-spec-v1.05.pdf` (*BCDx36HP Remote Command Specification* V1.03 and V1.05, for the BCD436HP and BCD536HP; V1.05 adds the key-code sheet V1.03 lacks). Neither prints `HLD`'s argument sheet ("tkd and 1st,2nd opt"); the SDS spec above does, on its page 14.
- `uniden-bcdx36hp-menu-tree-spec-v1.07.pdf` (*BCDx36HP Menu Tree Specification* V1.07: the menu IDs `MNU` takes, and the item names the destructive-item list reads).
- `uniden-bcd436hp-owners-manual.pdf` (BCD436HP owner's manual).

Get the BCDx36HP documents from Uniden's support pages for the BCD436HP and BCD536HP (search for the titles; the exact download pages weren't recorded when these copies were saved).

Protocol research notes live in `docs/specs/2026-11-08-sds-remote-protocol.md`.
