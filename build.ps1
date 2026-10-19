$ErrorActionPreference = 'Stop'
Push-Location $PSScriptRoot
$savedPath = $env:PATH
$savedCc = $env:CC
$savedLinker = $env:CARGO_TARGET_X86_64_PC_WINDOWS_GNU_LINKER
try {
    $cargo = Get-Command cargo -ErrorAction SilentlyContinue
    $cargoPath = if ($cargo) { $cargo.Source } else { Join-Path $env:USERPROFILE '.cargo\bin\cargo.exe' }
    $rustcPath = Join-Path (Split-Path -Parent $cargoPath) 'rustc.exe'
    if ((& $rustcPath -vV) -match 'host: x86_64-pc-windows-gnu') {
        $compiler = Get-Command gcc -ErrorAction SilentlyContinue
        if (!$env:CC -and !$compiler) {throw 'Building Tiny OCR requires a C compiler. Put GCC on PATH or use the MSVC Rust toolchain with C++ Build Tools. Prebuilt releases need no compiler.'}
        if (!$env:CC) {$env:CC=$compiler.Source}
        $tools = Join-Path (& $rustcPath --print sysroot) 'lib\rustlib\x86_64-pc-windows-gnu\bin\self-contained'
        $env:PATH="$tools;$env:PATH"
        if (!$env:CARGO_TARGET_X86_64_PC_WINDOWS_GNU_LINKER) {$env:CARGO_TARGET_X86_64_PC_WINDOWS_GNU_LINKER=Join-Path $tools 'x86_64-w64-mingw32-gcc.exe'}
    }
    & $cargoPath build --release --locked
    if ($LASTEXITCODE -ne 0) { throw 'Build failed.' }
    & $cargoPath build --manifest-path ocr-helper/Cargo.toml --release --locked
    if ($LASTEXITCODE -ne 0) {throw 'Tiny OCR helper build failed.'}
    $dist = Join-Path $PSScriptRoot 'dist\windows-x64'
    New-Item -ItemType Directory -Force -Path $dist | Out-Null
    Copy-Item -LiteralPath 'target\release\instaspeak.exe', 'target\release\instaspeak-cli.exe' -Destination $dist -Force
    Copy-Item -LiteralPath 'resources\instaspeak.ico' -Destination $dist -Force
    Copy-Item -LiteralPath 'ocr-helper\target\release\instaspeak-ocr.exe' -Destination $dist -Force
} finally {
    $env:PATH=$savedPath
    $env:CC=$savedCc
    $env:CARGO_TARGET_X86_64_PC_WINDOWS_GNU_LINKER=$savedLinker
    Pop-Location
}
