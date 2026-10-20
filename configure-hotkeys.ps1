$ErrorActionPreference = 'Stop'
$cli = Join-Path $env:LOCALAPPDATA 'InstaSpeak\instascanspeak-cli.exe'
if (!(Test-Path -LiteralPath $cli)) { $cli = Join-Path $PSScriptRoot 'dist\windows-x64\instascanspeak-cli.exe' }
if (!(Test-Path -LiteralPath $cli)) { throw 'Build or install InstaScanSpeak first.' }
$settingsPath = Join-Path $env:APPDATA 'InstaSpeak\rust-settings.txt'
$settings = [ordered]@{ language_tag=''; capture_hotkey='Ctrl+Alt+A'; copy_hotkey='Ctrl+Alt+D'; cycle_hotkey='Ctrl+Alt+W'; selected_hotkey='Ctrl+Alt+S'; stop_hotkey='Ctrl+Alt+Q'; pause_hotkey='Ctrl+Alt+Z'; voice_id=''; rate='0'; ocr_engine='windows' }
if (Test-Path -LiteralPath $settingsPath) {
    foreach ($line in Get-Content -LiteralPath $settingsPath) {
        $parts = $line.Split('=', 2)
        if ($parts.Count -eq 2 -and $settings.Contains($parts[0])) { $settings[$parts[0]] = $parts[1] }
    }
}
$chosen = @()
foreach ($key in @('selected_hotkey','capture_hotkey','copy_hotkey','stop_hotkey','cycle_hotkey','pause_hotkey')) {
    do {
        $value = Read-Host "$key [$($settings[$key])]"
        if ([string]::IsNullOrWhiteSpace($value)) { $value = $settings[$key] }
        $normalized = & $cli --validate-hotkey $value 2>&1
        $valid = $LASTEXITCODE -eq 0 -and $chosen -notcontains "$normalized"
        if (!$valid) { Write-Host "Invalid or duplicate hotkey: $normalized" }
    } while (!$valid)
    $settings[$key] = "$normalized"
    $chosen += "$normalized"
}
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $settingsPath) | Out-Null
$lines = foreach ($key in $settings.Keys) { "$key=$($settings[$key])" }
[IO.File]::WriteAllLines($settingsPath, [string[]]$lines, [Text.UTF8Encoding]::new($false))
Write-Host 'Saved. Exit InstaScanSpeak from its tray menu and start it again to apply the hotkeys.'
