"""Verify pause shortcut configuration without changing the user's settings."""
import os
from pathlib import Path
import subprocess

root=Path(__file__).resolve().parents[1]
appdata=root/"artifacts/hotkey-config-appdata"
settings=appdata/"InstaSpeak/rust-settings.txt"
settings.parent.mkdir(parents=True,exist_ok=True)
original={"capture_hotkey":"Ctrl+Alt+A","copy_hotkey":"Ctrl+Alt+D","cycle_hotkey":"Ctrl+Alt+W","selected_hotkey":"Ctrl+Alt+P","stop_hotkey":"Ctrl+Alt+Q","voice_id":"piper:northern-english-male","rate":"4","ocr_engine":"tiny"}
settings.write_text("".join(f"{key}={value}\n" for key,value in original.items()))
result=subprocess.run(["powershell","-NoProfile","-ExecutionPolicy","Bypass","-File",str(root/"configure-hotkeys.ps1")],input="\n"*5+"Ctrl+Alt+R\n",capture_output=True,text=True,env={**os.environ,"APPDATA":str(appdata)},timeout=20)
if result.returncode:
    raise RuntimeError(result.stdout+result.stderr)
after=dict(line.split("=",1) for line in settings.read_text(encoding="utf-8-sig").splitlines())
for key,value in original.items():
    assert after[key]==value,f"Configuration changed {key}"
assert after["pause_hotkey"]=="Ctrl+Alt+R"
print("PASS custom pause shortcut and all existing hotkeys, Tiny selection, voice and rate preserved")
