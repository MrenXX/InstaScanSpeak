param([switch]$SelectEngine)
$ErrorActionPreference = 'Stop'
$ProgressPreference = 'SilentlyContinue'
$root = Join-Path $env:LOCALAPPDATA 'InstaSpeak'
$models = Join-Path $root 'tiny-ocr'
$cache = Join-Path $root 'downloads'
$cli = Join-Path $root 'instascanspeak-cli.exe'
$app = Join-Path $root 'instascanspeak.exe'
if (!(Test-Path -LiteralPath (Join-Path $root 'instascanspeak-ocr.exe'))) { throw 'Install InstaScanSpeak first.' }
New-Item -ItemType Directory -Force -Path $models,$cache | Out-Null
function Matches-Hash($path,$hash) { return (Test-Path -LiteralPath $path) -and ((Get-FileHash -LiteralPath $path).Hash -eq $hash) }
function Download-Verified($url,$path,$hash) {
    if (!(Matches-Hash $path $hash)) {
        Write-Host "Downloading $([IO.Path]::GetFileName($path))..."
        Invoke-WebRequest -UseBasicParsing -Uri $url -OutFile $path
    }
    if (!(Matches-Hash $path $hash)) { throw "Download verification failed: $path" }
}
$files = @(
    @{Name='det.onnx';Cache='PP-OCRv6_det_tiny.onnx';Task='det';Hash='F42C0FBD294D95EAC1A550E131B277DAC97462C8025FA4B6C3CEC1B7894BD3D5'},
    @{Name='rec.onnx';Cache='PP-OCRv6_rec_tiny.onnx';Task='rec';Hash='E16E242DE5937AD92609223F19BC2AFF3727EE40B095F996907C24749BAD251B'}
)
foreach ($file in $files) {
    if (!(Matches-Hash (Join-Path $models $file.Name) $file.Hash)) {
        $url="https://www.modelscope.cn/models/RapidAI/RapidOCR/resolve/v3.10.0/onnx/PP-OCRv6/$($file.Task)/$($file.Cache)"
        Download-Verified $url (Join-Path $cache $file.Cache) $file.Hash
    }
}
$runtimeValid = (Matches-Hash (Join-Path $models 'onnxruntime.dll') '0C42DC4E278F0968FDF9EBF1B1E54A74C657A9942E70803E453C91993451CF4C') -and (Matches-Hash (Join-Path $models 'onnxruntime_providers_shared.dll') 'E45D471EA2A842B268C51291B96D53568B0DAE10807F43D1FB7DC0EB84E83723')
$archivePath = Join-Path $cache 'onnxruntime-win-x64-1.31.0.zip'
if (!$runtimeValid) {
    Write-Host 'The one-time upstream runtime download is about 79 MiB. Only about 17 MiB is installed.'
    Download-Verified 'https://github.com/microsoft/onnxruntime/releases/download/v1.31.0/onnxruntime-win-x64-1.31.0.zip' $archivePath '3958D8A44984160692C1B4FFD0DE3CB48F8C39F9D34BB31E433DB06E30B82195'
}
$running = @(Get-Process instascanspeak -ErrorAction SilentlyContinue | Where-Object {$_.Path -ieq $app})
if ($running.Count -gt 0) {
    & $cli --trigger exit
    foreach ($process in $running) {if (!$process.HasExited -and !$process.WaitForExit(5000)) {throw 'InstaScanSpeak did not exit. Close it before updating Tiny OCR.'}}
}
try {
    if (!$runtimeValid) {
        Add-Type -AssemblyName System.IO.Compression.FileSystem
        $archive = [IO.Compression.ZipFile]::OpenRead($archivePath)
        try {
            foreach ($entry in $archive.Entries) {
                $name = $entry.Name
                if ($name -in @('onnxruntime.dll','onnxruntime_providers_shared.dll','LICENSE','ThirdPartyNotices.txt')) {
                    $targetName = if ($name -eq 'LICENSE') {'ONNX-Runtime-LICENSE.txt'} else {$name}
                    [IO.Compression.ZipFileExtensions]::ExtractToFile($entry,(Join-Path $models $targetName),$true)
                }
            }
        } finally { $archive.Dispose() }
        if (!(Matches-Hash (Join-Path $models 'onnxruntime.dll') '0C42DC4E278F0968FDF9EBF1B1E54A74C657A9942E70803E453C91993451CF4C')) {throw 'Runtime extraction failed'}
        Remove-Item -LiteralPath $archivePath
    }
    foreach ($file in $files) {
        if (!(Matches-Hash (Join-Path $models $file.Name) $file.Hash)) { Copy-Item -LiteralPath (Join-Path $cache $file.Cache) -Destination (Join-Path $models $file.Name) -Force }
    }
    [IO.File]::WriteAllText((Join-Path $models 'ATTRIBUTION.txt'),@'
PP-OCRv6 Tiny by PaddlePaddle/PaddleOCR, distributed by RapidAI/RapidOCR.
https://github.com/PaddlePaddle/PaddleOCR
https://github.com/RapidAI/RapidOCR
Model registry version: v3.10.0. Character dictionary is embedded in the recognition model metadata.
Inference: ONNX Runtime 1.31.0, MIT. License and third-party notices are installed here.
Native helper: OAR OCR Core, Apache-2.0, https://github.com/GreatV/oar-ocr
Helper dependency notices are installed under InstaScanSpeak/resources.
Models and runtime are downloaded directly from their upstream projects.
'@)
    Get-ChildItem -LiteralPath $models -File | Unblock-File
    & $cli --check-tiny
    if ($LASTEXITCODE -ne 0) {throw 'Tiny OCR could not initialize. Verify the files and install the current Microsoft Visual C++ x64 runtime if needed: https://aka.ms/vc14/vc_redist.x64.exe'}
    if ($SelectEngine) {
        & $cli --set-ocr-engine tiny
        if ($LASTEXITCODE -ne 0) {throw 'Could not select Tiny OCR'}
    }
} finally {
    if ($running.Count -gt 0) {Start-Process -FilePath $app -WindowStyle Hidden}
}
Write-Host 'PP-OCRv6 Tiny installed. Choose it under OCR engine in the tray panel.'
