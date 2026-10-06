# OCR gratuito con el motor de Windows (Windows.Media.Ocr).
# Get-ImageOcrRows 'ruta.png' [-Scale 3] -> filas {y,x,t} (posicion en la imagen original y texto), o $null si no hay motor OCR; Invoke-ImageOcr devuelve el texto formateado.
# La imagen se amplia e invierte antes de leerla (las capturas pequenas pierden puntos decimales y confunden I/1/3).
function Wait-WinRt($op, [Type]$resultType) {
    $m = ([System.WindowsRuntimeSystemExtensions].GetMethods() | Where-Object { $_.Name -eq 'AsTask' -and $_.GetParameters().Count -eq 1 -and $_.GetParameters()[0].ParameterType.Name -eq 'IAsyncOperation`1' })[0]
    $t = $m.MakeGenericMethod($resultType).Invoke($null, @($op)); $t.Wait(30000) | Out-Null; return $t.Result
}
function Convert-ImageForOcr([string]$path, [double]$scale, [bool]$invert) {
    Add-Type -AssemblyName System.Drawing
    $src = [System.Drawing.Image]::FromFile((Resolve-Path $path).Path)
    $w = [int]($src.Width * $scale); $h = [int]($src.Height * $scale)
    $bmp = New-Object System.Drawing.Bitmap $w, $h
    $g = [System.Drawing.Graphics]::FromImage($bmp); $g.InterpolationMode = [System.Drawing.Drawing2D.InterpolationMode]::HighQualityBicubic; $g.PixelOffsetMode = 'HighQuality'
    $ia = New-Object System.Drawing.Imaging.ImageAttributes
    if ($invert) {
        $cm = New-Object System.Drawing.Imaging.ColorMatrix
        $cm.Matrix00 = -1; $cm.Matrix11 = -1; $cm.Matrix22 = -1; $cm.Matrix33 = 1; $cm.Matrix44 = 1; $cm.Matrix40 = 1; $cm.Matrix41 = 1; $cm.Matrix42 = 1
        $ia.SetColorMatrix($cm)
    }
    $g.DrawImage($src, (New-Object System.Drawing.Rectangle 0, 0, $w, $h), 0, 0, $src.Width, $src.Height, [System.Drawing.GraphicsUnit]::Pixel, $ia)
    $g.Dispose(); $src.Dispose()
    $out = Join-Path ([IO.Path]::GetTempPath()) ("ocr-" + [guid]::NewGuid().ToString('N') + ".png"); $bmp.Save($out, [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose(); return $out
}
function Get-ImageOcrRows([string]$path, [double]$Scale = 3, [bool]$Invert = $true) {
    try {
        Add-Type -AssemblyName System.Runtime.WindowsRuntime
        $null = [Windows.Media.Ocr.OcrEngine, Windows.Foundation, ContentType = WindowsRuntime]
        $null = [Windows.Graphics.Imaging.BitmapDecoder, Windows.Foundation, ContentType = WindowsRuntime]
        $null = [Windows.Storage.StorageFile, Windows.Foundation, ContentType = WindowsRuntime]
        $eng = [Windows.Media.Ocr.OcrEngine]::TryCreateFromUserProfileLanguages()
        if (-not $eng) { $eng = [Windows.Media.Ocr.OcrEngine]::TryCreateFromLanguage([Windows.Globalization.Language]::new('en-US')) }
        if (-not $eng) { return $null }
        $tmp = Convert-ImageForOcr $path $Scale $Invert
        $file = Wait-WinRt ([Windows.Storage.StorageFile]::GetFileFromPathAsync($tmp)) ([Windows.Storage.StorageFile])
        $stream = Wait-WinRt ($file.OpenAsync([Windows.Storage.FileAccessMode]::Read)) ([Windows.Storage.Streams.IRandomAccessStream])
        $dec = Wait-WinRt ([Windows.Graphics.Imaging.BitmapDecoder]::CreateAsync($stream)) ([Windows.Graphics.Imaging.BitmapDecoder])
        $bmp = Wait-WinRt ($dec.GetSoftwareBitmapAsync()) ([Windows.Graphics.Imaging.SoftwareBitmap])
        $res = Wait-WinRt ($eng.RecognizeAsync($bmp)) ([Windows.Media.Ocr.OcrResult])
        $rows = @(); foreach ($l in $res.Lines) { $first = $null; foreach ($w in $l.Words) { $first = $w; break }; if ($first) { $rows += [pscustomobject]@{ y = [int]($first.BoundingRect.Y / $Scale); x = [int]($first.BoundingRect.X / $Scale); t = "$($l.Text)" } } }
        try { $stream.Dispose(); Remove-Item $tmp -Force -ErrorAction SilentlyContinue } catch {}
        return @($rows | Sort-Object y, x)
    } catch { return $null }
}
function Invoke-ImageOcr([string]$path, [double]$Scale = 3) {
    $r = Get-ImageOcrRows $path $Scale; if ($null -eq $r) { return $null }
    return (($r | ForEach-Object { "{0,4},{1,4}: {2}" -f $_.y, $_.x, $_.t }) -join "`n")
}
