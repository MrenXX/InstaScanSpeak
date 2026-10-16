param([switch]$SelectVoice)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$root = Join-Path $env:LOCALAPPDATA 'InstaSpeak'
$cache = Join-Path $root 'downloads'
$voiceDir = Join-Path $root 'voices\northern_english_male'
New-Item -ItemType Directory -Force -Path $cache,$voiceDir | Out-Null
$revision = 'c10ece1aade47bb51c153c893d14e5bf8e5b7117'
$voiceUrl = "https://huggingface.co/rhasspy/piper-voices/resolve/$revision/en/en_GB/northern_english_male/medium"
$files = @(
    @{ Name='piper-windows-2023.11.14-2.zip'; Url='https://github.com/rhasspy/piper/releases/download/2023.11.14-2/piper_windows_amd64.zip'; Hash='F3C58906402B24F3A96D92145F58ACBA6D86C9B5DB896D207F78DC80811EFCEA' },
    @{ Name='northern-english-male.onnx'; Url="$voiceUrl/en_GB-northern_english_male-medium.onnx"; Hash='57A219AE8E638873DB7D18893304BE5069C42868F392BB95C3FF17F0690D0689' },
    @{ Name='northern-english-male.onnx.json'; Url="$voiceUrl/en_GB-northern_english_male-medium.onnx.json"; Hash='69557ED3D974463453E9B0C09DD99A7ED0E52B8B87B64B357DBEEB2540A97D47' }
)
foreach ($file in $files) {
    $target = Join-Path $cache $file.Name
    if (!(Test-Path -LiteralPath $target) -or (Get-FileHash -LiteralPath $target).Hash -ne $file.Hash) {
        Write-Host "Downloading $($file.Name)..."
        Invoke-WebRequest -UseBasicParsing -Uri $file.Url -OutFile $target
    }
    if ((Get-FileHash -LiteralPath $target).Hash -ne $file.Hash) { throw "Download verification failed: $($file.Name)" }
}
$runtimeMarker = Join-Path $root 'piper\runtime.sha256'
if (!(Test-Path -LiteralPath $runtimeMarker) -or (Get-Content -LiteralPath $runtimeMarker -Raw).Trim() -ne $files[0].Hash) {
    Expand-Archive -LiteralPath (Join-Path $cache $files[0].Name) -DestinationPath $root -Force
    [IO.File]::WriteAllText($runtimeMarker,$files[0].Hash)
}
foreach ($item in @(@{Source=$files[1];Target='voice.onnx'},@{Source=$files[2];Target='voice.onnx.json'})) {
    $target = Join-Path $voiceDir $item.Target
    if (!(Test-Path -LiteralPath $target) -or (Get-FileHash -LiteralPath $target).Hash -ne $item.Source.Hash) {
        Copy-Item -LiteralPath (Join-Path $cache $item.Source.Name) -Destination $target -Force
    }
}
$modelCard = Join-Path $voiceDir 'MODEL_CARD'
if (!(Test-Path -LiteralPath $modelCard)) { Invoke-WebRequest -UseBasicParsing -Uri "$voiceUrl/MODEL_CARD" -OutFile $modelCard }
[IO.File]::WriteAllText((Join-Path $voiceDir 'ATTRIBUTION.txt'), @'
Voice: en_GB-northern_english_male-medium by the Piper voice contributors.
Model card: https://huggingface.co/rhasspy/piper-voices/tree/main/en/en_GB/northern_english_male/medium
Dataset: OpenSLR 83, Northern English male.
Dataset license stated by the model card: CC-BY-SA 4.0 International.
https://creativecommons.org/licenses/by-sa/4.0/

Piper native runtime: https://github.com/rhasspy/piper/releases/tag/2023.11.14-2
Source: https://github.com/rhasspy/piper/tree/2023.11.14-2
Runtime dependencies include eSpeak NG, piper-phonemize, and ONNX Runtime.
The voice and runtime are downloaded directly from their upstream projects.
'@)
Get-ChildItem (Join-Path $root 'piper') -File -Recurse | Unblock-File
if ($SelectVoice) {
    $cli = Join-Path $root 'instaspeak-cli.exe'
    if (!(Test-Path -LiteralPath $cli)) { $cli = Join-Path $PSScriptRoot 'dist\windows-x64\instaspeak-cli.exe' }
    if (!(Test-Path -LiteralPath $cli)) { throw 'Install or build InstaSpeak before selecting the voice.' }
    $app = Join-Path $root 'instaspeak.exe'
    $running = @(Get-Process instaspeak -ErrorAction SilentlyContinue | Where-Object { $_.Path -ieq $app })
    if ($running.Count -gt 0) {
        & $cli --trigger exit
        $running | Wait-Process -Timeout 5 -ErrorAction SilentlyContinue
    }
    & $cli --set-voice 'piper:northern-english-male'
    if ($LASTEXITCODE -ne 0) { throw 'Could not select the installed voice.' }
    if ($running.Count -gt 0) { Start-Process -FilePath $app -WindowStyle Hidden }
}
Write-Host 'Northern English Male installed. An active InstaSpeak instance is restarted when selecting this voice.'
