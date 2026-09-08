# CineKit

A from-scratch Swift package for reading and writing Vision Research Phantom `.cine` high-speed camera files — header/setup parsing, P10/P12L/uncompressed pixel unpacking, `.cube` 3D LUT parsing, and trimmed-range `.cine` writing. Pure Foundation, no Metal/AppKit — safe to use from any Swift target, including non-macOS/non-Apple-rendering contexts. No official specification for the `.cine` format exists publicly — the layout was reverse-engineered and validated empirically against real sample files (see doc comments throughout `Sources/CineKit/` for the specific evidence behind each parsing decision).

## What's in here

- **Header/setup parsing** (`CineFile`, `CineFileHeader`, `BitmapInfoHeader`, `CineSetup`): open a `.cine` file and read its dimensions, frame rate, CFA/color info, bit depth, shutter speed, black/white levels, camera model, per-head white balance (including multihead/stereo cameras), recorded rotation, and color-calibration matrix — all lazily and length-guarded against the file's own recorded `SETUP` size, never assuming a fixed-size struct.
- **Per-frame decoding** (`CineFile.decodeFrame(at:)`): raw sensor `UInt16` values per pixel, for P10 (10-bit packed), P12L (12-bit packed), and uncompressed (8/16-bit) sources. No demosaicing or tone-mapping — that's left to a consumer's own rendering layer.
- **Per-frame capture time & exposure** (`CineFile.frameCaptureTimes()`, `frameExposureNanoseconds()`): when present, exactly when each frame was captured and how long its exposure was, frame-index-aligned with `decodeFrame(at:)`.
- **Writing** (`CineFile.writeTrimmed(range:to:)`): a structural, byte-verbatim frame-range trim to a fresh `.cine` file.
- **Color** (`ColorCalibration`): decomposes a file's recorded calibration matrix into white balance + a normalized color matrix.
- **LUT** (`CubeLUT`): reads and writes Adobe `.cube` 3D lookup tables.

## Feedback and feature requests

I'd love to hear from you! If there's a `.cine`/Phantom-camera-format feature you need that isn't here yet, or something doesn't behave the way you'd expect, please open an issue — I'm always happy to take a look and see what I can add.
