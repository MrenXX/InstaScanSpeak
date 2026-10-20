# Native Tiny OCR

InstaScanSpeak v0.5 adds PP-OCRv6 Tiny as an optional local engine. Run `Install Tiny OCR.cmd` after installing the app. The installer selects Tiny. Existing voice, rate and hotkey preferences stay unchanged.

The tray's `OCR engine` selector switches both capture actions. `Ctrl+Alt+D` still copies OCR text, `Ctrl+Alt+A` reads it, and `Ctrl+Alt+Q` cancels OCR or speech. `Ctrl+Alt+W` retains the Windows OCR language preference. Tiny recognizes its supported languages automatically.

## Native measurements

Measured on the same Windows 11 / Ryzen 5 7600 machine and 48 Windows-rendered fixtures as the [earlier comparison](ocr-comparison.md). This time the compiled Rust helper receives raw BGRA pixels through a local pipe. Timings include its RGB conversion, background inversion, enlargement, detection, line cropping, recognition and text assembly.

- 1.72% character errors on 6,864 expected non-whitespace characters. The earlier Python pipeline scored 1.62%. No substitutions or language-model corrections are applied.
- Median 58.1 ms for each new image with a loaded model, 46.7 ms for immediately repeated images.
- About 45 MiB helper working set after the fixture run, about 30 MiB private memory, and an 89 MiB peak. The helper used about 42 MiB in the live tray capture test.
- Initial reads also pay process, DLL and model startup costs. They vary with filesystem cache and system load. The full fixture benchmark's first read took 1.39 seconds; a subsequent new helper in the tray test completed its first capture OCR in about 216 ms. Warm timings are not cold-start promises.

The runtime's CPU memory arena is disabled to avoid retaining its largest buffers. With default arena retention, the helper held about 152 MiB, though median inference was faster at 43 ms. The chosen configuration uses memory-pattern optimization and two CPU threads per inference session, plus a two-thread preprocessing pool. It keeps repeat captures fast without the larger retained working set.

After 30 seconds without OCR commands, the helper exits and Windows releases its model/runtime allocations. Switching to Windows OCR releases it immediately. Stop kills active Tiny inference, and cancelled or older requests cannot start speech later. The helper belongs to a kill-on-close Windows job object.

## Files and downloads

The small app package includes `instascanspeak-ocr.exe`, a roughly 1.2 MB native Rust helper. The main tray executable does not link ONNX Runtime or the OCR model libraries.

Optional assets install under `%LOCALAPPDATA%\InstaScanSpeak\tiny-ocr`:

- `det.onnx`, 1,829,618 bytes.
- `rec.onnx`, 4,489,813 bytes.
- `characters.txt`, the character dictionary from the recognition model metadata.
- `onnxruntime.dll` and `onnxruntime_providers_shared.dll`, about 17 MiB together.
- Upstream runtime licenses, dependency notices and attribution.

The installer downloads from the pinned RapidOCR v3.10.0 registry and Microsoft ONNX Runtime v1.31.0 release. It verifies SHA-256 hashes before changing an active installation. The 79 MiB upstream runtime archive contains development files too; the installer extracts only the DLLs and notices, then deletes that archive. Re-running the installer checks installed runtime hashes and skips its download when they match.

It uses the native helper and CPU ONNX Runtime. Python, a GPU and an NPU are not required. ONNX Runtime requires the Microsoft Visual C++ x64 runtime. The installer tests initialization before selecting Tiny and reports the official runtime download if initialization fails. No captured text leaves the computer.

## Implementation and checks

`ocr-helper` is a separate Rust package using OAR OCR Core 0.10.0 and ort 2.0.0-rc.13 with dynamic loading. Detection uses PP-OCRv6's 0.5 mean/std normalization, 0.3 pixel threshold, 0.5 box threshold, 1.6 expansion ratio, dilation and a maximum detector side of 960. Recognition uses the model's character dictionary. Dark backgrounds are inverted; crops up to 1200 pixels on their longest side enlarge 2x before recognition.

The helper accepts an eight-byte little-endian width/height header and BGRA bytes, then returns one UTF-8 JSON line. This avoids PNG encoding and temporary image files. Only the OCR worker blocks on the helper. The UI can stop it independently.

`tests/tiny.ps1` verifies live copy/read captures, Northern English Male playback, the tray engine switch, saved preferences, warm reuse, idle unload, cancellation before OCR completes, recovery and cleanup on abrupt parent termination. It isolates app settings and restores clipboard contents. `tests/tiny-benchmark.py` records native latency, accuracy and memory under `artifacts/tiny-native`.

The source build needs a C compiler for helper dependencies. `build.ps1` builds both packages. Refresh `resources/Tiny OCR third-party notices.txt` with `python ocr-helper/generate-notices.py` after changing the helper lockfile.

Sources: [PaddleOCR](https://github.com/PaddlePaddle/PaddleOCR), [RapidOCR model registry](https://github.com/RapidAI/RapidOCR/blob/main/python/rapidocr/default_models.yaml), [OAR OCR](https://github.com/GreatV/oar-ocr), [ONNX Runtime v1.31.0](https://github.com/microsoft/onnxruntime/releases/tag/v1.31.0).
