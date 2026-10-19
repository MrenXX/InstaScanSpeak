param([switch]$NoStart)
$ErrorActionPreference = 'Stop'
$installDir = Join-Path $env:LOCALAPPDATA 'InstaSpeak'
$sourceDir = Join-Path $PSScriptRoot 'dist\windows-x64'
$app = Join-Path $installDir 'instaspeak.exe'
$cli = Join-Path $installDir 'instaspeak-cli.exe'
foreach ($file in @('instaspeak.exe', 'instaspeak-cli.exe', 'instaspeak-ocr.exe')) {
    if (!(Test-Path -LiteralPath (Join-Path $sourceDir $file))) { throw "Missing $file. Run build.ps1 first." }
}
foreach ($file in @('resources\tiny-characters.txt','resources\Tiny OCR third-party notices.txt','install-tiny-ocr.ps1','Install Tiny OCR.cmd')) {
    if (!(Test-Path -LiteralPath (Join-Path $PSScriptRoot $file))) {throw "Missing required install file: $file"}
}
New-Item -ItemType Directory -Force -Path $installDir | Out-Null
$running = Get-Process instaspeak -ErrorAction SilentlyContinue | Where-Object { $_.Path -ieq $app }
if ($running -and (Test-Path -LiteralPath $cli)) {
    & $cli --trigger exit 2>$null
    $running | Wait-Process -Timeout 5 -ErrorAction SilentlyContinue
}
foreach ($file in @('instaspeak.exe', 'instaspeak-cli.exe', 'instaspeak-ocr.exe')) {
    Copy-Item -LiteralPath (Join-Path $sourceDir $file) -Destination $installDir -Force
    Unblock-File -LiteralPath (Join-Path $installDir $file)
}
foreach ($file in @('configure-hotkeys.ps1', 'Configure Hotkeys.cmd', 'uninstall.ps1', 'install-northern-voice.ps1', 'Install Northern English Voice.cmd', 'install-tiny-ocr.ps1', 'Install Tiny OCR.cmd')) {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $file) -Destination $installDir -Force
}
$resourceDir = Join-Path $installDir 'resources'
$tinyDir = Join-Path $installDir 'tiny-ocr'
New-Item -ItemType Directory -Force -Path $resourceDir,$tinyDir | Out-Null
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'resources\tiny-characters.txt') -Destination (Join-Path $tinyDir 'characters.txt') -Force
Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'resources\Tiny OCR third-party notices.txt') -Destination $resourceDir -Force
$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
New-Item -Path $runKey -Force | Out-Null
Set-ItemProperty -Path $runKey -Name 'InstaSpeak' -Value "`"$app`""
$shortcutPath = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\InstaSpeak.lnk'
$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = $app
$shortcut.WorkingDirectory = $installDir
$shortcut.Description = 'Copy screen text or read text aloud'
$shortcut.Save()
& $cli --version
if ($LASTEXITCODE -ne 0) { throw 'Installed app verification failed.' }
if (!$NoStart) { Start-Process -FilePath $app -WindowStyle Hidden }
Write-Host "Installed to $installDir. Starts at login."
Write-Host 'Read selection: Ctrl+Alt+S. Read screen region: Ctrl+Alt+A. Stop: Ctrl+Alt+Q.'
Write-Host 'Pause/resume speech: Ctrl+Alt+Z. Configure Hotkeys can change shortcuts.'
Write-Host 'Copy screen text: Ctrl+Alt+D. Cycle OCR language: Ctrl+Alt+W.'
Write-Host 'Right-click the tray icon for the speed slider and controls.'
