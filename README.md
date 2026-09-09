# CineKit

A from-scratch Swift package for reading and writing Vision Research Phantom `.cine` high-speed camera files — header/setup parsing, P10/P12L/uncompressed pixel unpacking, `.cube` 3D LUT parsing, and trimmed-range `.cine` writing. Pure Foundation, no Metal/AppKit — safe to use from any Swift target, including non-macOS/non-Apple-rendering contexts. Vision Research does publish an official "Phantom Cine File Format" specification (no NDA or login required), which this package follows where it's cited in doc comments throughout `Sources/CineKit/` — but that document doesn't cover every field or every camera generation this package has been tested against, so several parsing decisions were still reverse-engineered and validated empirically against real sample files (see those same doc comments for the specific evidence behind each one).

## What's in here

- **Header/setup parsing** (`CineFile`, `CineFileHeader`, `BitmapInfoHeader`, `CineSetup`): open a `.cine` file and read its dimensions, frame rate, CFA/color info, bit depth, shutter speed, black/white levels, camera model, per-head white balance (including multihead/stereo cameras), recorded rotation, and color-calibration matrix — all lazily and length-guarded against the file's own recorded `SETUP` size, never assuming a fixed-size struct.
- **Per-frame decoding** (`CineFile.decodeFrame(at:)`): raw sensor `UInt16` values per pixel, for P10 (10-bit packed), P12L (12-bit packed), and uncompressed (8/16-bit) sources. No demosaicing or tone-mapping — that's left to a consumer's own rendering layer. P10 is gamma-companded at the pixel level (a bandwidth-saving trick, not a "look"), so `decodeFrame(at:)` linearizes it internally via the exact lookup table Vision Research's own spec provides — see `P10Linearization`/`P10Unpacker`'s doc comments; `CineFile.effectiveBlackWhiteLevels` re-expresses a file's own recorded black/white points in that same linear domain.
- **Per-frame capture time & exposure** (`CineFile.frameCaptureTimes()`, `frameExposureNanoseconds()`): when present, exactly when each frame was captured and how long its exposure was, frame-index-aligned with `decodeFrame(at:)`.
- **Writing** (`CineFile.writeTrimmed(range:to:)`): a structural, byte-verbatim frame-range trim to a fresh `.cine` file.
- **Color** (`ColorCalibration`): decomposes a file's recorded calibration matrix into white balance + a normalized color matrix.
- **LUT** (`CubeLUT`): reads and writes Adobe `.cube` 3D lookup tables.

## Specification

Vision Research's own "Phantom Cine File Format" specification — publicly downloadable, no NDA or account required: <https://phantomhighspeed.my.site.com/PhantomCommunity/servlet/fileField?entityId=ka01N000000vtRkQAI&field=File_Attachments__Body__s>. Every place this package relies on it (the `SETUP` struct layout, the `CameraVersion`/`BlackLevel`/`WhiteLevel` field semantics, the P10 10-bit-to-12-bit-linear lookup table) cites it directly in that code's own doc comment, cross-checked in the LUT's case against the independent open-source [`pycine`](https://github.com/ottomatic-io/pycine) project's own byte-identical copy of the same table. Fields or behaviors this document doesn't cover (or that real files disagree with) are called out individually, in the same doc comments, as reverse-engineered/empirically-validated instead.

## Feedback and feature requests

I'd love to hear from you! If there's a `.cine`/Phantom-camera-format feature you need that isn't here yet, or something doesn't behave the way you'd expect, please open an issue — I'm always happy to take a look and see what I can add.
