# InstaSpeak

A small Windows tray app that copies text from screen regions and reads highlighted or captured text aloud.

Built in Rust with Win32, Windows OCR, Windows SAPI speech, and an optional local Piper voice. No browser runtime, cloud service, or account is required. Text stays on your computer.

This is the combined OCR and speech project. Copy-only capture and read-aloud capture share one OCR implementation and worker. It includes InstOCR's native capture and OCR code, with no separate InstOCR process required. The original `instocr-rust` repository remains separate.

## Install

Download the Windows ZIP from [Releases](https://github.com/MrenXX/instaspeak-rust/releases), extract it, and run `Install InstaSpeak.cmd`.

The installer copies the app to `%LOCALAPPDATA%\InstaSpeak`, adds a Start menu shortcut, enables startup at login, and launches the tray app. It does not need administrator rights.

To run without installing, open `dist\windows-x64\instaspeak.exe`.

To add Northern English Male, run `Install Northern English Voice.cmd` after installing the app. It downloads a verified 63 MB voice model and a 22 MB native runtime directly from their upstream projects, selects the voice, and restarts an active installed app. Later reads work offline. The model and runtime stay installed across app updates and are not bundled into the small app ZIP.

## Use

- Highlight text, then press `Ctrl+Alt+S` to read it.
- Press `Ctrl+Alt+A`, drag around screen text, and release to read it.
- Press `Ctrl+Alt+D`, drag around screen text, and release to copy it without starting speech.
- Press `Ctrl+Alt+Q` to stop. This also cancels pending reading requests.
- Press `Ctrl+Alt+W` to cycle the OCR language.
- Right-click the tray icon for the inline speed slider, capture actions, voice and OCR-language selectors, startup, and Exit.

The slider is immediately visible in the right-click tray panel. It covers all 21 speech-rate steps, from -10 to +10, with 0 as normal. Arrow keys move one step; Home and End jump to the limits. Changes save automatically. Windows voices update immediately. The neural voice applies speed changes at the next short section of text, preserving its pitch. Escape or clicking outside dismisses the panel.

Escape or right-click cancels a screen selection. A new reading request replaces the current speech.

The copy and language shortcuts are the original InstOCR defaults. Exit the standalone InstOCR app before using them here. Run `Configure Hotkeys.cmd` to change shortcuts, then restart. `instaspeak-cli.exe --restore-ocr-hotkeys` imports the original InstOCR shortcut preferences when available. Settings are stored in `%APPDATA%\InstaSpeak\rust-settings.txt`.

## Voices and compatibility

Installed Windows SAPI voices, such as David, Zira, and Hortense, remain available. They use less memory while speaking. The list can differ from Narrator or Windows speech settings.

Northern English Male is an optional English UK neural voice. Its helper starts on the first read, stays warm for repeat reads, and exits after 30 seconds idle. Stop cancels synthesis and playback. The helper also exits if the app is terminated, so a model process does not remain in the background. Only the selected voice is loaded.

Highlighted text works with standard Windows edit controls and apps that expose their selection through UI Automation. Some custom controls, browsers, PDF viewers, and elevated apps may not expose it. Use screen capture in those cases. Read-aloud actions leave the clipboard unchanged. Only copy-only capture writes recognized text to it.

The [Northern English Male model card](https://huggingface.co/rhasspy/piper-voices/tree/main/en/en_GB/northern_english_male/medium) identifies the voice dataset as CC-BY-SA 4.0 International. Its attribution is installed alongside the model. Other voices in the [Piper samples](https://rhasspy.github.io/piper-samples/) and [Kokoro catalog](https://huggingface.co/hexgrad/Kokoro-82M/blob/main/VOICES.md) remain candidates for future integration.

OCR uses your installed Windows OCR languages. Add the relevant Windows language capability if a language is missing. Speech voice and OCR language are separate choices. Mixed-DPI multi-monitor capture needs more testing. The original InstOCR capture code targets a single monitor or monitors with the same scale.

The build is unsigned, so Windows may show a SmartScreen prompt.

## Performance

Measured on the development Windows 11 machine, not a guarantee for other hardware:

- Tray executable, roughly 510 KiB.
- Initial idle working set, roughly 12 MiB. Private bytes, roughly 1.9 MiB.
- After reading, copying, and idle cleanup, roughly 29 MiB working set and 6.6 MiB private bytes.
- SAPI speech stream startup, 122 ms for the first read and about 15 ms for repeated reads in the standalone benchmark.
- A test screen region took 115 ms to capture and recognize. The warm OCR step in the tray app took 53 ms.
- Northern English Male generated its first short audio in about 352 ms cold and 60 ms warm. The helper used about 95 MiB while loaded and released that memory after idle.
- Native themed controls opened in about 27 ms, matching the classic controls in an A/B check. They added about 0.2 MiB of mapped working-set memory, with no measured private-memory increase. Styling uses the Windows common-controls library.

Stream-start timings exclude the sound device's output buffer. Memory rises while reading or capturing. OCR engines and completed speech objects are released after an idle period, but Windows can retain mapped libraries and cached pages. The app does not trim its working set to make the reported number smaller.

## Build and verify

Requires Windows 10 or 11 x64 and a Rust toolchain. The GNU toolchain includes the required linker. The MSVC toolchain requires Visual Studio C++ Build Tools.

```powershell
.\build.ps1
.\dist\windows-x64\instaspeak-cli.exe --list-voices
.\dist\windows-x64\instaspeak-cli.exe --list-languages
.\dist\windows-x64\instaspeak-cli.exe --benchmark
.\dist\windows-x64\instaspeak-cli.exe --benchmark-neural
powershell -NoProfile -STA -ExecutionPolicy Bypass -File .\tests\integration.ps1
powershell -NoProfile -STA -ExecutionPolicy Bypass -File .\tests\neural.ps1
```

The integration test opens temporary Windows forms and starts a diagnostic tray instance with isolated settings. Exit any running InstaSpeak instance first. It tests selected text, registered hotkeys, the inline tray slider and saved rate, live changes, popup dismissal, both capture actions, OCR, speech, cancellation, clipboard behavior, and memory after idle. It restores the original clipboard after testing copy-only capture. It requires an unlocked desktop with an audio output device. Avoid interacting with the desktop while it runs.

The neural test requires the optional voice. It checks real playback, warm model reuse, idle unloading, rate changes, stop responsiveness, and cleanup after an abrupt parent-process exit.

Other diagnostics include `--speak TEXT`, `--read-selection`, `--capture-rect X Y W H`, `--validate-hotkey HOTKEY`, `--set-voice ID`, `--restore-ocr-hotkeys`, and `--trigger selected|capture|copy|stop|exit`. Rectangle coordinates use physical pixels. `--resident` runs the tray app with console diagnostics. Diagnostics print recognized or selected text when explicitly requested. The neural helper writes temporary audio files and the app deletes them before playback.

To uninstall, run `uninstall.ps1`. Settings remain in your AppData folder.

## Credits

The native capture, OCR, hotkey parsing, and tray code derive from [MrenXX/instocr-rust](https://github.com/MrenXX/instocr-rust), used under its MIT license. The original copyright notice remains in `LICENSE`.
