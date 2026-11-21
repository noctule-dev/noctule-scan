# Acknowledgments

## The `sds200` Python library

Noctule Scan's main reference for the scanner's remote protocol (commands, key codes, the `ScannerInfo` XML, and the RTSP audio request sequence) is the open-source `sds200` Python library (sdsctl) by Steven Boyd, MIT License, © 2026 Steven Boyd: <https://github.com/stevenboyd78/sdsctl>, <https://pypi.org/project/sds200/>. Its hardware-validated documentation saved us a great deal of guessing.

We read it for protocol facts only. Noctule Scan is written from scratch in Swift, and no code from the library has been copied or ported. Facts taken from it are marked **[lib]** in `docs/specs/2026-11-08-sds-remote-protocol.md`. If any of its code is ever ported, its MIT license notice will be kept with that code and recorded here.

## Other sources

- The `MSM,1` remote-restart command was named by the ProScan developer on the RadioReference forums (protocol notes §3 and §8.8).
