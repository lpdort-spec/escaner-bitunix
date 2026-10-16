# /liquidez [MONEDA] [24h|3d|7d|30d]: mapa de calor de liquidaciones ESTIMADO (estilo Coinglass) como imagen.
# MODELO (no son datos reales de liquidaciones, que solo vende Coinglass y similares): cada vez que sube el interés abierto (Binance, histórico gratis ~30 días; si no está disponible, se usa el volumen como sustituto)
# se supone que las posiciones nuevas se abrieron a ese precio con apalancamientos 5x/10x/25x/50x/100x (mitad largos, mitad cortos). Su precio de liquidación se calcula (entrada -/+ 1/apalancamiento + margen de mantenimiento 0,5%)
# y se dibuja desde que nacen hasta que el precio lo toca (entonces se consideran liquidadas). Si el interés abierto baja, se reducen en proporción. Zonas más claras = más liquidaciones estimadas.
function Get-LiqWin([string]$w) {
    switch -Regex ($w.ToLower()) {
        '^(24h|1d)$' { return @{ iv = '15m'; n = 96; label = '24 horas' } }
        '^3d$' { return @{ iv = '30m'; n = 144; label = '3 días' } }
        '^(7d|1s|semana)$' { return @{ iv = '1h'; n = 168; label = '7 días' } }
        '^(30d|1m|mes)$' { return @{ iv = '4h'; n = 180; label = '30 días' } }
    }
    return $null
}
function Get-LiqHeat($coin, $win) {
    $sym = "${coin}USDT"
    $k = @((Invoke-RestMethod "$($script:CmdBase)/kline?symbol=$sym&interval=$($win.iv)&limit=$($win.n)" -TimeoutSec 25).data | Sort-Object { [long]$_.time })
    if ($k.Count -lt 30) { return $null }
    $nC = $k.Count
    $hi = [double[]]($k | ForEach-Object { $_.high }); $lo = [double[]]($k | ForEach-Object { $_.low }); $cl = [double[]]($k | ForEach-Object { $_.close }); $op = [double[]]($k | ForEach-Object { $_.open }); $qv = [double[]]($k | ForEach-Object { $_.quoteVol }); $tm = [long[]]($k | ForEach-Object { $_.time })
    $oi = $null; $fuente = 'volumen (sin interés abierto disponible)'
    try { $o = @(Invoke-RestMethod "https://fapi.binance.com/futures/data/openInterestHist?symbol=$sym&period=$($win.iv)&limit=$nC" -TimeoutSec 20 | ForEach-Object { $_ })
        if ($o.Count -ge 20) { $oi = New-Object 'double[]' $nC; $off = $o.Count - $nC; for ($q = 0; $q -lt $nC; $q++) { $ix = $q + $off; if ($ix -lt 0) { $ix = 0 }; $oi[$q] = [double]$o[$ix].sumOpenInterestValue }; $fuente = 'interés abierto de Binance' }
    } catch { $oi = $null }
    $cum = New-Object 'double[]' $nC; $cum[0] = 1.0
    for ($q = 1; $q -lt $nC; $q++) { $f = 1.0; if ($oi -and $oi[$q - 1] -gt 0 -and $oi[$q] -lt $oi[$q - 1]) { $f = $oi[$q] / $oi[$q - 1] }; $cum[$q] = $cum[$q - 1] * $f }
    $pmin = ($lo | Measure-Object -Minimum).Minimum * 0.985; $pmax = ($hi | Measure-Object -Maximum).Maximum * 1.015; $nR = 140; $step = ($pmax - $pmin) / $nR
    $heat = New-Object 'double[]' ($nC * $nR)
    $tiers = @(@(5, 0.10), @(10, 0.25), @(25, 0.30), @(50, 0.20), @(100, 0.15))
    for ($q = 1; $q -lt $nC; $q++) {
        $newV = 0.0; if ($oi) { $d = $oi[$q] - $oi[$q - 1]; if ($d -gt 0) { $newV = $d } } else { $newV = $qv[$q] * 0.04 }
        if ($newV -le 0) { continue }
        $px = ($hi[$q] + $lo[$q] + $cl[$q]) / 3.0
        foreach ($tr in $tiers) { $wt = $newV * $tr[1] * 0.5
            foreach ($sd in @(1, -1)) {      # 1 = largo (se liquida por debajo), -1 = corto (por encima)
                $lv = $px * (1 - $sd * (1.0 / $tr[0] - 0.005)); $r = [int][Math]::Floor(($lv - $pmin) / $step); if ($r -lt 0 -or $r -ge $nR) { continue }
                $endC = $nC; for ($j = $q + 1; $j -lt $nC; $j++) { if (($sd -eq 1 -and $lo[$j] -le $lv) -or ($sd -eq -1 -and $hi[$j] -ge $lv)) { $endC = $j; break } }
                for ($j = $q; $j -lt $endC; $j++) { $heat[$j * $nR + $r] += $wt * $cum[$j] / $cum[$q] } } } }
    # suavizado vertical (1-2-1)
    $sm = New-Object 'double[]' ($nC * $nR)
    for ($j = 0; $j -lt $nC; $j++) { for ($r = 0; $r -lt $nR; $r++) { $a = $heat[$j * $nR + $r] * 0.5; if ($r -gt 0) { $a += 0.25 * $heat[$j * $nR + $r - 1] }; if ($r -lt $nR - 1) { $a += 0.25 * $heat[$j * $nR + $r + 1] }; $sm[$j * $nR + $r] = $a } }
    return @{ coin = $coin; win = $win; nC = $nC; nR = $nR; pmin = $pmin; step = $step; heat = $sm; hi = $hi; lo = $lo; cl = $cl; tm = $tm; px = $cl[$nC - 1]; fuente = $fuente }
}
function Get-LiqPeaks($d) {      # mayores acumulaciones ESTIMADAS al final de la ventana, encima y debajo del precio
    $nR = $d.nR; $last = $d.nC - 1; $pr = [int][Math]::Floor(($d.px - $d.pmin) / $d.step); $vals = @()
    for ($r = 0; $r -lt $nR; $r++) { $sv = $d.heat[$last * $nR + $r]; if ($r -gt 0) { $sv += $d.heat[$last * $nR + $r - 1] }; if ($r -lt $nR - 1) { $sv += $d.heat[$last * $nR + $r + 1] }; $vals += , @($r, $sv) }
    $out = @{ up = @(); dn = @() }
    foreach ($side in @('up', 'dn')) { $cand = @($vals | Where-Object { if ($side -eq 'up') { $_[0] -gt $pr } else { $_[0] -lt $pr } } | Sort-Object { $_[1] } -Descending); $pick = @()
        foreach ($c in $cand) { if ($c[1] -le 0) { break }; $far = $true; foreach ($p in $pick) { if ([Math]::Abs($p[0] - $c[0]) -lt 6) { $far = $false; break } }; if ($far) { $pick += , $c }; if ($pick.Count -ge 3) { break } }
        $out[$side] = @($pick | ForEach-Object { $price = $d.pmin + ($_[0] + 0.5) * $d.step; @{ price = $price; pct = (($price / $d.px - 1) * 100); usd = $_[1] } }) }
    return $out
}
function New-LiqImage($d, $path) {
    try { Add-Type -AssemblyName System.Drawing -ErrorAction Stop } catch { return $null }
    $W0 = 1000; $H0 = 560; $x0 = 14; $x1 = $W0 - 78; $y0 = 46; $y1 = $H0 - 26
    $bmp = New-Object System.Drawing.Bitmap $W0, $H0; $g = [System.Drawing.Graphics]::FromImage($bmp); $g.SmoothingMode = 'AntiAlias'
    $g.Clear([System.Drawing.ColorTranslator]::FromHtml('#0b0f1a'))
    $stops = @(@(0.0, 38, 10, 70), @(0.25, 58, 76, 160), @(0.5, 32, 150, 155), @(0.75, 90, 200, 100), @(1.0, 253, 231, 37))
    $pal = @(); for ($i = 0; $i -le 63; $i++) { $t = $i / 63.0; for ($s = 0; $s -lt 4; $s++) { if ($t -le $stops[$s + 1][0]) { $u = ($t - $stops[$s][0]) / ($stops[$s + 1][0] - $stops[$s][0]); $rr = [int]($stops[$s][1] + $u * ($stops[$s + 1][1] - $stops[$s][1])); $gg = [int]($stops[$s][2] + $u * ($stops[$s + 1][2] - $stops[$s][2])); $bb = [int]($stops[$s][3] + $u * ($stops[$s + 1][3] - $stops[$s][3])); $pal += , (New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb($rr, $gg, $bb))); break } } }
    $pos = @($d.heat | Where-Object { $_ -gt 0 } | Sort-Object); $vmax = if ($pos.Count) { $pos[[Math]::Min($pos.Count - 1, [int]($pos.Count * 0.985))] } else { 1.0 }; if ($vmax -le 0) { $vmax = 1.0 }
    $cw = ($x1 - $x0) / [double]$d.nC; $chh = ($y1 - $y0) / [double]$d.nR
    $g.FillRectangle($pal[0], $x0, $y0, ($x1 - $x0), ($y1 - $y0))
    for ($j = 0; $j -lt $d.nC; $j++) { for ($r = 0; $r -lt $d.nR; $r++) { $v = $d.heat[$j * $d.nR + $r]; if ($v -le 0) { continue }; $t = [Math]::Sqrt([Math]::Min(1.0, $v / $vmax)); $ix = [int]($t * 63); if ($ix -lt 1) { continue }
        $g.FillRectangle($pal[$ix], [single]($x0 + $j * $cw), [single]($y1 - ($r + 1) * $chh), [single]($cw + 0.6), [single]($chh + 0.6)) } }
    # línea de precio
    $pen = New-Object System.Drawing.Pen ([System.Drawing.Color]::FromArgb(235, 255, 255, 255)), 1.6; $pts = @()
    for ($j = 0; $j -lt $d.nC; $j++) { $yy = $y1 - ($d.cl[$j] - $d.pmin) / ($d.step * $d.nR) * ($y1 - $y0); $pts += (New-Object System.Drawing.PointF ([single]($x0 + ($j + 0.5) * $cw)), ([single]$yy)) }
    if ($pts.Count -gt 1) { $g.DrawLines($pen, [System.Drawing.PointF[]]$pts) }
    $font = New-Object System.Drawing.Font 'Segoe UI', 9; $fontB = New-Object System.Drawing.Font 'Segoe UI', 12, ([System.Drawing.FontStyle]::Bold); $white = [System.Drawing.Brushes]::White; $gray = New-Object System.Drawing.SolidBrush ([System.Drawing.Color]::FromArgb(190, 200, 200, 210))
    for ($i = 0; $i -le 6; $i++) { $pv = $d.pmin + ($d.step * $d.nR) * $i / 6.0; $yy = $y1 - ($y1 - $y0) * $i / 6.0; $g.DrawString((TaFp $pv), $font, $gray, [single]($x1 + 4), [single]($yy - 7)) }
    $yp = $y1 - ($d.px - $d.pmin) / ($d.step * $d.nR) * ($y1 - $y0); $g.FillRectangle([System.Drawing.Brushes]::White, [single]$x1, [single]($yp - 8), 74, 16); $g.DrawString((TaFp $d.px), $font, [System.Drawing.Brushes]::Black, [single]($x1 + 3), [single]($yp - 8))
    $tz = $null; try { $tz = [TimeZoneInfo]::FindSystemTimeZoneById('Romance Standard Time') } catch {}
    foreach ($j in @(0, [int]($d.nC / 2), ($d.nC - 1))) { $dt = [DateTimeOffset]::FromUnixTimeMilliseconds($d.tm[$j]); if ($tz) { $dt = [TimeZoneInfo]::ConvertTime($dt, $tz) }; $tx = [Math]::Min($x1 - 70, [Math]::Max($x0, $x0 + $j * $cw - 30)); $g.DrawString($dt.ToString('dd/MM HH:mm'), $font, $gray, [single]$tx, [single]($y1 + 4)) }
    $g.DrawString(("{0}/USDT · Mapa de liquidaciones ESTIMADO · {1}" -f $d.coin, $d.win.label), $fontB, $white, 14, 10)
    $g.DrawString("Más claro = más liquidaciones estimadas · modelo con " + $d.fuente, $font, $gray, 14, 30)
    $g.Dispose(); $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose(); return $path
}
function Handle-Liquidez($args1, $chat, $token) {
    $coin = 'BTC'; $wins = @('24h', '3d')
    foreach ($w in @($args1)) { $s = "$w".Trim(); if (-not $s) { continue }; if (Get-LiqWin $s) { $wins = @($s) } else { $coin = ($s -replace 'USDT$', '' -replace '[^A-Za-z0-9]', '').ToUpper() } }
    foreach ($w in $wins) {
        $win = Get-LiqWin $w; $d = $null; try { $d = Get-LiqHeat $coin $win } catch { $d = $null }
        if (-not $d) { Send-Tg $token $chat "No he podido construir el mapa de $coin ($w): compruebo que sea un futuro de Bitunix con historial suficiente." $null; continue }
        $path = Join-Path ([IO.Path]::GetTempPath()) ("liq-" + [guid]::NewGuid().ToString('N') + ".png"); $img = New-LiqImage $d $path
        $pk = Get-LiqPeaks $d
        $fm = { param($lst) if (-not $lst.Count) { return "—" }; return (($lst | ForEach-Object { "{0} ({1:+0.0;-0.0}%, ≈{2:N0} M USD)" -f (TaFp $_.price), $_.pct, ($_.usd / 1e6) }) -join " · ") }
        $txt = ("💧 MAPA DE LIQUIDACIONES ESTIMADO · {0}/USDT · {1} · precio {2}`nMayores acumulaciones estimadas:`n▲ Encima (liquidaciones de CORTOS): {3}`n▼ Debajo (liquidaciones de LARGOS): {4}`nModelo con {5}. No son datos reales de liquidaciones (eso solo lo dan los mapas de pago tipo Coinglass): úsalo como orientación de hacia dónde puede ir a buscar liquidez el precio, no como señal. Sin ventaja predictiva medida." -f $coin, $win.label, (TaFp $d.px), (& $fm $pk.up), (& $fm $pk.dn), $d.fuente)
        if ($img) { $cap = ("{0}/USDT · mapa de liquidaciones estimado · {1}" -f $coin, $win.label); $ok = Send-TelegramPhoto $token $chat $img $cap; try { Remove-Item $img -Force } catch {}; if (-not $ok) { $txt = "(No he podido enviar la imagen.)`n" + $txt } } else { $txt = "(Este entorno no puede dibujar la imagen.)`n" + $txt }
        Send-Tg $token $chat $txt $null
    }
}
