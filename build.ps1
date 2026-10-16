$ErrorActionPreference = 'Stop'
Push-Location $PSScriptRoot
try {
    $cargo = Get-Command cargo -ErrorAction SilentlyContinue
    $cargoPath = if ($cargo) { $cargo.Source } else { Join-Path $env:USERPROFILE '.cargo\bin\cargo.exe' }
    & $cargoPath build --release --locked
    if ($LASTEXITCODE -ne 0) { throw 'Build failed.' }
    $dist = Join-Path $PSScriptRoot 'dist\windows-x64'
    New-Item -ItemType Directory -Force -Path $dist | Out-Null
    Copy-Item -LiteralPath 'target\release\instaspeak.exe', 'target\release\instaspeak-cli.exe' -Destination $dist -Force
} finally { Pop-Location }
