$ErrorActionPreference = 'Stop'
$projectDir = Split-Path -Parent $PSScriptRoot
$cli = Join-Path $projectDir 'dist\windows-x64\instaspeak-cli.exe'
$artifacts = Join-Path $projectDir 'artifacts'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -Path (Join-Path $PSScriptRoot 'native-test.cs')
[TestNative]::SetProcessDpiAwarenessContext([IntPtr](-4)) | Out-Null
$previous = [TestNative]::GetForegroundWindow()
$originalAppData = $env:APPDATA
$env:APPDATA = Join-Path $artifacts 'neural-test-appdata'
$settingsDir = Join-Path $env:APPDATA 'InstaSpeak'
New-Item -ItemType Directory -Force -Path $settingsDir | Out-Null
[IO.File]::WriteAllText((Join-Path $settingsDir 'rust-settings.txt'), "voice_id=piper:northern-english-male`nrate=0`n",[Text.UTF8Encoding]::new($false))
$statePath = Join-Path $artifacts 'neural-fixture.json'
$logPath = Join-Path $artifacts 'neural-resident.log'
$resident = $null
$fixture = $null
function Wait-For($condition,$description,$seconds=15) {
    $deadline = [DateTime]::UtcNow.AddSeconds($seconds)
    do { if (& $condition) { return }; Start-Sleep -Milliseconds 50 } while ([DateTime]::UtcNow -lt $deadline)
    throw "Timed out: $description"
}
function Read-Selected {
    [TestNative]::FocusFixture([IntPtr]$state.form,[IntPtr]$state.input)
    [TestNative]::SendMessage([IntPtr]$state.input,0xB1,[IntPtr]0,[IntPtr](-1)) | Out-Null
    & $cli --trigger selected
}
function Last-Helper {
    $matches = [regex]::Matches((Get-Content -LiteralPath $logPath -Raw),'neural_helper_pid=(\d+)')
    if ($matches.Count -eq 0) { return 0 }
    return [int]$matches[$matches.Count-1].Groups[1].Value
}
try {
    if (Test-Path -LiteralPath $statePath) { Remove-Item -LiteralPath $statePath }
    $resident = Start-Process -FilePath $cli -ArgumentList '--resident' -WindowStyle Hidden -PassThru -RedirectStandardOutput $logPath -RedirectStandardError (Join-Path $artifacts 'neural-resident-error.log')
    Wait-For { [TestNative]::FindWindow('InstaSpeakRustHiddenWindow',$null) -ne [IntPtr]::Zero } 'resident startup'
    $fixture = Start-Process powershell -ArgumentList @('-NoProfile','-STA','-ExecutionPolicy','Bypass','-File',"`"$(Join-Path $PSScriptRoot 'fixture.ps1')`"",'-StatePath',"`"$statePath`"") -WindowStyle Hidden -PassThru
    Wait-For { Test-Path -LiteralPath $statePath } 'fixture startup'
    $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    [TestNative]::ShowWindow([IntPtr]$state.form,5) | Out-Null
    Read-Selected
    Wait-For { (Get-Content -LiteralPath $logPath -Raw) -match 'neural_finished=true' } 'neural audio playback'
    $helperId = Last-Helper
    if (!(Get-Process -Id $helperId -ErrorAction SilentlyContinue)) { throw 'Voice helper was not retained for warm reads' }
    Read-Selected
    Wait-For { ([regex]::Matches((Get-Content -LiteralPath $logPath -Raw),'neural_finished=true')).Count -ge 2 } 'warm neural playback'
    if ((Last-Helper) -ne $helperId) { throw 'Warm read reloaded the voice model' }
    $helper = Get-Process -Id $helperId
    Write-Host "PASS neural playback and warm helper reuse; helper working set $([math]::Round($helper.WorkingSet64/1MB,2)) MiB"
    Wait-For { !(Get-Process -Id $helperId -ErrorAction SilentlyContinue) } '30-second idle model unload' 36
    Write-Host 'PASS neural helper unloads after idle'
    Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class NeuralFixtureText {
 [DllImport("user32.dll",CharSet=CharSet.Unicode,EntryPoint="SendMessageW")] static extern IntPtr SendText(IntPtr hwnd,uint message,IntPtr wparam,string text);
 public static void SetWindowText(IntPtr hwnd,string text) {
  if(SendText(hwnd,0xC,IntPtr.Zero,text)==IntPtr.Zero) throw new Exception("Could not set fixture text");
 }
}
'@
    [NeuralFixtureText]::SetWindowText([IntPtr]$state.input,('This is a longer passage used to verify that speech can be stopped without waiting for the full text to finish. ' * 60)) | Out-Null
    if ([TestNative]::SendMessage([IntPtr]$state.input,0xE,[IntPtr]0,[IntPtr]0).ToInt64() -lt 500) { throw 'Long-text fixture was not initialized' }
    $readyCount = ([regex]::Matches((Get-Content -LiteralPath $logPath -Raw),'neural_audio_ready_ms=')).Count
    Read-Selected
    Wait-For { ([regex]::Matches((Get-Content -LiteralPath $logPath -Raw),'neural_audio_ready_ms=')).Count -gt $readyCount } 'long neural reading'
    $helperBeforeRate = Last-Helper
    $main = [TestNative]::FindWindow('InstaSpeakRustHiddenWindow',$null)
    [TestNative]::PostMessage($main,0x8008,[IntPtr]14,[IntPtr]0) | Out-Null
    Wait-For { (Last-Helper) -ne $helperBeforeRate -and (Get-Content -LiteralPath $logPath -Raw) -match 'neural_rate=4' } 'pitch-preserving rate change at the next section' 20
    Write-Host 'PASS neural speed changes take effect at the next section'
    $helperId = Last-Helper
    $stopwatch = [Diagnostics.Stopwatch]::StartNew()
    [TestNative]::Hotkey(0x51)
    Wait-For { !(Get-Process -Id $helperId -ErrorAction SilentlyContinue) } 'neural stop'
    Write-Host "PASS stop cancels neural helper in $([math]::Round($stopwatch.Elapsed.TotalMilliseconds)) ms"
    [NeuralFixtureText]::SetWindowText([IntPtr]$state.input,'Selected text is read aloud by InstaSpeak.') | Out-Null
    $finishedCount = ([regex]::Matches((Get-Content -LiteralPath $logPath -Raw),'neural_finished=true')).Count
    Read-Selected
    Wait-For { ([regex]::Matches((Get-Content -LiteralPath $logPath -Raw),'neural_finished=true')).Count -gt $finishedCount } 'playback before process exit'
    $helperId = Last-Helper
    Stop-Process -Id $resident.Id -Force
    Wait-For { !(Get-Process -Id $helperId -ErrorAction SilentlyContinue) } 'helper cleanup after abrupt parent exit'
    Write-Host 'PASS helper exits if the tray process is terminated'
    if ((Get-Content -LiteralPath $logPath -Raw) -match 'Northern English Male:') { throw 'Neural backend reported an error' }
} finally {
    & $cli --trigger exit 2>$null
    if ($fixture -and !$fixture.HasExited) { Stop-Process -Id $fixture.Id }
    if ($resident -and !$resident.HasExited) { $resident.WaitForExit(5000) | Out-Null }
    if ($previous -ne [IntPtr]::Zero) { [TestNative]::SetForegroundWindow($previous) | Out-Null }
    $env:APPDATA = $originalAppData
}
