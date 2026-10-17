@echo off
powershell -NoProfile -ExecutionPolicy Bypass -File "%~dp0install-tiny-ocr.ps1" -SelectEngine
pause
