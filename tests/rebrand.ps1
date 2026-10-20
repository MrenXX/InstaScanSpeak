$ErrorActionPreference = 'Stop'
$projectDir = Split-Path -Parent $PSScriptRoot
$fixture = Join-Path $projectDir "artifacts\rebrand-install-$PID"
$savedAppData = $env:APPDATA
$savedLocalAppData = $env:LOCALAPPDATA
$global:InstaScanSpeakTestStartup = @{InstaSpeak='legacy-app.exe'}

# Keep installer registry operations inside this test process.
function Set-ItemProperty {
    [CmdletBinding()]
    param($Path, $Name, $Value)
    if ($Path -ne 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run') {throw 'Unexpected registry path'}
    $global:InstaScanSpeakTestStartup[$Name] = $Value
}
function Remove-ItemProperty {
    [CmdletBinding()]
    param($Path, $Name)
    if ($Path -ne 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run') {throw 'Unexpected registry path'}
    $global:InstaScanSpeakTestStartup.Remove($Name)
}
function New-Item {
    [CmdletBinding()]
    param([string[]]$Path, $ItemType, [switch]$Force)
    if ($Path.Count -eq 1 -and $Path[0] -eq 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run') {return}
    Microsoft.PowerShell.Management\New-Item @PSBoundParameters
}

try {
    $env:APPDATA = Join-Path $fixture 'roaming'
    $env:LOCALAPPDATA = Join-Path $fixture 'local'
    $installDir = Join-Path $env:LOCALAPPDATA 'InstaSpeak'
    $profileDir = Join-Path $env:APPDATA 'InstaSpeak'
    $programs = Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs'
    New-Item -ItemType Directory -Force -Path $installDir,$profileDir,$programs,(Join-Path $installDir 'voices'),(Join-Path $installDir 'tiny-ocr') | Out-Null
    $settings = Join-Path $profileDir 'rust-settings.txt'
    $preferences = "pause_hotkey=Ctrl+Alt+R`ncopy_hotkey=Ctrl+Alt+D`ncycle_hotkey=Ctrl+Alt+W`nvoice_id=piper:northern-english-male`nrate=4`nocr_engine=tiny`n"
    [IO.File]::WriteAllText($settings,$preferences)
    [IO.File]::WriteAllText((Join-Path $installDir 'voices\keep.onnx'),'existing voice')
    [IO.File]::WriteAllText((Join-Path $installDir 'tiny-ocr\det.onnx'),'existing OCR model')
    foreach ($name in @('instaspeak.exe','instaspeak-cli.exe','instaspeak-ocr.exe','instaspeak.ico')) {
        [IO.File]::WriteAllText((Join-Path $installDir $name),'legacy file')
    }
    [IO.File]::WriteAllText((Join-Path $programs 'InstaSpeak.lnk'),'legacy shortcut')

    & (Join-Path $projectDir 'install.ps1') -NoStart
    if ([IO.File]::ReadAllText($settings) -cne $preferences) {throw 'Upgrade changed preferences'}
    if ([IO.File]::ReadAllText((Join-Path $installDir 'voices\keep.onnx')) -ne 'existing voice') {throw 'Voice removed'}
    if ([IO.File]::ReadAllText((Join-Path $installDir 'tiny-ocr\det.onnx')) -ne 'existing OCR model') {throw 'OCR model removed'}
    foreach ($name in @('instascanspeak.exe','instascanspeak-cli.exe','instascanspeak-ocr.exe','instascanspeak.ico')) {
        if (!(Test-Path -LiteralPath (Join-Path $installDir $name))) {throw "Missing $name"}
    }
    if ($global:InstaScanSpeakTestStartup.ContainsKey('InstaSpeak') -or !$global:InstaScanSpeakTestStartup.ContainsKey('InstaScanSpeak')) {throw 'Startup entry migration failed'}
    if ((Test-Path -LiteralPath (Join-Path $programs 'InstaSpeak.lnk')) -or !(Test-Path -LiteralPath (Join-Path $programs 'InstaScanSpeak.lnk'))) {throw 'Shortcut migration failed'}
    if (Test-Path -LiteralPath (Join-Path $installDir 'instaspeak.exe')) {throw 'Legacy app binary remains'}

    & (Join-Path $projectDir 'uninstall.ps1')
    if (Test-Path -LiteralPath $installDir) {throw 'Uninstall retained app files'}
    if ([IO.File]::ReadAllText($settings) -cne $preferences) {throw 'Uninstall changed preferences'}
    Write-Host 'PASS rebrand upgrade, retained profiles/models, startup and shortcut migration, and uninstall.'
} finally {
    $env:APPDATA=$savedAppData
    $env:LOCALAPPDATA=$savedLocalAppData
    $resolved=[IO.Path]::GetFullPath($fixture)
    $allowed=[IO.Path]::GetFullPath((Join-Path $projectDir 'artifacts')).TrimEnd('\') + '\'
    if (!$resolved.StartsWith($allowed,[StringComparison]::OrdinalIgnoreCase)) {throw 'Unexpected test cleanup path'}
    if (Test-Path -LiteralPath $resolved) {Remove-Item -LiteralPath $resolved -Recurse -Force}
}
