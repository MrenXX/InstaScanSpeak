$ErrorActionPreference = 'Stop'
$projectDir = Split-Path -Parent $PSScriptRoot
$cli = Join-Path $projectDir 'dist\windows-x64\instaspeak-cli.exe'
$artifacts = Join-Path $projectDir 'artifacts'
New-Item -ItemType Directory -Force -Path $artifacts | Out-Null
Add-Type -AssemblyName System.Windows.Forms
Add-Type -Path (Join-Path $PSScriptRoot 'speed-evidence.cs') -ReferencedAssemblies System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;
public static class TestNative {
    [DllImport("user32.dll")] public static extern IntPtr GetForegroundWindow();
    [DllImport("user32.dll")] public static extern bool SetForegroundWindow(IntPtr hwnd);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hwnd,int cmd);
    [DllImport("kernel32.dll")] public static extern uint GetCurrentThreadId();
    [DllImport("user32.dll")] public static extern uint GetWindowThreadProcessId(IntPtr hwnd,IntPtr processId);
    [DllImport("user32.dll")] public static extern bool AttachThreadInput(uint from,uint to,bool attach);
    [DllImport("user32.dll")] public static extern IntPtr SetFocus(IntPtr hwnd);
    [DllImport("user32.dll", CharSet=CharSet.Unicode)] public static extern IntPtr FindWindow(string cls, string title);
    [DllImport("user32.dll")] public static extern bool PostMessage(IntPtr hwnd,uint msg,IntPtr w,IntPtr l);
    [DllImport("user32.dll")] public static extern IntPtr SendMessage(IntPtr hwnd,uint msg,IntPtr w,IntPtr l);
    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr value);
    [DllImport("user32.dll")] public static extern uint GetClipboardSequenceNumber();
    [DllImport("user32.dll")] public static extern uint SendInput(uint count, INPUT[] inputs, int size);
    [StructLayout(LayoutKind.Sequential)] public struct INPUT { public uint type; public UNION data; }
    [StructLayout(LayoutKind.Explicit)] public struct UNION { [FieldOffset(0)] public KEYBOARD keyboard; [FieldOffset(0)] public MOUSE mouse; }
    [StructLayout(LayoutKind.Sequential)] public struct KEYBOARD { public ushort vk,scan; public uint flags,time; public UIntPtr extra; }
    [StructLayout(LayoutKind.Sequential)] public struct MOUSE { public int x,y; public uint data,flags,time; public UIntPtr extra; }
    public static void Hotkey(ushort key) {
        ushort[] keys = {0x11,0x12,key,key,0x12,0x11};
        INPUT[] input = new INPUT[6];
        for (int i=0;i<6;i++) { input[i].type=1; input[i].data.keyboard.vk=keys[i]; input[i].data.keyboard.flags=i<3?0u:2u; }
        if (SendInput(6,input,Marshal.SizeOf(typeof(INPUT))) != 6) throw new Exception("SendInput failed");
    }
    public static void FocusFixture(IntPtr form, IntPtr textBox) {
        uint current = GetCurrentThreadId();
        uint foreground = GetWindowThreadProcessId(GetForegroundWindow(),IntPtr.Zero);
        uint target = GetWindowThreadProcessId(form,IntPtr.Zero);
        AttachThreadInput(current,foreground,true);
        AttachThreadInput(current,target,true);
        try { SetForegroundWindow(form); SetFocus(textBox); }
        finally { AttachThreadInput(current,target,false); AttachThreadInput(current,foreground,false); }
        if (GetForegroundWindow() != form) throw new Exception("Could not focus the test fixture");
    }
}
'@
[TestNative]::SetProcessDpiAwarenessContext([IntPtr](-4)) | Out-Null
$previous = [TestNative]::GetForegroundWindow()
$statePath = Join-Path $artifacts 'fixture.json'
$logPath = Join-Path $artifacts 'resident.log'
$fixtureProcess = $null
$residentProcess = $null
$clipboardBackup = $null
$clipboardChanged = $false
$originalAppData = $env:APPDATA
$env:APPDATA = Join-Path $artifacts 'test-appdata'
$testSettings = Join-Path $env:APPDATA 'InstaSpeak\rust-settings.txt'
function Wait-For($condition, $description) {
    $deadline = [DateTime]::UtcNow.AddSeconds(15)
    do {
        if (& $condition) { return }
        Start-Sleep -Milliseconds 100
    } while ([DateTime]::UtcNow -lt $deadline)
    throw "Timed out: $description"
}
try {
    if (Test-Path -LiteralPath $testSettings) { Remove-Item -LiteralPath $testSettings }
    if (Test-Path -LiteralPath $statePath) { Remove-Item -LiteralPath $statePath }
    $residentProcess = Start-Process -FilePath $cli -ArgumentList '--resident' -WindowStyle Hidden -PassThru -RedirectStandardOutput $logPath -RedirectStandardError (Join-Path $artifacts 'resident-error.log')
    Wait-For { [TestNative]::FindWindow('InstaSpeakRustHiddenWindow',$null) -ne [IntPtr]::Zero } 'resident startup'
    $fixtureProcess = Start-Process powershell -ArgumentList @('-NoProfile','-STA','-ExecutionPolicy','Bypass','-File',"`"$(Join-Path $PSScriptRoot 'fixture.ps1')`"",'-StatePath',"`"$statePath`"") -WindowStyle Hidden -PassThru
    Wait-For { Test-Path -LiteralPath $statePath } 'fixture startup'
    $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    [TestNative]::ShowWindow([IntPtr]$state.form,5) | Out-Null
    [TestNative]::FocusFixture([IntPtr]$state.form,[IntPtr]$state.input)
    $clipboardSequence = [TestNative]::GetClipboardSequenceNumber()
    $selection = & $cli --read-selection
    if ($LASTEXITCODE -ne 0 -or ($selection -join "`n") -notmatch 'Selected text is read aloud by InstaSpeak') { throw "Selection failed: $selection" }
    Write-Host "PASS selected text: $selection"
    $beforeSpeech = (Get-Process -Id $residentProcess.Id).WorkingSet64
    [TestNative]::Hotkey(0x53)
    Wait-For { (Get-Content -LiteralPath $logPath -Raw) -match 'speech_queued_ms=' } 'selected text hotkey to speech'
    Write-Host 'PASS registered selection hotkey to speech'
    $mainWindow = [TestNative]::FindWindow('InstaSpeakRustHiddenWindow',$null)
    [TestNative]::PostMessage($mainWindow,0x8001,[IntPtr]1,[IntPtr]0x205) | Out-Null
    Wait-For { [TestNative]::FindWindow('InstaSpeakTrayPanel','InstaSpeak') -ne [IntPtr]::Zero } 'speed slider'
    $speedWindow = [TestNative]::FindWindow('InstaSpeakTrayPanel','InstaSpeak')
    Wait-For { [SpeedEvidence]::GetDlgItem($speedWindow,1) -ne [IntPtr]::Zero } 'tray slider creation'
    $slider = [SpeedEvidence]::GetDlgItem($speedWindow,1)
    if ($slider -eq [IntPtr]::Zero) { throw 'Native trackbar missing' }
    [TestNative]::SendMessage($slider,0x100,[IntPtr]0x23,[IntPtr]0) | Out-Null
    Wait-For { (Get-Content -LiteralPath $testSettings -Raw) -match '(?m)^rate=10$' } 'maximum speed'
    [TestNative]::SendMessage($slider,0x100,[IntPtr]0x24,[IntPtr]0) | Out-Null
    Wait-For { (Get-Content -LiteralPath $testSettings -Raw) -match '(?m)^rate=-10$' } 'minimum speed'
    for ($i=0; $i -lt 13; $i++) { [TestNative]::SendMessage($slider,0x100,[IntPtr]0x27,[IntPtr]0) | Out-Null }
    Wait-For { (Get-Content -LiteralPath $testSettings -Raw) -match '(?m)^rate=3$' } 'intermediate speed'
    if ((Get-Content -LiteralPath $logPath -Raw) -notmatch 'speech_rate=3') { throw 'Live rate change did not reach speech controller' }
    [SpeedEvidence]::Capture($speedWindow,(Join-Path $artifacts 'tray_panel_v0_3.png'))
    [TestNative]::SendMessage($speedWindow,0x10,[IntPtr]0,[IntPtr]0) | Out-Null
    [TestNative]::PostMessage($mainWindow,0x8001,[IntPtr]1,[IntPtr]0x205) | Out-Null
    Wait-For { [TestNative]::FindWindow('InstaSpeakTrayPanel','InstaSpeak') -ne [IntPtr]::Zero } 'reopened speed slider'
    $speedWindow = [TestNative]::FindWindow('InstaSpeakTrayPanel','InstaSpeak')
    $slider = [SpeedEvidence]::GetDlgItem($speedWindow,1)
    Wait-For { [TestNative]::SendMessage([SpeedEvidence]::GetDlgItem($speedWindow,1),0x400,[IntPtr]0,[IntPtr]0).ToInt64() -eq 13 } 'retained speed after panel creation'
    $slider = [SpeedEvidence]::GetDlgItem($speedWindow,1)
    [TestNative]::SendMessage($slider,0x100,[IntPtr]0x24,[IntPtr]0) | Out-Null
    for ($i=0; $i -lt 10; $i++) { [TestNative]::SendMessage($slider,0x100,[IntPtr]0x27,[IntPtr]0) | Out-Null }
    Wait-For { (Get-Content -LiteralPath $testSettings -Raw) -match '(?m)^rate=0$' } 'normal speed reset'
    [TestNative]::PostMessage($speedWindow,0x111,[IntPtr]2,[IntPtr]0) | Out-Null
    Wait-For { [TestNative]::FindWindow('InstaSpeakTrayPanel','InstaSpeak') -eq [IntPtr]::Zero } 'close speed slider'
    Write-Host 'PASS right-click tray panel, inline slider, full range, live changes, saved settings, and reopen'
    [TestNative]::FocusFixture([IntPtr]$state.form,[IntPtr]$state.input)
    [TestNative]::Hotkey(0x51)
    $ocr = & $cli --capture-rect $state.x $state.y $state.width $state.height
    if ($LASTEXITCODE -ne 0 -or ($ocr -join "`n") -notmatch 'InstaSpeak reads this screen text aloud') { throw "OCR failed: $ocr" }
    Write-Host "PASS screenshot OCR: $ocr"
    [TestNative]::Hotkey(0x41)
    Wait-For { [TestNative]::FindWindow('InstaSpeakRustSelectionOverlay',$null) -ne [IntPtr]::Zero } 'capture hotkey overlay'
    $overlay = [TestNative]::FindWindow('InstaSpeakRustSelectionOverlay',$null)
    $start = [IntPtr](($state.y -shl 16) -bor ($state.x -band 65535))
    $end = [IntPtr]((($state.y + $state.height) -shl 16) -bor (($state.x + $state.width) -band 65535))
    [TestNative]::PostMessage($overlay,0x201,[IntPtr]1,$start) | Out-Null
    [TestNative]::PostMessage($overlay,0x200,[IntPtr]1,$end) | Out-Null
    [TestNative]::PostMessage($overlay,0x202,[IntPtr]0,$end) | Out-Null
    Wait-For { (Get-Content -LiteralPath $logPath -Raw) -match 'ocr_ready_ms=' } 'drag selection OCR to speech'
    Wait-For { ([regex]::Matches((Get-Content -LiteralPath $logPath -Raw),'speech_queued_ms=')).Count -ge 2 } 'OCR speech output'
    $mainWindow = [TestNative]::FindWindow('InstaSpeakRustHiddenWindow',$null)
    [TestNative]::PostMessage($mainWindow,0x111,[IntPtr]105,[IntPtr]0) | Out-Null
    Write-Host 'PASS capture hotkey, drag selection, OCR, speech, and stop'
    # Cancel OCR while the UI thread handles the drag result. Delayed work must not speak.
    $speechCount = ([regex]::Matches((Get-Content -LiteralPath $logPath -Raw),'speech_queued_ms=')).Count
    & $cli --trigger capture
    Wait-For { [TestNative]::FindWindow('InstaSpeakRustSelectionOverlay',$null) -ne [IntPtr]::Zero } 'second capture'
    $overlay = [TestNative]::FindWindow('InstaSpeakRustSelectionOverlay',$null)
    [TestNative]::SendMessage($overlay,0x201,[IntPtr]1,$start) | Out-Null
    [TestNative]::SendMessage($overlay,0x202,[IntPtr]0,$end) | Out-Null
    [TestNative]::PostMessage($mainWindow,0x111,[IntPtr]105,[IntPtr]0) | Out-Null
    Start-Sleep -Milliseconds 1800
    $afterCount = ([regex]::Matches((Get-Content -LiteralPath $logPath -Raw),'speech_queued_ms=')).Count
    if ($afterCount -ne $speechCount) { throw 'Cancelled OCR started speech' }
    Write-Host 'PASS stop discards pending OCR'
    if ([TestNative]::GetClipboardSequenceNumber() -ne $clipboardSequence) { throw 'Clipboard changed during reading' }
    Write-Host 'PASS clipboard untouched'
    $clipboardBackup = New-Object Windows.Forms.DataObject
    $clipboardSource = [Windows.Forms.Clipboard]::GetDataObject()
    if ($clipboardSource) {
        foreach ($format in $clipboardSource.GetFormats($false)) {
            $data = $clipboardSource.GetData($format,$false)
            if ($null -ne $data) { $clipboardBackup.SetData($format,$false,$data) }
        }
    }
    $beforeCopyCount = ([regex]::Matches((Get-Content -LiteralPath $logPath -Raw),'speech_queued_ms=')).Count
    [TestNative]::FocusFixture([IntPtr]$state.form,[IntPtr]$state.input)
    [TestNative]::Hotkey(0x43)
    Wait-For { [TestNative]::FindWindow('InstaSpeakRustSelectionOverlay',$null) -ne [IntPtr]::Zero } 'copy-only capture hotkey'
    $overlay = [TestNative]::FindWindow('InstaSpeakRustSelectionOverlay',$null)
    $clipboardChanged = $true
    [TestNative]::PostMessage($overlay,0x201,[IntPtr]1,$start) | Out-Null
    [TestNative]::PostMessage($overlay,0x202,[IntPtr]0,$end) | Out-Null
    Wait-For { (Get-Content -LiteralPath $logPath -Raw) -match 'ocr_copied=true' } 'copy-only OCR result'
    if ([Windows.Forms.Clipboard]::GetText() -notmatch 'InstaSpeak reads this screen text aloud') { throw 'Copy-only OCR text mismatch' }
    $afterCopyCount = ([regex]::Matches((Get-Content -LiteralPath $logPath -Raw),'speech_queued_ms=')).Count
    if ($afterCopyCount -ne $beforeCopyCount) { throw 'Copy-only OCR triggered speech' }
    Write-Host 'PASS copy-only OCR hotkey, clipboard text, and no speech'
    [TestNative]::PostMessage($mainWindow,0x8001,[IntPtr]1,[IntPtr]0x205) | Out-Null
    Wait-For { [TestNative]::FindWindow('InstaSpeakTrayPanel','InstaSpeak') -ne [IntPtr]::Zero } 'tray copy button'
    $panel = [TestNative]::FindWindow('InstaSpeakTrayPanel','InstaSpeak')
    Wait-For { [SpeedEvidence]::GetDlgItem($panel,106) -ne [IntPtr]::Zero } 'tray copy button creation'
    $button = [SpeedEvidence]::GetDlgItem($panel,106)
    [TestNative]::SendMessage($button,0xF5,[IntPtr]0,[IntPtr]0) | Out-Null
    Wait-For { [TestNative]::FindWindow('InstaSpeakRustSelectionOverlay',$null) -ne [IntPtr]::Zero } 'tray copy action'
    & $cli --trigger stop
    Wait-For { [TestNative]::FindWindow('InstaSpeakRustSelectionOverlay',$null) -eq [IntPtr]::Zero } 'cancel tray copy'
    [TestNative]::PostMessage($mainWindow,0x8001,[IntPtr]1,[IntPtr]0x205) | Out-Null
    Wait-For { [TestNative]::FindWindow('InstaSpeakTrayPanel','InstaSpeak') -ne [IntPtr]::Zero } 'tray dismissal test'
    [TestNative]::FocusFixture([IntPtr]$state.form,[IntPtr]$state.input)
    Wait-For { [TestNative]::FindWindow('InstaSpeakTrayPanel','InstaSpeak') -eq [IntPtr]::Zero } 'tray panel dismissal on focus change'
    Write-Host 'PASS tray copy button and popup dismissal'

    $beforeTrayRead = ([regex]::Matches((Get-Content -LiteralPath $logPath -Raw),'speech_queued_ms=')).Count
    [TestNative]::FocusFixture([IntPtr]$state.form,[IntPtr]$state.input)
    [TestNative]::SendMessage([IntPtr]$state.input,0xB1,[IntPtr]0,[IntPtr](-1)) | Out-Null
    [TestNative]::PostMessage($mainWindow,0x8001,[IntPtr]1,[IntPtr]0x205) | Out-Null
    Wait-For { [TestNative]::FindWindow('InstaSpeakTrayPanel','InstaSpeak') -ne [IntPtr]::Zero } 'tray selection reader'
    $panel = [TestNative]::FindWindow('InstaSpeakTrayPanel','InstaSpeak')
    Wait-For { [SpeedEvidence]::GetDlgItem($panel,104) -ne [IntPtr]::Zero } 'tray selection button'
    [TestNative]::SendMessage([SpeedEvidence]::GetDlgItem($panel,104),0xF5,[IntPtr]0,[IntPtr]0) | Out-Null
    Wait-For { ([regex]::Matches((Get-Content -LiteralPath $logPath -Raw),'speech_queued_ms=')).Count -gt $beforeTrayRead } 'tray selection focus restoration'
    & $cli --trigger stop
    Write-Host 'PASS tray read-selection button restores document focus'

    [TestNative]::PostMessage($mainWindow,0x8001,[IntPtr]1,[IntPtr]0x205) | Out-Null
    Wait-For { [TestNative]::FindWindow('InstaSpeakTrayPanel','InstaSpeak') -ne [IntPtr]::Zero } 'tray selectors'
    $panel = [TestNative]::FindWindow('InstaSpeakTrayPanel','InstaSpeak')
    Wait-For { [SpeedEvidence]::GetDlgItem($panel,11) -ne [IntPtr]::Zero } 'tray selectors creation'
    $voicePicker = [SpeedEvidence]::GetDlgItem($panel,10)
    [TestNative]::SendMessage($voicePicker,0x14E,[IntPtr]0,[IntPtr]0) | Out-Null
    [TestNative]::SendMessage($panel,0x111,[IntPtr](10 -bor (1 -shl 16)),$voicePicker) | Out-Null
    Wait-For { (Get-Content -LiteralPath $testSettings -Raw) -match '(?m)^voice_id=.+$' } 'voice selection from tray'
    $languagePicker = [SpeedEvidence]::GetDlgItem($panel,11)
    [TestNative]::SendMessage($languagePicker,0x14E,[IntPtr]1,[IntPtr]0) | Out-Null
    [TestNative]::SendMessage($panel,0x111,[IntPtr](11 -bor (1 -shl 16)),$languagePicker) | Out-Null
    Wait-For { (Get-Content -LiteralPath $testSettings -Raw) -match '(?m)^language_tag=.+$' } 'OCR language selection from tray'
    [TestNative]::SendMessage($languagePicker,0x14E,[IntPtr]0,[IntPtr]0) | Out-Null
    [TestNative]::SendMessage($panel,0x111,[IntPtr](11 -bor (1 -shl 16)),$languagePicker) | Out-Null
    [TestNative]::PostMessage($panel,0x111,[IntPtr]2,[IntPtr]0) | Out-Null
    Write-Host 'PASS tray voice and OCR-language selectors'

    [TestNative]::PostMessage([IntPtr]$state.form,0x10,[IntPtr]0,[IntPtr]0) | Out-Null
    $fixtureProcess.WaitForExit(5000) | Out-Null
    Remove-Item -LiteralPath $statePath
    $fixtureProcess = Start-Process powershell -ArgumentList @('-NoProfile','-STA','-ExecutionPolicy','Bypass','-File',"`"$(Join-Path $PSScriptRoot 'fixture.ps1')`"",'-StatePath',"`"$statePath`"",'-UseWpf') -WindowStyle Hidden -PassThru
    Wait-For { Test-Path -LiteralPath $statePath } 'UI Automation fixture startup'
    $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json
    [TestNative]::ShowWindow([IntPtr]$state.form,5) | Out-Null
    [TestNative]::FocusFixture([IntPtr]$state.form,[IntPtr]$state.input)
    Wait-For {
        try {
            [TestNative]::FocusFixture([IntPtr]$state.form,[IntPtr]$state.input)
            $script:uiaSelection = & $cli --read-selection 2>$null
            return $LASTEXITCODE -eq 0 -and ($script:uiaSelection -join "`n") -match 'UI Automation selected text is read aloud'
        } catch { return $false }
    } 'UI Automation fixture selection readiness'
    Write-Host "PASS UI Automation selection: $script:uiaSelection"
    Write-Host "Resident idle before speech: $([math]::Round($beforeSpeech/1MB,2)) MiB"
    Start-Sleep -Seconds 35
    $resident = Get-Process -Id $residentProcess.Id
    Write-Host "Resident after idle cleanup: $([math]::Round($resident.WorkingSet64/1MB,2)) MiB working set, $([math]::Round($resident.PrivateMemorySize64/1MB,2)) MiB private bytes"
    if ((Get-Content -LiteralPath $logPath -Raw) -match 'hotkey .*unavailable') { throw 'A default hotkey was unavailable' }
    Write-Host 'PASS all five default hotkeys registered'
} finally {
    & $cli --trigger exit 2>$null
    if ($fixtureProcess -and !$fixtureProcess.HasExited) { Stop-Process -Id $fixtureProcess.Id }
    if ($residentProcess -and !$residentProcess.HasExited) { $residentProcess.WaitForExit(5000) | Out-Null }
    if ($previous -ne [IntPtr]::Zero) { [TestNative]::SetForegroundWindow($previous) | Out-Null }
    if ($clipboardChanged -and $clipboardBackup) { [Windows.Forms.Clipboard]::SetDataObject($clipboardBackup,$true) }
    $env:APPDATA = $originalAppData
}
