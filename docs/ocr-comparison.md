# Small-font OCR comparison

Measured on 17 October 2026, Windows 11 x64, AMD Ryzen 5 7600. These are local CPU measurements, not upstream benchmark claims. Downloaded models stay under the ignored `artifacts` directory. The app still uses Windows OCR in v0.4.1.

PP-OCRv6 Tiny is the best accuracy and speed tradeoff in this test. Persistent Tesseract is a close alternative with lower measured memory use. PP-OCRv6 Small provides a smaller accuracy gain at roughly three times Tiny's latency.

## Results

The [results JSON](ocr-results-2026-10-17.json) contains counts and breakdowns for ordinary prose, difficult characters and code, and the smallest fonts.

- Windows OCR, current preprocessing. Median 19.8 ms, 21.08% character errors across all samples, 6.18% on ordinary prose. No download.
- Tesseract 5.5 through its persistent native C API, 3x enlargement. Median 60.0 ms, 2.71% character errors, 0.30% on ordinary prose. English weights are 3.92 MiB, excluding its runtime.
- PP-OCRv6 Tiny, 2x enlargement. Median 59.3 ms, 1.62% character errors, 0.19% on ordinary prose. Detection and recognition weights total 6.03 MiB, excluding its runtime.
- PP-OCRv6 Small, original scale. Median 171.5 ms, 1.08% character errors, 0.03% on ordinary prose. Weights total 29.72 MiB, excluding its runtime.

Those are the first reads of each new image with an already loaded model. Repeating the identical image gave medians of 47.6 ms for Tiny and 146.8 ms for Small. Tesseract remained around 60 ms. Starting a separate Tesseract CLI process per image took 184.6 ms, so a persistent native API is the relevant comparison for integration.

The current Windows engine and both Paddle models produced identical text on every identical repeat. This does not reproduce reports of differing screen captures. Different selection bounds, pixels and application state remain untested causes. No automatic `I`, `l`, or `1` substitution was added.

## Memory and startup

These figures describe complete benchmark processes, using working-set memory:

- Native Windows OCR test. 9.6 MiB before recognition, 21.4 MiB afterward, 39.3 MiB peak. The peak includes experimental scaling variants.
- Persistent native Tesseract through Python. 26.2 MiB before loading the DLL/model, 58.6 MiB afterward, 63.5 MiB peak. Model/runtime initialization took 55.6 ms, excluding Python startup.
- Tiny through Python/RapidOCR. 63.5 MiB before the model sessions, 106.7 MiB afterward, 157.9 MiB peak across the full scaling comparison. A separate cached cold-read process took 172.4 ms for initialization plus its first 2x inference, excluding Python startup.
- Small through Python/RapidOCR. 63.7 MiB before sessions, 134.2 MiB afterward, 344.9 MiB peak. Cached initialization plus first 2x inference took 343.6 ms, excluding Python startup.

The runtimes differ. These results do not establish native Rust memory use for Paddle models. A native integration must measure its own cold start, memory, cancellation and idle unloading before becoming the default. Benchmark downloads add no background process to the installed app.

## Method and limits

The fixture generator uses Windows TextRenderer and installed Segoe UI, Arial and Consolas fonts at 9, 11, 14 and 18 physical pixels, with light and dark backgrounds. Each image has three text lines. There are 24 ordinary-prose images and 24 images with deliberately difficult identifiers, digits, punctuation and code. Each engine receives the same 48 source images, totaling 6,864 non-whitespace characters.

Character error rate is Levenshtein distance divided by expected character count. Whitespace is removed. Case, punctuation, missing lines and reading-order mistakes count. This intentionally difficult, small corpus is not a general accuracy rating, and no model was trained on it. Some fonts draw confusable characters with nearly identical shapes.

Windows OCR uses en-US and the production preprocessing. Tesseract uses the installed 5.5.0 DLL, its English model, page-segmentation mode 6 and one OpenMP thread. RapidOCR 3.10.0 uses ONNX Runtime 1.31.0 on CPU with two intra-op threads and one inter-op thread. Orientation classification is disabled. Its detector uses a maximum side length of 960. Tiny and Tesseract inputs invert dark backgrounds before enlargement. Pipeline inference timings exclude capture, speech, Python startup and model downloads. Fixture image loading and enlargement are outside the alternative-engine inference timers; these are OCR timings rather than end-to-end app timings.

Other Windows scaling variants reduced the total error rate as far as 15.91%, but remained behind the open-source candidates. Production OCR preprocessing is unchanged in this fix release.

## Reproduce

Use an otherwise idle Windows machine and run these sequentially. Python, Pillow, psutil, and Tesseract are benchmark prerequisites, not app requirements. The downloaded RapidOCR models are verified against the hashes in its model registry.

```powershell
powershell -NoProfile -ExecutionPolicy Bypass -File tests/ocr-fixtures.ps1
cargo test --release --locked benchmark_screen_fonts -- --ignored
python tests/ocr-benchmark.py tesseract
python tests/ocr-benchmark.py tesseract-native
python -m venv artifacts/ocr-bench-env
artifacts/ocr-bench-env/Scripts/python.exe -m pip install rapidocr==3.10.0 onnxruntime==1.31.0 pillow psutil
artifacts/ocr-bench-env/Scripts/python.exe tests/ocr-benchmark.py tiny
artifacts/ocr-bench-env/Scripts/python.exe tests/ocr-benchmark.py small
artifacts/ocr-bench-env/Scripts/python.exe tests/ocr-benchmark.py tiny --cold
artifacts/ocr-bench-env/Scripts/python.exe tests/ocr-benchmark.py small --cold
```

Raw per-image results appear in `artifacts/ocr-*.json`. Native Tesseract benchmarking expects `libtesseract-5.dll` and `tessdata` beside the Tesseract executable found on PATH.

## Sources

- [PaddleOCR PP-OCRv6](https://github.com/PaddlePaddle/PaddleOCR/blob/main/docs/version3.x/algorithm/PP-OCRv6/PP-OCRv6.en.md), model family and supported deployment targets.
- [RapidOCR model registry](https://github.com/RapidAI/RapidOCR/blob/main/python/rapidocr/default_models.yaml), pinned download URLs and hashes.
- [Tesseract C API](https://github.com/tesseract-ocr/tesseract/blob/main/include/tesseract/capi.h), persistent engine lifecycle.
- [New Windows text-recognition API](https://learn.microsoft.com/en-us/windows/ai/apis/text-recognition), requires an NPU. It cannot replace the current API on every Windows machine.

Tiny hashes downloaded for this test:

```text
PP-OCRv6_det_tiny.onnx  f42c0fbd294d95eac1a550e131b277dac97462c8025fa4b6c3cec1b7894bd3d5
PP-OCRv6_rec_tiny.onnx  e16e242de5937ad92609223f19bc2aff3727ee40b095f996907c24749bad251b
```
