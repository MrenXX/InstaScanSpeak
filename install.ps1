param([switch]$NoStart)
$ErrorActionPreference = 'Stop'
$installDir = Join-Path $env:LOCALAPPDATA 'InstaSpeak'
$sourceDir = Join-Path $PSScriptRoot 'dist\windows-x64'
$app = Join-Path $installDir 'instaspeak.exe'
$cli = Join-Path $installDir 'instaspeak-cli.exe'
foreach ($file in @('instaspeak.exe', 'instaspeak-cli.exe')) {
    if (!(Test-Path -LiteralPath (Join-Path $sourceDir $file))) { throw "Missing $file. Run build.ps1 first." }
}
New-Item -ItemType Directory -Force -Path $installDir | Out-Null
if (Test-Path -LiteralPath $cli) {
    & $cli --trigger exit 2>$null
    Get-Process instaspeak -ErrorAction SilentlyContinue |
        Where-Object { $_.Path -ieq $app } | Wait-Process -Timeout 5 -ErrorAction SilentlyContinue
}
foreach ($file in @('instaspeak.exe', 'instaspeak-cli.exe')) {
    Copy-Item -LiteralPath (Join-Path $sourceDir $file) -Destination $installDir -Force
    Unblock-File -LiteralPath (Join-Path $installDir $file)
}
foreach ($file in @('configure-hotkeys.ps1', 'Configure Hotkeys.cmd', 'uninstall.ps1')) {
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot $file) -Destination $installDir -Force
}
$runKey = 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run'
New-Item -Path $runKey -Force | Out-Null
Set-ItemProperty -Path $runKey -Name 'InstaSpeak' -Value "`"$app`""
$shortcutPath = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\InstaSpeak.lnk'
$shell = New-Object -ComObject WScript.Shell
$shortcut = $shell.CreateShortcut($shortcutPath)
$shortcut.TargetPath = $app
$shortcut.WorkingDirectory = $installDir
$shortcut.Description = 'Read selected text or screen text aloud'
$shortcut.Save()
if (!$NoStart) { Start-Process -FilePath $app -WindowStyle Hidden }
Write-Host "Installed to $installDir. Starts at login."
Write-Host 'Read selection: Ctrl+Alt+S. Read screen region: Ctrl+Alt+A. Stop: Ctrl+Alt+Q.'
