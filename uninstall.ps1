$ErrorActionPreference = 'Stop'
$installDir = [IO.Path]::GetFullPath((Join-Path $env:LOCALAPPDATA 'InstaSpeak'))
$expected = [IO.Path]::GetFullPath($env:LOCALAPPDATA).TrimEnd('\') + '\InstaSpeak'
if ($installDir -ine $expected) { throw 'Unexpected installation path.' }
$cli = Join-Path $installDir 'instaspeak-cli.exe'
$running = Get-Process instaspeak -ErrorAction SilentlyContinue |
    Where-Object { $_.Path -ieq (Join-Path $installDir 'instaspeak.exe') }
if ($running -and (Test-Path -LiteralPath $cli)) {
    & $cli --trigger exit 2>$null
    $running | Wait-Process -Timeout 5 -ErrorAction SilentlyContinue
}
Remove-ItemProperty -Path 'HKCU:\Software\Microsoft\Windows\CurrentVersion\Run' -Name 'InstaSpeak' -ErrorAction SilentlyContinue
Remove-Item -LiteralPath (Join-Path $env:APPDATA 'Microsoft\Windows\Start Menu\Programs\InstaSpeak.lnk') -ErrorAction SilentlyContinue
if (Test-Path -LiteralPath $installDir) { Remove-Item -LiteralPath $installDir -Recurse -Force }
Write-Host 'InstaSpeak removed. Your settings remain in %APPDATA%\InstaSpeak.'
