# CineKit

A from-scratch Swift package for reading, writing, and rendering Vision Research Phantom
`.cine` high-speed camera files — header/setup parsing, P10/P12L/uncompressed pixel
unpacking, `.cube` 3D LUT parsing, trimmed-range `.cine` writing, and a GPU debayer/tone-mapping
pipeline for turning decoded sensor data into a displayable image. Vision Research does publish
an official "Phantom Cine File Format" specification (no NDA or login required), which this
package follows where it's cited in doc comments throughout `Sources/CineKit/` — but that
document doesn't cover every field or every camera generation this package has been tested
against, so several parsing decisions were still reverse-engineered and validated empirically
against real sample files (see those same doc comments for the specific evidence behind each
one).

**Requires Metal** (macOS/Apple platforms only)

## What's in here

- **Header/setup parsing** (`CineFile`, `CineFileHeader`, `BitmapInfoHeader`, `CineSetup`): open a `.cine` file and read its dimensions, frame rate, CFA/color info, bit depth, shutter speed, black/white levels, camera model, per-head white balance (including multihead/stereo cameras), recorded rotation, and color-calibration matrix — all lazily and length-guarded against the file's own recorded `SETUP` size, never assuming a fixed-size struct.
- **Per-frame decoding** (`CineFile.decodeFrame(at:)`): raw sensor `UInt16` values per pixel, for P10 (10-bit packed), P12L (12-bit packed), and uncompressed (8/16-bit) sources. No demosaicing or tone-mapping at this stage — that's the rendering pipeline below. P10 is gamma-companded at the pixel level (a bandwidth-saving trick, not a "look"), so `decodeFrame(at:)` linearizes it internally via the exact lookup table Vision Research's own spec provides — see `P10Linearization`/`P10Unpacker`'s doc comments; `CineFile.effectiveBlackWhiteLevels` re-expresses a file's own recorded black/white points in that same linear domain.
- **Per-frame capture time & exposure** (`CineFile.frameCaptureTimes()`, `frameExposureNanoseconds()`): when present, exactly when each frame was captured and how long its exposure was, frame-index-aligned with `decodeFrame(at:)`.
- **Writing** (`CineFile.writeTrimmed(range:to:)`): a structural, byte-verbatim frame-range trim to a fresh `.cine` file.
- **Color** (`ColorCalibration`): decomposes a file's recorded calibration matrix into white balance + a normalized color matrix.
- **LUT** (`CubeLUT`): reads and writes Adobe `.cube` 3D lookup tables.
- **Rendering** (`Sources/CineKit/Rendering/`): a Metal pipeline turning a `decodeFrame(at:)` result (or any raw `[UInt16]` sensor buffer, e.g. one downloaded live over a network protocol rather than read from a file) into a displayable, color-correct image.
  - `CineRenderer` + `Shaders/Tonemap.metal`: the single shared tone-mapping render pass — five debayer modes (`DebayerMode`: raw sensor, grey-scale, nearest-neighbor, bilinear, and Malvar-He-Cutler high-quality demosaic), white balance + color-matrix calibration (`ExposureUniforms`, fed from `ColorCalibration`), a "Cine Colour" grading stage (`GradingUniforms`: brightness/gain/pedestal/gamma-trim/saturation/hue/flip/rotate), a zoom/pan viewport transform (`ViewportUniforms`), an optional 3D LUT (`LUTTexture`), and optional per-channel tone curves (`ToneCurve`/`ToneCurveSet`/`ToneCurveTexture`).
  - `CalibrationPlausibility` (in `ExposureUniforms.swift`): vetoes a file's own recorded color calibration when it measurably makes the image *less* neutral than doing nothing, falling back to a generic or camera-specific fallback matrix instead — a real, empirically-motivated safeguard against stale/incorrect `cmCalib` metadata some real capture files carry.
  - `CinePreviewImage`: renders one representative frame straight to a `CGImage` — the one-shot "just give me a picture" entry point (thumbnails, previews, single-frame display), as opposed to `CineRenderer` itself, which is built for sustained live/playback rendering.
  - `FrameHistogram`/`FrameHistogramComputer`: a per-channel value histogram computed from the *rendered* (post-debayer/grading/LUT) image, matching what a raw-editing tool's histogram shows.
  - Building a Metal shader inside an SPM package needs a build-tool plugin (plain `swift build` doesn't auto-compile `.metal` files the way Xcode does) — see `Plugins/MetalShaderPlugin`. An Xcode app target consuming this rendering pipeline needs its own copy of `Tonemap.metal` compiled directly into its own bundle (`Bundle.main` has no SwiftPM `Bundle.module` of its own) — see `CineRenderer.init(device:bundle:)`'s doc comment for the exact mechanism, already proven out in CinePlayer's and CineControl's own Xcode projects.

## Specification

Vision Research's own "Phantom Cine File Format" specification — publicly downloadable, no NDA or account required: <https://phantomhighspeed.my.site.com/PhantomCommunity/servlet/fileField?entityId=ka01N000000vtRkQAI&field=File_Attachments__Body__s>. Every place this package relies on it (the `SETUP` struct layout, the `CameraVersion`/`BlackLevel`/`WhiteLevel` field semantics, the P10 10-bit-to-12-bit-linear lookup table) cites it directly in that code's own doc comment, cross-checked in the LUT's case against the independent open-source [`pycine`](https://github.com/ottomatic-io/pycine) project's own byte-identical copy of the same table. Fields or behaviors this document doesn't cover (or that real files disagree with) are called out individually, in the same doc comments, as reverse-engineered/empirically-validated instead.

## Feedback and feature requests

I'd love to hear from you! If there's a `.cine`/Phantom-camera-format feature you need that isn't here yet, or something doesn't behave the way you'd expect, please open an issue — I'm always happy to take a look and see what I can add.
