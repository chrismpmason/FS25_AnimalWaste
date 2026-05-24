# build_icon.ps1
# Generate icon_animalWaste.dds - 128x128 white line-art on transparent,
# slurry-tanker silhouette: horizontal capsule body + two wheels.
# BC3/DXT5 compressed (real 8-bit alpha) with full mipmap chain.
#
# Format choice: BC3/DXT5 is what FS25 vanilla menu icons use. Adapted
# from FS25_GrainCollection/build_icon.ps1 which documents that
# uncompressed A8R8G8B8 and BC1/DXT1 both rendered blank in-game.
#
#   powershell -ExecutionPolicy Bypass -File .\build_icon.ps1

[CmdletBinding()]
param()
$ErrorActionPreference = 'Stop'
Add-Type -AssemblyName System.Drawing

# ============================================================
# Draw the icon: horizontal slurry tanker, line art
# ============================================================

$size = 128
$bmp = New-Object System.Drawing.Bitmap $size, $size, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$g = [System.Drawing.Graphics]::FromImage($bmp)
$g.SmoothingMode = [System.Drawing.Drawing2D.SmoothingMode]::AntiAlias
$g.Clear([System.Drawing.Color]::FromArgb(0, 0, 0, 0))

$pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(255, 255, 255, 255)), ([float]4.0)
$pen.LineJoin = [System.Drawing.Drawing2D.LineJoin]::Round
$pen.StartCap = [System.Drawing.Drawing2D.LineCap]::Round
$pen.EndCap = [System.Drawing.Drawing2D.LineCap]::Round

# Tank capsule body. Arcs are bounded boxes; DrawArc(pen, x, y, w, h, startDeg, sweepDeg)
# with 0deg = 3 o'clock, positive = clockwise.
$g.DrawArc($pen, 18, 45, 30, 30, 90, 180)    # left rounded end
$g.DrawArc($pen, 80, 45, 30, 30, 270, 180)   # right rounded end
$g.DrawLine($pen, 33, 45, 95, 45)            # top edge of tank
$g.DrawLine($pen, 33, 75, 95, 75)            # bottom edge of tank

# Wheels (line-art circles, not filled).
$g.DrawEllipse($pen, 30, 78, 16, 16)         # left wheel
$g.DrawEllipse($pen, 82, 78, 16, 16)         # right wheel

$g.Dispose()
$pen.Dispose()

$bmp.Save("$PSScriptRoot\icon_animalWaste.png", [System.Drawing.Imaging.ImageFormat]::Png)

# Debug preview on dark background so the line-art is visible in any viewer
$dbgBmp = New-Object System.Drawing.Bitmap $size, $size, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
$dbgG = [System.Drawing.Graphics]::FromImage($dbgBmp)
$dbgG.Clear([System.Drawing.Color]::FromArgb(255, 30, 30, 40))
$dbgG.DrawImage($bmp, 0, 0)
$dbgG.Dispose()
$scratch = "C:\dev\_scratch"
if (-not (Test-Path $scratch)) { New-Item -ItemType Directory -Path $scratch -Force | Out-Null }
$dbgBmp.Save("$scratch\icon_animalWaste_preview_dark.png", [System.Drawing.Imaging.ImageFormat]::Png)
$dbgBmp.Dispose()

# ============================================================
# Build-time verification: count non-transparent source pixels.
# A blank icon at this point means our drawing code is wrong (not BC3).
# ============================================================

function Get-PixelBytes {
    param($bitmap, $w, $h)
    $rect = New-Object System.Drawing.Rectangle 0, 0, $w, $h
    $bmpData = $bitmap.LockBits($rect,
        [System.Drawing.Imaging.ImageLockMode]::ReadOnly,
        [System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $stride = $bmpData.Stride
    $bytes = New-Object byte[] ($stride * $h)
    [System.Runtime.InteropServices.Marshal]::Copy($bmpData.Scan0, $bytes, 0, $bytes.Length)
    $bitmap.UnlockBits($bmpData)
    return @{ bytes = $bytes; stride = $stride }
}

$mainPx = Get-PixelBytes $bmp $size $size
$nonZeroAlpha = 0
$fullyOpaque = 0
for ($i = 3; $i -lt $mainPx.bytes.Length; $i += 4) {
    $a = $mainPx.bytes[$i]
    if ($a -gt 0) { $nonZeroAlpha++ }
    if ($a -eq 255) { $fullyOpaque++ }
}
$totalPx = $size * $size

# ============================================================
# BC3/DXT5 encoder
# ============================================================

# 8-alpha mode (alpha0 > alpha1). With alpha0=0xFF, alpha1=0x00, the eight
# alpha levels are: 0=255, 1=0, 2=219, 3=182, 4=146, 5=109, 6=73, 7=36
function Get-AlphaIdx {
    param([int]$a)
    if ($a -ge 238) { return 0 }
    if ($a -ge 201) { return 2 }
    if ($a -ge 165) { return 3 }
    if ($a -ge 128) { return 4 }
    if ($a -ge 92)  { return 5 }
    if ($a -ge 55)  { return 6 }
    if ($a -ge 19)  { return 7 }
    return 1
}

function Encode-BC3Block {
    param($pixelBytes, $stride, $bx, $by, $imgW, $imgH)
    $block = New-Object byte[] 16

    # Alpha block (bytes 0-7)
    $block[0] = 0xFF  # alpha0 = max
    $block[1] = 0x00  # alpha1 = min
    $bits = [uint64]0
    for ($row = 0; $row -lt 4; $row++) {
        for ($col = 0; $col -lt 4; $col++) {
            $srcX = $bx * 4 + $col
            $srcY = $by * 4 + $row
            if ($srcX -ge $imgW) { $srcX = $imgW - 1 }
            if ($srcY -ge $imgH) { $srcY = $imgH - 1 }
            $off = $srcY * $stride + $srcX * 4
            $alpha = $pixelBytes[$off + 3]
            $idx = Get-AlphaIdx $alpha
            $pixelIdx = $row * 4 + $col
            $bits = $bits -bor (([uint64]$idx) -shl ([int]($pixelIdx * 3)))
        }
    }
    for ($j = 0; $j -lt 6; $j++) {
        $block[2 + $j] = [byte](($bits -shr ($j * 8)) -band 0xFF)
    }

    # Color block (bytes 8-15): c0=0xFFFF (white), c1=0x0000 (black),
    # c0 > c1 -> 4-color opaque mode. All color indices = 0 (white).
    # Color is irrelevant for transparent pixels (alpha block kills them).
    $block[8]  = 0xFF
    $block[9]  = 0xFF
    $block[10] = 0x00
    $block[11] = 0x00
    $block[12] = 0x00
    $block[13] = 0x00
    $block[14] = 0x00
    $block[15] = 0x00

    return ,$block  # comma prefix forces array return (PS array-collapse gotcha)
}

function Encode-MipBC3 {
    param($bitmap, $w, $h)
    $px = Get-PixelBytes $bitmap $w $h
    $blockW = [Math]::Max([Math]::Ceiling($w / 4.0), 1)
    $blockH = [Math]::Max([Math]::Ceiling($h / 4.0), 1)
    $out = New-Object byte[] ($blockW * $blockH * 16)
    for ($by = 0; $by -lt $blockH; $by++) {
        for ($bx = 0; $bx -lt $blockW; $bx++) {
            $blk = Encode-BC3Block $px.bytes $px.stride $bx $by $w $h
            $off = ($by * $blockW + $bx) * 16
            [Array]::Copy($blk, 0, $out, $off, 16)
        }
    }
    return ,$out
}

# ============================================================
# Mipmap chain: 128, 64, 32, 16, 8, 4, 2, 1
# ============================================================

$mips = @()
$curBmp = $bmp
$curSize = $size
$mipCount = 0
while ($true) {
    $mipData = Encode-MipBC3 $curBmp $curSize $curSize
    $mips += ,$mipData
    $mipCount++
    if ($curSize -le 1) { break }
    $newSize = [Math]::Max([Math]::Floor($curSize / 2), 1)
    $newBmp = New-Object System.Drawing.Bitmap $newSize, $newSize, ([System.Drawing.Imaging.PixelFormat]::Format32bppArgb)
    $newG = [System.Drawing.Graphics]::FromImage($newBmp)
    $newG.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic
    $newG.PixelOffsetMode = [System.Drawing.Drawing2D.PixelOffsetMode]::HighQuality
    $newG.Clear([System.Drawing.Color]::FromArgb(0, 0, 0, 0))
    $newG.DrawImage($curBmp, (New-Object System.Drawing.Rectangle 0, 0, $newSize, $newSize))
    $newG.Dispose()
    if ($curBmp -ne $bmp) { $curBmp.Dispose() }
    $curBmp = $newBmp
    $curSize = $newSize
}
$bmp.Dispose()
if ($curBmp -ne $bmp) { $curBmp.Dispose() }

# ============================================================
# DDS header (128 bytes) - matches GrainCollection's flag/caps pattern,
# legacy 'DXT5' fourCC instead of DX10 extended header.
# ============================================================

function Write-LE($buf, $off, $val) {
    $b = [System.BitConverter]::GetBytes([uint32]$val)
    [Array]::Copy($b, 0, $buf, $off, 4)
}

$header = New-Object byte[] 128
$header[0] = 0x44; $header[1] = 0x44; $header[2] = 0x53; $header[3] = 0x20  # 'DDS '

Write-LE $header 4   124
Write-LE $header 8   ([uint32]0xA1007)  # CAPS|HEIGHT|WIDTH|PIXELFORMAT|MIPMAPCOUNT|LINEARSIZE
Write-LE $header 12  $size
Write-LE $header 16  $size
# BC3 linearSize = blocks_w * blocks_h * 16. For 128x128: 32*32*16 = 16384
Write-LE $header 20  16384
Write-LE $header 24  0
Write-LE $header 28  $mipCount

Write-LE $header 76  32
Write-LE $header 80  ([uint32]0x4)       # DDPF_FOURCC
$header[84] = 0x44  # 'D'
$header[85] = 0x58  # 'X'
$header[86] = 0x54  # 'T'
$header[87] = 0x35  # '5'

Write-LE $header 108 ([uint32]0x401008)  # TEXTURE|MIPMAP|COMPLEX

# ============================================================
# Concatenate and write
# ============================================================

$total = $header.Length
foreach ($m in $mips) { $total += $m.Length }
$out = New-Object byte[] $total
[Array]::Copy($header, 0, $out, 0, $header.Length)
$cursor = $header.Length
foreach ($m in $mips) {
    [Array]::Copy($m, 0, $out, $cursor, $m.Length)
    $cursor += $m.Length
}

$ddsPath = "$PSScriptRoot\icon_animalWaste.dds"
[IO.File]::WriteAllBytes($ddsPath, $out)

# ============================================================
# Build-time verification (greppable [AW-VERIFY-BUILD])
# ============================================================

$nzPct = [Math]::Round(100.0 * $nonZeroAlpha / $totalPx, 1)
$opPct = [Math]::Round(100.0 * $fullyOpaque  / $totalPx, 1)

Write-Host ""
Write-Host "[AW-VERIFY-BUILD] icon=icon_animalWaste.dds"
Write-Host ("[AW-VERIFY-BUILD]   file size: {0} bytes" -f $out.Length)
Write-Host ("[AW-VERIFY-BUILD]   format: BC3/DXT5 (8-bit alpha, DXT5 color)")
Write-Host ("[AW-VERIFY-BUILD]   dimensions: {0} x {0}" -f $size)
Write-Host ("[AW-VERIFY-BUILD]   mipmap count: {0}" -f $mipCount)
Write-Host ("[AW-VERIFY-BUILD]   alpha channel: YES (full 8-bit)")
Write-Host ("[AW-VERIFY-BUILD]   source pixels with alpha > 0:  {0}/{1} ({2}%)" -f $nonZeroAlpha, $totalPx, $nzPct)
Write-Host ("[AW-VERIFY-BUILD]   source pixels fully opaque:    {0}/{1} ({2}%)" -f $fullyOpaque, $totalPx, $opPct)
Write-Host ("[AW-VERIFY-BUILD]   PNG source: {0} bytes" -f (Get-Item "$PSScriptRoot\icon_animalWaste.png").Length)
Write-Host ("[AW-VERIFY-BUILD]   preview: $scratch\icon_animalWaste_preview_dark.png")
