$ErrorActionPreference='Stop'
$root=Split-Path -Parent $PSScriptRoot
$cli=Join-Path $root 'dist/windows-x64/instaspeak-cli.exe'
$artifacts=Join-Path $root 'artifacts'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -Path (Join-Path $PSScriptRoot 'native-test.cs')
[TestNative]::SetProcessDpiAwarenessContext([IntPtr](-4)) | Out-Null
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class PauseFixtureText {
 [DllImport("user32.dll",CharSet=CharSet.Unicode,EntryPoint="SendMessageW")]
 public static extern IntPtr Set(IntPtr hwnd,uint msg,IntPtr w,string text);
}
'@
$savedAppData=$env:APPDATA
$previous=[TestNative]::GetForegroundWindow()
$env:APPDATA=Join-Path $artifacts 'pause-test-appdata'
$settings=Join-Path $env:APPDATA 'InstaSpeak/rust-settings.txt'
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $settings) | Out-Null
$statePath=Join-Path $artifacts 'pause-fixture.json'
$fixture=$null;$resident=$null
function Wait-For($condition,$description,$seconds=15){
 $deadline=[DateTime]::UtcNow.AddSeconds($seconds)
 do{if(& $condition){return};Start-Sleep -Milliseconds 20}while([DateTime]::UtcNow -lt $deadline)
 throw "Timed out: $description"
}
function Count($pattern){return ([regex]::Matches((Get-Content $log -Raw),$pattern)).Count}
function Select-FixtureText {
 Wait-For {
  try {
  [TestNative]::FocusFixture([IntPtr]$state.form,[IntPtr]$state.input)
  [TestNative]::SendMessage([IntPtr]$state.input,0xB1,[IntPtr]0,[IntPtr](-1)) | Out-Null
  $length=[TestNative]::SendMessage([IntPtr]$state.input,0xE,[IntPtr]0,[IntPtr]0).ToInt64()
  $range=[TestNative]::SendMessage([IntPtr]$state.input,0xB0,[IntPtr]0,[IntPtr]0).ToInt64()
  return $length -gt 500 -and ($range -band 65535) -eq 0 -and (($range -shr 16) -band 65535) -eq $length
  } catch {return $false}
 } 'fixture selection readiness'
}
function Read-Selected {
 Select-FixtureText
 $window=[TestNative]::FindWindow('InstaSpeakRustHiddenWindow',$null)
 [TestNative]::PostMessage($window,0x111,[IntPtr]104,[IntPtr]0) | Out-Null
}
function Toggle($paused,$key=0x50){
 $pattern="speech_paused=$($paused.ToString().ToLowerInvariant())"
 $before=Count $pattern
 [TestNative]::Hotkey($key)
 Wait-For {(Count $pattern) -gt $before} "pause state $paused"
}
try {
 if(Test-Path $statePath){Remove-Item -LiteralPath $statePath}
 $fixture=Start-Process powershell -ArgumentList @('-NoProfile','-STA','-ExecutionPolicy','Bypass','-File',"`"$(Join-Path $PSScriptRoot 'fixture.ps1')`"",'-StatePath',"`"$statePath`"") -WindowStyle Hidden -PassThru
 Wait-For {Test-Path $statePath} 'fixture startup'
 $state=Get-Content $statePath -Raw | ConvertFrom-Json
 [TestNative]::ShowWindow([IntPtr]$state.form,5) | Out-Null
 [PauseFixtureText]::Set([IntPtr]$state.input,0xC,[IntPtr]0,('This passage verifies that pausing preserves the current reading position and that stopping clears the paused state. ' * 15)) | Out-Null
 foreach($voice in @('', 'piper:northern-english-male')){
  $name=if($voice){'neural'}else{'windows'}
  [IO.File]::WriteAllText($settings,"voice_id=$voice`nrate=0`nocr_engine=tiny`n")
  $log=Join-Path $artifacts "pause-$name.log"
  $resident=Start-Process $cli -ArgumentList '--resident' -WindowStyle Hidden -PassThru -RedirectStandardOutput $log -RedirectStandardError (Join-Path $artifacts "pause-$name-error.log")
  Wait-For {(Get-Content $log -Raw) -match 'pause/resume speech Ctrl\+Alt\+P'} 'pause hotkey registration'
  [TestNative]::Hotkey(0x50)
  Wait-For {(Count 'speech_pause_ignored=true') -eq 1} 'idle pause is a no-op'
  Read-Selected
  Wait-For {(Count 'speech_queued_ms=') -eq 1} 'speech queued'
  Toggle $true
  if($voice){Wait-For {(Count 'neural_audio_started=') -gt 0} 'paused audio submission'}
  # Cross the existing 30-second idle timer. Paused speech must remain resumable.
  Start-Sleep -Seconds 31
  if($voice -and (Count 'neural_finished=true') -ne 0){throw 'Paused neural speech completed'}
  Toggle $false
  Start-Sleep -Milliseconds 250
  Toggle $true
  [TestNative]::Hotkey(0x51)
  [TestNative]::Hotkey(0x50)
  Wait-For {(Count 'speech_pause_ignored=true') -eq 2} 'Stop clears paused state'
  $queued=Count 'speech_queued_ms='
  Read-Selected
  Wait-For {(Count 'speech_queued_ms=') -gt $queued} 'new reading after paused Stop'
  Toggle $true
  # A new read replaces the paused one and starts unpaused.
  $queued=Count 'speech_queued_ms='
  Read-Selected
  Wait-For {(Count 'speech_queued_ms=') -gt $queued} 'replacement reading'
  Toggle $true
  Toggle $false
  [TestNative]::Hotkey(0x51)
  Write-Host "PASS $name Ctrl+Alt+P: idle no-op, pause before playback, 31-second hold, resume, repeated toggles, Stop and replacement reading"
  [TestNative]::PostMessage([TestNative]::FindWindow('InstaSpeakRustHiddenWindow',$null),0x111,[IntPtr]199,[IntPtr]0) | Out-Null
  if(!$resident.WaitForExit(5000)){throw 'Resident did not exit'}
  $resident=$null
 }
 # The new default must not take an existing custom Ctrl+Alt+P binding.
 [IO.File]::WriteAllText($settings,"selected_hotkey=Ctrl+Alt+P`nocr_engine=tiny`n")
 $log=Join-Path $artifacts 'pause-custom.log'
 $resident=Start-Process $cli -ArgumentList '--resident' -WindowStyle Hidden -PassThru -RedirectStandardOutput $log -RedirectStandardError (Join-Path $artifacts 'pause-custom-error.log')
 Wait-For {(Get-Content $log -Raw) -match 'pause/resume speech Ctrl\+Alt\+R'} 'non-conflicting pause default'
 if((Get-Content $log -Raw) -notmatch 'read selection Ctrl\+Alt\+P'){throw 'Existing custom shortcut changed'}
 Read-Selected
 Wait-For {(Count 'speech_queued_ms=') -gt 0} 'custom reading'
 Toggle $true 0x52
 $queued=Count 'speech_queued_ms='
 Select-FixtureText
 [TestNative]::Hotkey(0x50)
 Wait-For {(Count 'speech_queued_ms=') -gt $queued} 'original custom read shortcut'
 Toggle $true 0x52
 Toggle $false 0x52
 [TestNative]::Hotkey(0x51)
 Write-Host 'PASS custom Ctrl+Alt+P read shortcut preserved and Ctrl+Alt+R toggles pause/resume'
} finally {
 if($resident -and !$resident.HasExited){[TestNative]::PostMessage([TestNative]::FindWindow('InstaSpeakRustHiddenWindow',$null),0x111,[IntPtr]199,[IntPtr]0) | Out-Null;$resident.WaitForExit(5000) | Out-Null}
 if($fixture -and !$fixture.HasExited){Stop-Process -Id $fixture.Id}
 $env:APPDATA=$savedAppData
 if($previous -ne [IntPtr]::Zero){[TestNative]::SetForegroundWindow($previous) | Out-Null}
}
