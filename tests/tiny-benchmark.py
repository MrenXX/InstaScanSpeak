"""Benchmark the shipped native helper, including BGRA transfer and preprocessing."""
import json
from pathlib import Path
import struct
import subprocess
import time
import psutil

root = Path(__file__).resolve().parents[1]
helper = root / "ocr-helper/target/release/instascanspeak-ocr.exe"
models = root / "artifacts/tiny-native/models"
fixtures = root / "artifacts/ocr-fixtures"
manifest = json.loads((fixtures / "fixtures.json").read_text(encoding="utf-8-sig"))
start = time.perf_counter()
process = subprocess.Popen([str(helper), str(models)], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE)
child = psutil.Process(process.pid)
records = []
try:
    for fixture in manifest:
        pixels = (fixtures / (fixture["name"] + ".bgra")).read_bytes()
        for repeat in range(2):
            begin = time.perf_counter()
            process.stdin.write(struct.pack("<II", fixture["width"], fixture["height"]) + pixels)
            process.stdin.flush()
            response = process.stdout.readline()
            if not response:
                raise RuntimeError(process.stderr.read().decode("utf-8", errors="replace"))
            result = json.loads(response)
            if "error" in result:
                raise RuntimeError(result["error"])
            result.update(name=fixture["name"], mode="tiny-native" + ("-repeat" if repeat else ""), parent_ms=(time.perf_counter()-begin)*1000)
            if not records:
                result["cold_from_process_start_ms"] = (time.perf_counter()-start)*1000
            records.append(result)
    memory = child.memory_info()
    print(json.dumps({"working_set_mib": memory.rss/2**20, "private_mib": memory.private/2**20, "peak_mib": memory.peak_wset/2**20, "cold_ms":records[0]["cold_from_process_start_ms"]}), flush=True)
    (root / "artifacts/tiny-native/results.json").write_text(json.dumps(records, indent=2))
    (root / "artifacts/tiny-native/memory.json").write_text(json.dumps({"working_set_mib":memory.rss/2**20,"private_mib":memory.private/2**20,"peak_mib":memory.peak_wset/2**20}))
    import runpy
    runpy.run_path(str(root / "tests/ocr-benchmark.py"))["summarize"](manifest, records)
finally:
    process.stdin.close()
    try:
        process.wait(timeout=5)
    except subprocess.TimeoutExpired:
        process.kill()
