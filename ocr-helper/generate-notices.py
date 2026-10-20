"""Refresh the committed dependency notices after changing Cargo.lock."""
import json
from pathlib import Path
import shutil
import subprocess

root = Path(__file__).resolve().parents[1]
cargo = shutil.which("cargo") or str(Path.home()/".cargo/bin/cargo.exe")
metadata = json.loads(subprocess.check_output([cargo,"metadata","--manifest-path",str(root/"ocr-helper/Cargo.toml"),"--format-version","1","--locked","--filter-platform","x86_64-pc-windows-gnu"]))
included = {node["id"] for node in metadata["resolve"]["nodes"]}
sections = ["InstaScanSpeak Tiny OCR helper dependency notices. Models and ONNX Runtime have separate upstream notices.\n"]
for package in sorted(metadata["packages"], key=lambda p:p["name"]):
    if package["id"] not in included or package["name"] == "instascanspeak-ocr":
        continue
    sections.append(f"\n{'='*60}\n{package['name']} {package['version']}\nLicense: {package.get('license')}\nSource: {package.get('repository') or package['source']}\n")
    directory = Path(package["manifest_path"]).parent
    for file in sorted(directory.iterdir()):
        if file.is_file() and file.name.upper().startswith(("LICENSE","COPYING","NOTICE","UNLICENSE")):
            sections.append(file.name+"\n"+file.read_text(encoding="utf-8",errors="replace"))
(root/"resources/Tiny OCR third-party notices.txt").write_text("\n".join(sections),encoding="utf-8")
print(f"Wrote notices for {len(included)-1} packages")
