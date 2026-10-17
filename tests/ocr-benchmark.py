"""Compare OCR candidates on fixtures from ocr-fixtures.ps1. Benchmark only."""
import argparse
import json
import os
from pathlib import Path
import statistics
import subprocess
import threading
import time

from PIL import Image, ImageOps

ROOT = Path(__file__).resolve().parents[1]
ARTIFACTS = ROOT / "artifacts"
FIXTURES = ARTIFACTS / "ocr-fixtures"


def distance(a, b):
    row = list(range(len(b) + 1))
    for i, x in enumerate(a, 1):
        new = [i]
        for j, y in enumerate(b, 1):
            new.append(min(new[-1] + 1, row[j] + 1, row[j - 1] + (x != y)))
        row = new
    return row[-1]


def normalized(text):
    return "".join(text.split())


def summarize(fixtures, records):
    expected = {f["name"]: f for f in fixtures}
    for mode in dict.fromkeys(r["mode"] for r in records):
        rows = [r for r in records if r["mode"] == mode]
        errors = sum(distance(normalized(expected[r["name"]]["text"]), normalized(r["text"])) for r in rows)
        chars = sum(len(normalized(expected[r["name"]]["text"])) for r in rows)
        print(f"{mode}: CER={100 * errors / chars:.2f}%, median={statistics.median(r['ms'] for r in rows):.1f} ms", flush=True)


def image_for(fixture, scale):
    image = Image.open(FIXTURES / (fixture["name"] + ".png")).convert("RGB")
    if fixture["dark"]:
        image = ImageOps.invert(image)
    if scale != 1:
        image = image.resize((image.width * scale, image.height * scale), Image.Resampling.BICUBIC)
    return image


def tesseract(fixtures):
    import psutil
    records = []
    for fixture in fixtures:
        for scale in [1, 2, 3]:
            file = ARTIFACTS / "tesseract-input.png"
            image_for(fixture, scale).save(file)
            start = time.perf_counter()
            process = subprocess.Popen(["tesseract", str(file), "stdout", "--psm", "6", "-l", "eng"], stdout=subprocess.PIPE, stderr=subprocess.PIPE, env={**os.environ, "OMP_THREAD_LIMIT": "1"})
            peak = [0]
            def sample_memory():
                child = psutil.Process(process.pid)
                while process.poll() is None:
                    try:
                        peak[0] = max(peak[0], child.memory_info().peak_wset)
                    except psutil.NoSuchProcess:
                        break
                    time.sleep(0.002)
            monitor = threading.Thread(target=sample_memory)
            monitor.start()
            output, error = process.communicate()
            elapsed_ms = (time.perf_counter() - start) * 1000
            monitor.join()
            if process.returncode:
                raise RuntimeError(error.decode("utf-8"))
            records.append({"name": fixture["name"], "mode": f"tesseract-{scale}x", "ms": elapsed_ms, "text": output.decode("utf-8").strip(), "peak_mib": peak[0] / 2**20})
    return records


def paddle(fixtures, tier, cold=False):
    import psutil
    from rapidocr import RapidOCR, ModelType, OCRVersion
    before = psutil.Process().memory_info().rss
    start = time.perf_counter()
    engine = RapidOCR(params={
        "Global.use_cls": False, "Global.log_level": "error",
        "Det.model_type": ModelType(tier), "Rec.model_type": ModelType(tier),
        "Det.ocr_version": OCRVersion("PP-OCRv6"), "Rec.ocr_version": OCRVersion("PP-OCRv6"),
        "Det.limit_type": "max", "Det.limit_side_len": 960,
        "EngineConfig.onnxruntime.intra_op_num_threads": 2,
        "EngineConfig.onnxruntime.inter_op_num_threads": 1,
    })
    load_ms = (time.perf_counter() - start) * 1000
    records = []
    for fixture in fixtures[:1] if cold else fixtures:
        for scale in [2] if cold else [1, 2, 3]:
            import numpy as np
            image = np.array(image_for(fixture, scale))[:, :, ::-1].copy()
            for repeat in range(1 if cold else 2):
                start = time.perf_counter()
                result = engine(image, use_cls=False)
                records.append({"name": fixture["name"], "mode": f"paddle-v6-{tier}-{scale}x" + ("-repeat" if repeat else ""), "ms": (time.perf_counter() - start) * 1000, "text": "\n".join(result.txts or []), "rss_mib": psutil.Process().memory_info().rss / 2**20})
    print(json.dumps({"load_ms": load_ms, "before_mib": before / 2**20, "after_mib": psutil.Process().memory_info().rss / 2**20, "peak_mib": psutil.Process().memory_info().peak_wset / 2**20}), flush=True)
    return records


def tesseract_native(fixtures):
    import ctypes as c
    import psutil
    import shutil
    os.environ["OMP_THREAD_LIMIT"] = "1"
    root = Path(shutil.which("tesseract")).parent
    before = psutil.Process().memory_info().rss
    start = time.perf_counter()
    with os.add_dll_directory(str(root)):
        dll = c.CDLL(str(root / "libtesseract-5.dll"))
    def bind(name, result, *arguments):
        function = getattr(dll, name)
        function.restype, function.argtypes = result, arguments
        return function
    create = bind("TessBaseAPICreate", c.c_void_p)
    init = bind("TessBaseAPIInit3", c.c_int, c.c_void_p, c.c_char_p, c.c_char_p)
    mode = bind("TessBaseAPISetPageSegMode", None, c.c_void_p, c.c_int)
    set_image = bind("TessBaseAPISetImage", None, c.c_void_p, c.c_void_p, c.c_int, c.c_int, c.c_int, c.c_int)
    text = bind("TessBaseAPIGetUTF8Text", c.c_void_p, c.c_void_p)
    free = bind("TessDeleteText", None, c.c_void_p)
    clear = bind("TessBaseAPIClear", None, c.c_void_p)
    delete = bind("TessBaseAPIDelete", None, c.c_void_p)
    api = create()
    records = []
    try:
        if init(api, os.fsencode(root / "tessdata"), b"eng") != 0:
            raise RuntimeError("Tesseract initialization failed")
        mode(api, 6)
        load_ms = (time.perf_counter() - start) * 1000
        for fixture in fixtures:
            image = image_for(fixture, 3)
            pixels = image.tobytes()
            for repeat in range(2):
                start = time.perf_counter()
                set_image(api, c.c_char_p(pixels), image.width, image.height, 3, image.width * 3)
                pointer = text(api)
                if not pointer:
                    raise RuntimeError("Tesseract recognition failed")
                recognized = c.string_at(pointer).decode("utf-8").strip()
                free(pointer)
                clear(api)
                records.append({"name": fixture["name"], "mode": "tesseract-native-3x" + ("-repeat" if repeat else ""), "text": recognized, "ms": (time.perf_counter()-start)*1000})
        print(json.dumps({"load_ms":load_ms,"before_mib":before/2**20,"after_mib":psutil.Process().memory_info().rss/2**20,"peak_mib":psutil.Process().memory_info().peak_wset/2**20}), flush=True)
    finally:
        delete(api)
    return records


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("engine", choices=["tesseract", "tesseract-native", "tiny", "small", "summary"])
    parser.add_argument("--cold", action="store_true", help="One first inference with cached models, at 2x scale")
    args = parser.parse_args()
    fixtures = json.loads((FIXTURES / "fixtures.json").read_text(encoding="utf-8-sig"))
    if args.engine == "summary":
        for file in ARTIFACTS.glob("ocr-*.json"):
            print(file.name)
            summarize(fixtures, json.loads(file.read_text()))
    else:
        if args.engine in ["tiny", "small"]:
            import importlib.metadata
            print(json.dumps({"rapidocr": importlib.metadata.version("rapidocr"), "onnxruntime": importlib.metadata.version("onnxruntime")}), flush=True)
        records = tesseract(fixtures) if args.engine == "tesseract" else tesseract_native(fixtures) if args.engine == "tesseract-native" else paddle(fixtures, args.engine, args.cold)
        suffix = "-cold" if args.cold else ""
        (ARTIFACTS / f"ocr-{args.engine}{suffix}.json").write_text(json.dumps(records, indent=2))
        summarize(fixtures, records)
