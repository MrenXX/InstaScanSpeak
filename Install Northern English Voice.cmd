@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install-northern-voice.ps1" -SelectVoice
pause
