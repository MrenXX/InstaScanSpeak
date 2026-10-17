$ErrorActionPreference='Stop'
$projectDir=Split-Path -Parent $PSScriptRoot
$cli=Join-Path $projectDir 'dist/windows-x64/instaspeak-cli.exe'
$artifacts=Join-Path $projectDir 'artifacts'
Add-Type -AssemblyName System.Windows.Forms
Add-Type -Path (Join-Path $PSScriptRoot 'native-test.cs')
Add-Type -Path (Join-Path $PSScriptRoot 'speed-evidence.cs') -ReferencedAssemblies System.Drawing
[TestNative]::SetProcessDpiAwarenessContext([IntPtr](-4)) | Out-Null
$previous=[TestNative]::GetForegroundWindow()
$savedAppData=$env:APPDATA
$env:APPDATA=Join-Path $artifacts 'tiny-test-appdata'
$settings=Join-Path $env:APPDATA 'InstaSpeak/rust-settings.txt'
New-Item -ItemType Directory -Force -Path (Split-Path -Parent $settings) | Out-Null
[IO.File]::WriteAllText($settings,"ocr_engine=tiny`nvoice_id=piper:northern-english-male`nrate=0`n")
$log=Join-Path $artifacts 'tiny-resident.log'
$statePath=Join-Path $artifacts 'tiny-fixture.json'
$resident=$null; $fixture=$null
$clipboardBackup=New-Object Windows.Forms.DataObject
$source=[Windows.Forms.Clipboard]::GetDataObject()
if($source){foreach($format in $source.GetFormats($false)){$data=$source.GetData($format,$false);if($null -ne $data){$clipboardBackup.SetData($format,$false,$data)}}}
function Wait-For($condition,$description,$seconds=15){
 $deadline=[DateTime]::UtcNow.AddSeconds($seconds)
 do{if(& $condition){return};Start-Sleep -Milliseconds 20}while([DateTime]::UtcNow -lt $deadline)
 throw "Timed out: $description"
}
function Count-Log($pattern){return ([regex]::Matches((Get-Content $log -Raw),$pattern)).Count}
function Helper-Id {$matches=[regex]::Matches((Get-Content $log -Raw),'tiny_helper_pid=(\d+)');if(!$matches.Count){return 0};return [int]$matches[$matches.Count-1].Groups[1].Value}
function Capture($key){
 [TestNative]::FocusFixture([IntPtr]$state.form,[IntPtr]$state.input)
 [TestNative]::Hotkey($key)
 Wait-For {[TestNative]::FindWindow('InstaSpeakRustSelectionOverlay',$null) -ne [IntPtr]::Zero} 'capture overlay'
 $overlay=[TestNative]::FindWindow('InstaSpeakRustSelectionOverlay',$null)
 $start=[IntPtr](($state.y -shl 16) -bor ($state.x -band 65535))
 $end=[IntPtr]((($state.y+$state.height) -shl 16) -bor (($state.x+$state.width) -band 65535))
 [TestNative]::PostMessage($overlay,0x201,[IntPtr]1,$start) | Out-Null
 [TestNative]::PostMessage($overlay,0x202,[IntPtr]0,$end) | Out-Null
}
try{
 if(Test-Path $statePath){Remove-Item -LiteralPath $statePath}
 $resident=Start-Process $cli -ArgumentList '--resident' -WindowStyle Hidden -PassThru -RedirectStandardOutput $log -RedirectStandardError (Join-Path $artifacts 'tiny-error.log')
 Wait-For {(Get-Content $log -Raw) -match 'Ready\.'} 'resident startup'
 $fixture=Start-Process powershell -ArgumentList @('-NoProfile','-STA','-ExecutionPolicy','Bypass','-File',"`"$(Join-Path $PSScriptRoot 'fixture.ps1')`"",'-StatePath',"`"$statePath`"") -WindowStyle Hidden -PassThru
 Wait-For {Test-Path $statePath} 'fixture startup'
 $state=Get-Content $statePath -Raw | ConvertFrom-Json
 [TestNative]::ShowWindow([IntPtr]$state.form,5) | Out-Null
 Capture 0x44
 Wait-For {(Count-Log 'ocr_copied=true') -eq 1} 'Tiny copy OCR'
 if([Windows.Forms.Clipboard]::GetText() -notmatch 'InstaSpeak reads this screen text aloud'){throw 'Tiny OCR text mismatch'}
 if((Count-Log 'speech_queued_ms=') -ne 0){throw 'Copy OCR started speech'}
 $helper=Helper-Id
 Write-Host "PASS Ctrl+Alt+D uses Tiny, copies text, and does not speak; helper $([math]::Round((Get-Process -Id $helper).WorkingSet64/1MB,1)) MiB"
 Capture 0x41
 Wait-For {(Count-Log 'neural_audio_started=') -gt 0} 'Tiny OCR to neural speech'
 if((Helper-Id) -ne $helper){throw 'Warm OCR reloaded the model'}
 [TestNative]::Hotkey(0x51)
 Wait-For {(Count-Log 'neural_audio_stopped=') -gt 0} 'speech stop'
 Write-Host 'PASS Ctrl+Alt+A reads Tiny OCR through Northern English Male; Ctrl+Alt+Q stops it'
 $main=[TestNative]::FindWindow('InstaSpeakRustHiddenWindow',$null)
 [TestNative]::PostMessage($main,0x8001,[IntPtr]1,[IntPtr]0x205) | Out-Null
 Wait-For {[TestNative]::FindWindow('InstaSpeakTrayPanel','InstaSpeak') -ne [IntPtr]::Zero} 'tray panel'
 $panel=[TestNative]::FindWindow('InstaSpeakTrayPanel','InstaSpeak')
 Wait-For {[SpeedEvidence]::GetDlgItem($panel,12) -ne [IntPtr]::Zero} 'engine selector'
 $combo=[SpeedEvidence]::GetDlgItem($panel,12)
 if([TestNative]::SendMessage($combo,0x147,[IntPtr]0,[IntPtr]0).ToInt64() -ne 1){throw 'Tiny selection was not shown'}
 [SpeedEvidence]::Capture($panel,(Join-Path $artifacts 'tray_tiny_v0_5.png'))
 [TestNative]::SendMessage($combo,0x14E,[IntPtr]0,[IntPtr]0) | Out-Null
 [TestNative]::SendMessage($panel,0x111,[IntPtr](12 -bor (1 -shl 16)),$combo) | Out-Null
 Wait-For {(Get-Content $settings -Raw) -match '(?m)^ocr_engine=windows$' -and !(Get-Process -Id $helper -ErrorAction SilentlyContinue)} 'Windows switch and Tiny unload'
 [TestNative]::SendMessage($combo,0x14E,[IntPtr]1,[IntPtr]0) | Out-Null
 [TestNative]::SendMessage($panel,0x111,[IntPtr](12 -bor (1 -shl 16)),$combo) | Out-Null
 Wait-For {(Get-Content $settings -Raw) -match '(?m)^ocr_engine=tiny$'} 'Tiny switch'
 if(Get-Process -Id $helper -ErrorAction SilentlyContinue){throw 'Selecting Tiny loaded it before capture'}
 [TestNative]::PostMessage($panel,0x111,[IntPtr]2,[IntPtr]0) | Out-Null
 Write-Host 'PASS tray engine switch persists and immediately unloads Tiny when choosing Windows'
 $copies=Count-Log 'ocr_copied=true'
 Capture 0x44
 Wait-For {(Count-Log 'ocr_copied=true') -gt $copies} 'Tiny reload'
 $helper=Helper-Id
 Wait-For {!(Get-Process -Id $helper -ErrorAction SilentlyContinue)} 'idle model unload' 36
 Write-Host 'PASS Tiny helper unloads after 30 seconds idle'
 $speech=Count-Log 'speech_queued_ms='
 Capture 0x41
 Wait-For {(Helper-Id) -ne $helper} 'cold helper startup'
 $helper=Helper-Id
 $stopwatch=[Diagnostics.Stopwatch]::StartNew()
 [TestNative]::Hotkey(0x51)
 Wait-For {!(Get-Process -Id $helper -ErrorAction SilentlyContinue)} 'cancel cold OCR'
 if($stopwatch.ElapsedMilliseconds -gt 500){throw 'OCR cancellation exceeded 500 ms'}
    $cancelMs=$stopwatch.ElapsedMilliseconds
 Start-Sleep -Milliseconds 300
 if((Count-Log 'speech_queued_ms=') -ne $speech){throw 'Cancelled OCR started speech'}
    Write-Host "PASS Ctrl+Alt+Q cancels cold OCR in $cancelMs ms without late speech"
 $copies=Count-Log 'ocr_copied=true'
 Capture 0x44
 Wait-For {(Count-Log 'ocr_copied=true') -gt $copies} 'OCR after cancellation'
 $helper=Helper-Id
 Stop-Process -Id $resident.Id -Force
 Wait-For {!(Get-Process -Id $helper -ErrorAction SilentlyContinue)} 'job object cleanup'
 Write-Host 'PASS Tiny recovers after cancellation and exits on abrupt parent termination'
}finally{
 if($resident -and !$resident.HasExited){& $cli --trigger exit;$resident.WaitForExit(5000) | Out-Null}
 if($fixture -and !$fixture.HasExited){Stop-Process -Id $fixture.Id}
 [Windows.Forms.Clipboard]::SetDataObject($clipboardBackup,$true)
 $env:APPDATA=$savedAppData
 if($previous -ne [IntPtr]::Zero){[TestNative]::SetForegroundWindow($previous) | Out-Null}
}
