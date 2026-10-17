param([string]$OutputDirectory = (Join-Path $PSScriptRoot '..\artifacts\ocr-fixtures'))
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing, System.Windows.Forms
New-Item -ItemType Directory -Force -Path $OutputDirectory | Out-Null
$OutputDirectory = (Resolve-Path -LiteralPath $OutputDirectory).Path
$corpora = @{
stress = @(
    'I will install 11 little files in folder I1l, not 111.',
    'Invoice IL-101: total 101.11 USD. Call Lily at 0118 123 4567.',
    'if (limit == 1) { fileId = "Il1lI"; } // line 101'
)
prose = @(
    'Small print should remain readable in a dark browser window.',
    'Please bring 12 copies of the report to the library at 11:30.',
    'The old building has bright windows and a quiet little garden.'
)
}
$fixtures = foreach ($corpus in @('stress','prose')) {
 $lines = $corpora[$corpus]
 foreach ($family in @('Segoe UI', 'Arial', 'Consolas')) {
    foreach ($size in @(9,11,14,18)) {
        foreach ($dark in @($false,$true)) {
            $font = [Drawing.Font]::new($family,$size,[Drawing.FontStyle]::Regular,[Drawing.GraphicsUnit]::Pixel)
            $flags = [Windows.Forms.TextFormatFlags]::NoPadding -bor [Windows.Forms.TextFormatFlags]::NoPrefix -bor [Windows.Forms.TextFormatFlags]::SingleLine
            $sizes = @($lines | ForEach-Object { [Windows.Forms.TextRenderer]::MeasureText($_,$font,[Drawing.Size]::new(2000,100),$flags) })
            $width = [int](($sizes | Measure-Object Width -Maximum).Maximum + 24)
            $lineHeight = [int](($sizes | Measure-Object Height -Maximum).Maximum + 4)
            $height = $lineHeight * $lines.Count + 24
            $bitmap = [Drawing.Bitmap]::new($width,$height,[Drawing.Imaging.PixelFormat]::Format32bppArgb)
            $graphics = [Drawing.Graphics]::FromImage($bitmap)
            $background = if ($dark) { [Drawing.Color]::FromArgb(30,30,30) } else { [Drawing.Color]::White }
            $foreground = if ($dark) { [Drawing.Color]::FromArgb(225,225,225) } else { [Drawing.Color]::FromArgb(25,25,25) }
            $graphics.Clear($background)
            for ($i=0; $i -lt $lines.Count; $i++) {
                [Windows.Forms.TextRenderer]::DrawText($graphics,$lines[$i],$font,[Drawing.Point]::new(12,12+$i*$lineHeight),$foreground,$background,$flags)
            }
            $theme = if ($dark) {'dark'} else {'light'}
            $name = "$(($family -replace ' ',''))-$size-$theme"
            if ($corpus -ne 'stress') { $name += "-$corpus" }
            $bitmap.Save((Join-Path $OutputDirectory "$name.png"),[Drawing.Imaging.ImageFormat]::Png)
            $data = $bitmap.LockBits([Drawing.Rectangle]::new(0,0,$width,$height),[Drawing.Imaging.ImageLockMode]::ReadOnly,[Drawing.Imaging.PixelFormat]::Format32bppArgb)
            $bytes = [byte[]]::new($width*$height*4)
            [Runtime.InteropServices.Marshal]::Copy($data.Scan0,$bytes,0,$bytes.Length)
            $bitmap.UnlockBits($data)
            [IO.File]::WriteAllBytes((Join-Path $OutputDirectory "$name.bgra"),$bytes)
            $graphics.Dispose(); $bitmap.Dispose(); $font.Dispose()
            [pscustomobject]@{name=$name; width=$width; height=$height; size=$size; family=$family; dark=$dark; corpus=$corpus; text=($lines -join "`n")}
        }
    }
}
}
$fixtures | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $OutputDirectory 'fixtures.json') -Encoding UTF8
Write-Host "Created $($fixtures.Count) Windows-rendered OCR samples in $OutputDirectory"
