# Análisis de operaciones a partir de una captura de pantalla de Bitunix (solo chat privado de Luis): el bot lee la imagen con OCR gratuito (ocr.ps1), interpreta la tabla "Posiciones"
# (símbolo, entrada, marcado, margen, liquidación, SL/TP, PYG), valora la operación con datos en vivo y la deja en vigilancia (strat 'tomada'). Si algún dato no se lee bien, lo dice y no registra nada.
function Convert-OcrNumber([string]$s, [bool]$allowNoDot = $true) {
    $x = ("$s" -replace '[^0-9,\.\-]', ''); if (-not $x) { return $null }
    $x = $x.TrimStart('-')
    if ($x -match ',' -and $x -match '\.') { $x = $x -replace ',', '' }
    elseif ($x -match ',') { if ($x -match '^\d{1,3}(,\d{3})+$') { $x = $x -replace ',', '' } else { $x = $x -replace ',', '.' } }
    elseif ($x -notmatch '\.') { if ($allowNoDot -and $x.Length -ge 3 -and $x.StartsWith('0')) { $x = '0.' + $x.Substring(1) } else { return $null } }
    $d = 0.0; if ([double]::TryParse($x, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$d)) { return $d } else { return $null }
}
function Get-OcrCanon([string]$s) { return (($s.ToUpper() -replace '[1L\|]', 'I' -replace '[0Q]', 'O' -replace '5', 'S' -replace '8', 'B')) }
function Resolve-OcrSymbol([string]$token, $symbols) {
    $c1 = Get-OcrCanon $token; $cands = @($c1); if ($c1.Length -gt 3) { $cands += $c1.Substring(1) }
    foreach ($c in $cands) { $hit = @($symbols | Where-Object { (Get-OcrCanon $_) -eq $c }); if ($hit.Count -eq 1) { return @{ sym = $hit[0]; ok = $true } } }
    return @{ sym = $null; ok = $false }
}
function Test-OcrAvailable {      # autocomprobación: dibuja un texto, lo lee con el OCR y comprueba que sale el número
    try {
        Add-Type -AssemblyName System.Drawing
        $b = New-Object System.Drawing.Bitmap 420, 90; $g = [System.Drawing.Graphics]::FromImage($b); $g.Clear([System.Drawing.Color]::Black)
        $f = New-Object System.Drawing.Font 'Arial', 22; $g.DrawString('API3USDT 0.3812', $f, [System.Drawing.Brushes]::White, 8, 20); $g.Dispose()
        $tmp = Join-Path ([IO.Path]::GetTempPath()) ("ocrtest-" + [guid]::NewGuid().ToString('N') + ".png"); $b.Save($tmp, [System.Drawing.Imaging.ImageFormat]::Png); $b.Dispose()
        $rows = Get-ImageOcrRows $tmp; Remove-Item $tmp -Force -ErrorAction SilentlyContinue
        if ($null -eq $rows) { return $false }; return [bool](($rows | ForEach-Object { $_.t }) -join ' ' -match '3812')
    } catch { return $false }
}
function Get-SideByColor([string]$path, [int]$y0, [int]$y1) {
    try {
        Add-Type -AssemblyName System.Drawing
        $img = New-Object System.Drawing.Bitmap ((Resolve-Path $path).Path); $g = 0; $r = 0
        for ($y = $y0; $y -lt [Math]::Min($y1, $img.Height); $y += 1) { for ($x = 0; $x -lt [Math]::Min(450, $img.Width); $x += 1) {
            $c = $img.GetPixel($x, $y)
            if ($c.G -gt 130 -and $c.R -lt 100 -and $c.B -lt 170 -and $c.G - $c.R -gt 80) { $g++ } elseif ($c.R -gt 170 -and $c.G -lt 110 -and $c.B -lt 120) { $r++ } } }
        $img.Dispose(); if ($g -gt 80 -and $g -gt 2 * $r) { return 1 }; if ($r -gt 80 -and $r -gt 2 * $g) { return -1 }; return 0
    } catch { return 0 }
}
function Read-PositionScreenshot([string]$path, [string]$captionSym) {      # varias pasadas (distinta ampliación/inversión); cada una rellena lo que falta
    $merged = $null
    foreach ($cfg in @(@(3, $true), @(4, $true), @(6, $true), @(2, $true), @(4, $false))) {
        $q = Read-PositionOnce $path $captionSym $cfg[0] $cfg[1]
        if ($q.error) { if (-not $merged) { $merged = $q }; if ($q.error -like '*no está disponible*') { return $q }; continue }
        if (-not $merged -or $merged.error) { $merged = $q } else { foreach ($k in @($q.Keys)) { if ($k -eq 'notes') { $merged.notes = @($merged.notes) + @($q.notes) | Select-Object -Unique } elseif (-not $merged.ContainsKey($k) -or $null -eq $merged[$k]) { $merged[$k] = $q[$k] } } }
        if ($merged.sym -and $merged.entry -and $merged.side -and $merged.margin -and ($merged.levels -or $merged.sl) -and ($merged.levLabel -or $merged.qty)) { break }
    }
    # apalancamiento definitivo tras juntar las pasadas: etiqueta "7X" > cantidad x ENTRADA / margen > nocional marcado / margen (el nocional a precio marcado da un apalancamiento menor del real cuando el precio se ha movido)
    if ($merged -and -not $merged.error) { $lvF = $null
        if ($merged.levLabel) { $lvF = [double]$merged.levLabel }
        elseif ($merged.qty -and $merged.entry -and $merged.margin -and $merged.margin -gt 0) { $z = $merged.qty * $merged.entry / $merged.margin; if ([Math]::Abs($z - [Math]::Round($z)) -lt 0.3 -and $z -ge 1 -and $z -le 150) { $lvF = [Math]::Round($z) } }
        if ($lvF) { $merged.lev = $lvF } }
    if ($merged -and -not $merged.error -and $merged.entry -and $merged.side -and $merged.levels -and -not ($merged.sl -or $merged.tp)) {
        if (@($merged.levels).Count -eq 2) { $merged.tp = [double]$merged.levels[0]; $merged.sl = [double]$merged.levels[1] }      # Bitunix muestra "TP/SL": con dos precios el primero es el TP y el segundo el SL (el SL puede estar ya en beneficio)
        else { foreach ($n in $merged.levels) { if ($merged.side * ($n - $merged.entry) -gt 0) { $merged.tp = $n } else { $merged.sl = $n } } } }
    return $merged
}
function Read-PositionOnce([string]$path, [string]$captionSym, [double]$sc0, [bool]$inv) {
    $rows = Get-ImageOcrRows $path $sc0 $inv; if ($null -eq $rows) { return @{ error = "El OCR no está disponible en este entorno." } }
    if (-not @($rows).Count) { return @{ error = "No he conseguido leer texto en la imagen." } }
    $fw = 1580.0; try { Add-Type -AssemblyName System.Drawing; $im = [System.Drawing.Image]::FromFile((Resolve-Path $path).Path); $fw = [double]$im.Width; $im.Dispose() } catch {}
    $f = [Math]::Max(0.5, [Math]::Min(1.8, $fw / 1580.0))
    $p = @{ notes = @() }
    $find = { param($rx) @($rows | Where-Object { $_.t -match $rx } | Select-Object -First 1)[0] }
    $below = { param($h, $dx = 70) if (-not $h) { return $null }; @($rows | Where-Object { $_.y -gt $h.y + 8 * $f -and $_.y -lt $h.y + 80 * $f -and [Math]::Abs($_.x - $h.x) -le ($dx * $f + 25) } | Sort-Object y, x | Select-Object -First 1)[0] }
    # modo de margen (Aislado / Cruzada) junto al símbolo
    $modeRow = @($rows | Where-Object { $_.y -lt 110 -and $_.t -match '(?i)\b(cruzad[ao]|aislad[ao]|cross|isolated)\b' } | Select-Object -First 1)[0]
    if ($modeRow) { $p.mode = $(if ($modeRow.t -match '(?i)cruzad|cross') { 'cruzada' } else { 'aislada' }) }
    # símbolo
    $symRow =@($rows | Where-Object { $_.y -lt 110 -and $_.t -match '(?i)[A-Z0-9]{2,12}\s*USDT' } | Select-Object -First 1)[0]
    $tick = @((Invoke-RestMethod "$($script:CmdBase)/tickers" -TimeoutSec 20).data)
    $bases = @($tick | ForEach-Object { $_.symbol -replace 'USDT$', '' })
    if ($captionSym) { $p.sym = ($captionSym.ToUpper() -replace 'USDT$', '') }
    elseif ($symRow -and $symRow.t -match '(?i)([A-Z0-9]{2,12})\s*USDT') { $r = Resolve-OcrSymbol $Matches[1] $bases; if ($r.ok) { $p.sym = $r.sym } else { $p.notes += "no reconozco con seguridad el símbolo (leído '$($Matches[1])')" } }
    else { $p.notes += "no encuentro el símbolo" }
    if ($p.sym -and $p.sym -notin $bases) { $p.notes += "$($p.sym) no existe en Bitunix"; $p.sym = $null }
    $live = $null; if ($p.sym) { $live = [double]($tick | Where-Object symbol -eq "$($p.sym)USDT" | Select-Object -First 1).lastPrice; $p.live = $live }
    $near = { param($v) $v -and $live -gt 0 -and [Math]::Abs($v / $live - 1) -lt 0.35 }
    # columnas por cabecera
    $hEntry = & $find '(?i)precio de entrada'; $hMark = & $find '(?i)precio marcado'; $hMargin = & $find '(?i)^margen'; $hLiq = & $find '(?i)liq'; $hPnl = & $find '(?i)no realizado'; $hTp = & $find '(?i)posici.n\s*TP'; $hPos = @($rows | Where-Object { $_.t -match '(?i)^posici.n\s*$' } | Select-Object -First 1)[0]
    $v = & $below $hEntry; if ($v) { $n = Convert-OcrNumber (($v.t -split '\s+')[0]); if ($n -and (-not $live -or (& $near $n))) { $p.entry = $n } }
    $v = & $below $hMark; if ($v) { $n = Convert-OcrNumber (($v.t -split '\s+')[0]); if ($n) { $p.mark = $n } }
    $v = & $below $hMargin; if ($v) { $n = Convert-OcrNumber (($v.t -split '\s+')[0]) $false; if ($n) { $p.margin = $n } }
    $v = & $below $hLiq; if ($v) { $n = Convert-OcrNumber (($v.t -split '\s+')[0]); if ($n) { $p.liq = $n } }
    $v = & $below $hPnl 120; if ($v) { $p.pnlNeg = ($v.t -match '^\s*-'); $m1 = [regex]::Match($v.t, '[+-]?\d+[\.,]\d+'); if ($m1.Success) { $p.pnl = (Convert-OcrNumber $m1.Value $false) } }
    $v = & $below $hPos 90; if ($v -and $v.t -match '([\d,]+\.\d+)\s*USDT') { $p.notional = Convert-OcrNumber $Matches[1] $false }
    if ($v) { $q0 = ($v.t -split '[≈=~]')[0]; $qn = Convert-OcrNumber (($q0 -split '\s+' | Where-Object { $_ -match '\d' } | Select-Object -First 1)) $false; if ($qn -and $qn -gt 0) { $p.qty = $qn } }      # cantidad de la posición (unidades)
    $levRow = @($rows | Where-Object { $_.y -lt 110 -and $_.t -match '(?i)(?<![\d.,])(\d{1,3})\s*[xX](?![A-Za-z0-9])' } | Select-Object -First 1)[0]; if ($levRow -and $levRow.t -match '(?i)(?<![\d.,])(\d{1,3})\s*[xX](?![A-Za-z0-9])') { $lvl = [double]$Matches[1]; if ($lvl -ge 1 -and $lvl -le 150) { $p.levLabel = $lvl } }      # etiqueta de apalancamiento junto al símbolo (ej. 7X)
    # SL / TP (fila bajo "Posición TP/SL": uno o dos precios; se quitan los importes entre paréntesis)
    if ($hTp) {
        $txt = (@($rows | Where-Object { $_.y -gt $hTp.y + 10 -and $_.y -lt $hTp.y + 80 -and $_.x -ge $hTp.x - 60 } | Sort-Object y, x | ForEach-Object { $_.t }) -join ' ')
        $txt0 = $txt
        $clean = { param($s) $s -replace '\(?\s*[\$S]\s*[\d,\.]+\s*\)?', ' ' -replace '\([^)]*\)', ' ' }
        $txt = & $clean $txt
        $nums = @([regex]::Matches($txt, '\d+[\.,]\d{2,}') | ForEach-Object { Convert-OcrNumber $_.Value $false } | Where-Object { $_ -and ((-not $live) -or (& $near $_)) })
        $p.levels = $nums
        # formato "TP / SL": lo de la izquierda de la barra es el TP y lo de la derecha el SL (sirve también si el SL ya está en beneficio)
        if ($txt0 -match '/') { $halves = @($txt0 -split '/'); if ($halves.Count -eq 2) {
            $hn = @(); foreach ($h2 in $halves) { $c2 = & $clean $h2; $m2 = [regex]::Match($c2, '\d+[\.,]\d{2,}'); $val = $null; if ($m2.Success) { $val = Convert-OcrNumber $m2.Value $false; if (-not ($val -and ((-not $live) -or (& $near $val)))) { $val = $null } }; $hn += $val }
            if ($hn[0]) { $p.tp = $hn[0] }; if ($hn[1]) { $p.sl = $hn[1] } } }
    }
    # lado: texto Largo/Corto si se leyó; si no, por el signo del PYG frente a marcado/entrada
    $sideTxt = @($rows | Where-Object { $_.y -lt 110 -and $_.t -match '(?i)\b(largo|corto|long|short)\b' } | Select-Object -First 1)[0]
    if ($sideTxt) { $p.side = $(if ($sideTxt.t -match '(?i)largo|long') { 1 } else { -1 }) }
    else {
        # la etiqueta Largo (verde) / Corto (roja) está junto al símbolo: se cuenta el color de sus píxeles
        $sy = if ($symRow) { $symRow.y } else { 60 }; $sc = Get-SideByColor $path ([Math]::Max(0, $sy - 12)) ([int]$sy + 34)
        if ($sc) { $p.side = $sc }
        elseif ($p.levels -and @($p.levels).Count -ge 2) { $p.side = $(if ($p.levels[0] -gt $p.levels[1]) { 1 } else { -1 }); $p.notes += "lado deducido del orden TP/SL" }
    }
    # apalancamiento = nocional / margen (debe salir casi entero)
    # prioridad: etiqueta "7X" junto al símbolo > cantidad x ENTRADA / margen (el margen se calcula con el precio de entrada, no con el marcado) > nocional a precio marcado / margen
    if ($p.levLabel) { $p.lev = $p.levLabel }
    elseif ($p.qty -and $p.entry -and $p.margin -and $p.margin -gt 0) { $lv = $p.qty * $p.entry / $p.margin; if ([Math]::Abs($lv - [Math]::Round($lv)) -lt 0.3 -and $lv -ge 1 -and $lv -le 150) { $p.lev = [Math]::Round($lv) } }
    if (-not $p.lev -and $p.notional -and $p.margin -and $p.margin -gt 0) { $lv = $p.notional / $p.margin; if ([Math]::Abs($lv - [Math]::Round($lv)) -lt 0.2 -and $lv -ge 1 -and $lv -le 150) { $p.lev = [Math]::Round($lv); $p.notes += "apalancamiento deducido del nocional a precio marcado: puede estar desviado" } }
    if ($p.levels -and $p.entry -and $p.side -and -not ($p.tp -or $p.sl)) {
        if (@($p.levels).Count -eq 2) { $p.tp = [double]$p.levels[0]; $p.sl = [double]$p.levels[1] }      # orden "TP/SL"
        else { foreach ($n in $p.levels) { if ($p.side * ($n - $p.entry) -gt 0) { $p.tp = $n } else { $p.sl = $n } } }
    }
    return $p
}
function Get-CaptureAtr($sym) {
    try { $cd = Get-MomentoCd @{ src = 'bitunix'; sym = $sym } '4h'; $a = Analyze-TF $cd '4h' 100; return $a } catch { return $null }
}
function Format-CapturaAnalysis($p, [bool]$register, [string]$who) {
    $sym = $p.sym; $sg = [int]$p.side; $dir = if ($sg -eq 1) { "LARGO" } else { "CORTO" }; $en = [double]$p.entry; $px = if ($p.live) { [double]$p.live } else { [double]$p.mark }
    $sl = $p.sl; $tp = $p.tp; $lev = $p.lev; $mg = $p.margin; $L = @()
    $L += ("📸 CAPTURA LEÍDA · {0} {1}{2} · entrada {3} · ahora {4}{5}{6}{7}" -f $sym, $dir, $(if ($lev) { " x$lev" } else { "" }), (TaFp $en), (TaFp $px), $(if ($mg) { " · margen {0:N0} USDT" -f $mg } else { "" }), $(if ($p.liq) { " · liq. " + (TaFp $p.liq) } else { "" }), "")
    if ($p.mode -eq 'cruzada') { $L = @("🚨 MARGEN CRUZADO: tu regla es operar SIEMPRE en AISLADO. En cruzado, un movimiento brusco puede arrastrar el resto de tu cuenta. Cámbialo a aislado desde el icono de margen de esa posición.") + $L }
    $L += ("   SL: {0} · TP: {1}" -f $(if ($sl) { TaFp $sl } else { "⛔ NO TIENE" }), $(if ($tp) { TaFp $tp } else { "sin TP" }))
    $pct = $sg * ($px / $en - 1) * 100; $L += ("   Resultado ahora: {0:+0.00;-0.00}% del precio{1}" -f $pct, $(if ($lev) { " (≈ {0:+0.0;-0.0}% del margen)" -f ($pct * $lev) } else { "" }))
    $a = Get-CaptureAtr $sym; $atr = if ($a) { [double]$a.atr } else { 0.0 }
    # lectura del activo
    $ctx = $null; $own = $null; $opp = $null; $neg = @(); $pos = @()
    try { $ss = @{ src = 'bitunix'; sym = $sym; name = "$sym/USDT"; currency = 'USDT'; exch = ''; price = $px; extra = @{ funding = $null } }; $sc = Get-MomScores $ss
        if ($sc) { $me = if ($sg -eq 1) { $sc.lg } else { $sc.st }; $op = if ($sg -eq 1) { $sc.st } else { $sc.lg }; $own = [int]$me.score; $opp = [int]$op.score; $ctx = $own
            $neg = @($me.fx | Where-Object { $_ -like '⚠️*' } | Select-Object -First 3); $pos = @($me.fx | Where-Object { $_ -like '✅*' } | Select-Object -First 3) } } catch {}
    if ($null -ne $own) { $L += ""; $L += ("🧭 Lectura del activo: puntuación {0} a favor de tu dirección (contraria {1})" -f $own, $opp); $neg | ForEach-Object { $L += "   $_" }; $pos | ForEach-Object { $L += "   $_" } }
    if ($atr -gt 0) { $L += ("   Volatilidad 4h (ATR): {0} = {1:N1}% del precio" -f (TaFp $atr), ($atr / $px * 100)) }
    # estructura reciente en 1h: extremo de las últimas 48 velas
    $recent = $null
    $ext = $null
    try { $k = @((Invoke-RestMethod "$($script:CmdBase)/kline?symbol=${sym}USDT&interval=1h&limit=80" -TimeoutSec 20).data | Sort-Object { [long]$_.time }); $k = @($k[0..($k.Count - 2)])
        # extensión en 1h: Bollinger(20,2) y RSI(14) con las velas cerradas; fuera de banda 2 de las últimas 3 velas o RSI extremo = movimiento estirado
        $cl1 = @($k | ForEach-Object { [double]$_.close }); $nOut = 0; $bbm = $null
        for ($q = 1; $q -le 3; $q++) { $sub = @($cl1[0..($cl1.Count - $q)]); $x20 = @($sub | Select-Object -Last 20); $mm = ($x20 | Measure-Object -Average).Average; $sd = [Math]::Sqrt((($x20 | ForEach-Object { ($_ - $mm) * ($_ - $mm) }) | Measure-Object -Sum).Sum / 20); if ($q -eq 1) { $bbm = $mm; $bbu = $mm + 2 * $sd; $bbl = $mm - 2 * $sd }
            if (($sg -eq 1 -and $sub[-1] -gt $mm + 2 * $sd) -or ($sg -eq -1 -and $sub[-1] -lt $mm - 2 * $sd)) { $nOut++ } }
        $gg = 0.0; $ll2 = 0.0; for ($q = 1; $q -le 14; $q++) { $d = $cl1[$q] - $cl1[$q - 1]; if ($d -gt 0) { $gg += $d } else { $ll2 -= $d } }; $gg /= 14; $ll2 /= 14
        for ($q = 15; $q -lt $cl1.Count; $q++) { $d = $cl1[$q] - $cl1[$q - 1]; $gg = ($gg * 13 + [Math]::Max($d, 0)) / 14; $ll2 = ($ll2 * 13 + [Math]::Max(-$d, 0)) / 14 }
        $rsi1 = if ($ll2 -eq 0) { 100 } else { 100 - 100 / (1 + $gg / $ll2) }
        $stretched = ($nOut -ge 2) -or ($sg -eq 1 -and $rsi1 -ge 75) -or ($sg -eq -1 -and $rsi1 -le 25)
        $ext = @{ nOut = $nOut; rsi = $rsi1; mid = $bbm; up = $bbu; lo = $bbl; stretched = $stretched }
        $k = @($k | Select-Object -Last 48)
        $recent = if ($sg -eq 1) { ($k | ForEach-Object { [double]$_.high } | Measure-Object -Maximum).Maximum } else { ($k | ForEach-Object { [double]$_.low } | Measure-Object -Minimum).Minimum } } catch {}
    if ($ext) { $L += ("   Bollinger 1h: media {0} · banda {1} {2} · RSI 1h {3:N0} · {4} de las últimas 3 velas cerraron fuera de la banda{5}" -f (TaFp $ext.mid), $(if ($sg -eq 1) { "sup." } else { "inf." }), (TaFp $(if ($sg -eq 1) { $ext.up } else { $ext.lo })), $ext.rsi, $ext.nOut, $(if ($ext.stretched) { " ⚠️ MOVIMIENTO ESTIRADO: lo habitual es volver hacia la media de 1h (" + (TaFp $ext.mid) + "); no persigas ni añadas aquí" } else { "" })) }
    try { if (Get-Command Get-MultiTfLine -ErrorAction SilentlyContinue) { $mt = Get-MultiTfLine $sg $sym $px; if ($mt) { $L += $mt } } } catch {}      # 15m, 1h, 4h, 1D, 1S y 1M frente a tu dirección
    # veredicto con reglas fijas
    $L += ""; $verdict = "MANTENER"; $why = @(); $inProfit = $false
    if (-not $sl) {
        $dsug = if ($lev -and $lev -gt 0) { $en * (Get-SlMaxPct) / 100 / $lev } else { [Math]::Max(1.2 * $atr, 0.02 * $en) }
        $liqTxt = if ($p.liq) { " (liquidación a {0:N1}% del precio)" -f ([Math]::Abs($px - $p.liq) / $px * 100) } else { "" }
        $ruido = if ($lev -and $atr -gt 0) { "; es lo que cuesta el {0:N0}% del margen con x{1}: si queda dentro del ruido normal (ATR 4h {2:N1}%), baja el apalancamiento" -f (Get-SlMaxPct), $lev, ($atr / $px * 100) } else { "" }
        $verdict = "PROTEGER YA"; $why += ("no tiene stop: una posición sin SL puede liquidarse{0}. Pon uno ahora (sugerido {1}{2})" -f $liqTxt, (TaFp ($en - $sg * $dsug)), $ruido) }
    else {
        $inProfit = (($sg * ($sl - $en)) -gt 0)      # SL del lado del beneficio (corto con SL bajo la entrada / largo con SL sobre ella): si salta se GANA
        if ($inProfit) {
            $lk = $sg * ($sl / $en - 1) * 100; $L += ("🔒 SL en beneficio ({0}): si salta aseguras ≈ {1:+0.0;-0.0}% del precio{2}. No hay pérdida posible por el SL." -f (TaFp $sl), $lk, $(if ($mg -and $lev) { " (≈ +{0:N0} USDT)" -f ($mg * $lev * $lk / 100) } else { "" }))
            if ($atr -gt 0 -and ($sg * ($px - $sl)) -lt 0.8 * $atr) { $L += ("   El precio está a solo {0:N1} ATR de tu SL: si salta, cierras con ese beneficio." -f (($sg * ($px - $sl)) / $atr)) }
        } else {
        $R = [Math]::Abs($en - $sl); $slPct = $R / $en * 100; $costMg = if ($lev) { $slPct * $lev } else { $null }; $dSl = $sg * ($px - $sl)
        if ($costMg) { $L += ("🛡️ Si salta el SL pierdes ≈ {0:N0} USDT ({1:N0}% del margen){2}" -f ($mg * $costMg / 100), $costMg, $(if ($costMg -gt (Get-SlMaxPct)) { " ⚠️ por encima de tu límite del {0:N0}%" -f (Get-SlMaxPct) } else { " ✔ dentro de tu regla del {0:N0}%" -f (Get-SlMaxPct) })) }
        if ($p.liq) { $dl = [Math]::Abs($px - $p.liq) / $px * 100; $L += ("   Liquidación a {0:N1}% del precio y SL a {2:N1}%: {1}" -f $dl, $(if ([Math]::Abs($sl - $px) / $px * 100 -lt $dl * 0.8) { "queda más lejos ✔" } else { "⚠️ demasiado cerca" }), ([Math]::Abs($sl - $px) / $px * 100)) }
        if ($atr -gt 0 -and $dSl -lt 0.8 * $atr) { $L += ("⚠️ El SL queda a solo {0:N1} ATR del precio: es fácil que el ruido normal lo toque." -f ($dSl / $atr)) }
        if ($sg * ($px - $en) / $R -ge 1.0) { $verdict = "PROTEGER"; $why += "ya vas a +{0:N1}R: cierra un tercio y mueve el SL a tu entrada ({1})" -f ($sg * ($px - $en) / $R), (TaFp $en) }
        }
    }
    if ($ext -and $ext.stretched -and $verdict -eq "MANTENER") { if ($pct -gt 0) { $verdict = "PROTEGER"; $why += "el activo está estirado en 1h y vas en beneficio: toma un parcial ya y sube el SL a la entrada" } else { $verdict = "VIGILAR"; $why += "el activo está estirado en 1h: riesgo de retroceso hacia la media; no añadas posición" } }
    if ($null -ne $own -and $own -le 0 -and $opp -ge 6) { if ($inProfit) { $verdict = "PROTEGER"; $why += "la lectura se ha dado la vuelta en contra, pero tu SL ya asegura beneficio: valora tomar un parcial y deja el resto con ese SL" } else { $verdict = "CERRAR"; $why += "la lectura del activo se ha dado la vuelta en contra" } }
    elseif ($null -ne $own -and $own -lt 4 -and $verdict -eq "MANTENER") { $verdict = "VIGILAR"; $why += "la puntuación es floja ($own); si pierde más, valora cerrar" }
    if ($mg -and $mg -gt 200) { $L += ("⚠️ El margen ({0:N0} USDT) supera tu límite de 200 USDT." -f $mg) }
    $icon = switch ($verdict) { 'CERRAR' { "⛔" } 'PROTEGER YA' { "🚨" } 'PROTEGER' { "🔔" } 'VIGILAR' { "⚠️" } default { "✅" } }
    $L += ("{0} VEREDICTO: {1}{2}" -f $icon, $verdict, $(if ($why.Count) { " · " + ($why -join "; ") } else { " · la operación sigue vigente con el plan que tienes" }))
    # propuesta de objetivos
    $tgt = $null
    if ($sl -and -not $inProfit) { $R = [Math]::Abs($en - $sl); $t1 = $en + $sg * $R; $t2 = $en + $sg * 2 * $R; $t3 = $en + $sg * 3 * $R
        $obst = if ($recent -and $sg * ($recent - $px) -gt 0.3 * [Math]::Max($atr, 0.001)) { $recent } else { $null }
        $L += "🎯 Objetivos propuestos (parciales en tercios):"
        $L += ("   TP1 {0} (1R) → cierra un tercio y SL a entrada · TP2 {1} (2R){2}" -f (TaFp $t1), (TaFp $t2), $(if ($obst) { " · ⚠️ máximo reciente en " + (TaFp $obst) + ": zona donde puede frenarse; buen sitio para otro parcial" } else { "" }))
        if ($tp) { $L += ("   Tu TP ({0}) = {1:N1}R" -f (TaFp $tp), ($sg * ($tp - $en) / $R)) } else { $L += ("   TP final sugerido: {0} (3R){1}" -f (TaFp $t3), $(if ($obst -and $sg * ($t3 - $obst) -gt 0) { " — o antes, en " + (TaFp $obst) + " si no lo supera" } else { "" })) }
        $L += "   Regla de gestión: no subas el SL a la entrada hasta TP1 (hacerlo antes te saca por ruido normal); sí a la entrada al tocar TP1."
        $tgt = @{ t1 = $t1; t2 = $t2; t3 = $(if ($tp) { $tp } else { $t3 }) }
    }
    if ($register -and $sl -and $tgt) {
        $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds(); $all2 = @(Read-Signals); $dirty = $false
        foreach ($r in $all2) { if ($r.strat -eq 'tomada' -and $r.status -eq 'open' -and $r.sym -eq "${sym}USDT" -and $r.dest -eq 'priv') { $r.status = 'closed'; $r.outcome = 'sustituida por una nueva captura'; $r.closedAt = $now; $dirty = $true } }
        if ($dirty) { Save-Signals $all2 }
        $R = [Math]::Abs($en - $sl)
        Add-SignalRecord ([ordered]@{
            id = "tomada-$sym-$now"; time = $now; sym = "${sym}USDT"; src = $null; tf = '4h'; strat = 'tomada'; dest = 'priv'; by = "$who"; chat = ""; side = $sg; entryType = 'market'
            entry = $en; sl = $sl; sl0 = $sl; tp1 = $tgt.t1; tp2 = $tgt.t2; tp3 = $tgt.t3; riskAbs = $R; slPct = ($R / $en * 100); lev = $(if ($lev) { $lev } else { 1 }); margin = $mg; status = 'open'; stage = 0; realized = 0.0; age = 0; lastLabel = 0; lab0 = 0
            cost = 0.0015; outcome = $null; R = $null; net = $null; ctxScore = $ctx; chkAt = $now; closeNote = ""; origen = "captura"; note = "Operación leída de una captura"
        })
        $L += ""; $L += "👁️ Operación registrada y vigilada en vivo: te aviso al momento de TP1/TP2/TP final, stop, cercanía al SL y cambios de lectura. Ciérrala con /señal cerrada $sym PRECIO."
    }
    elseif ($register -and $inProfit -and $tp -and $mg -and $lev -and (Get-Command Add-LiveOrder -ErrorAction SilentlyContinue)) {
        try { Add-LiveOrder $sym $sg $en $sl $tp $mg $lev 'captura' "$who"; $L += ""; $L += "👁️ Operación registrada y vigilada en vivo con tu SL en beneficio ($(TaFp $sl)) y tu TP ($(TaFp $tp)). Ciérrala con /cerrar $sym PRECIO." } catch {}
    }
    return ($L -join "`n")
}
function Split-PositionBlocks([string]$path) {      # si la captura trae varias posiciones apiladas (cada una con su fila de símbolo), devuelve un PNG recortado por posición; si no, nada
    try { Add-Type -AssemblyName System.Drawing; $img = [System.Drawing.Image]::FromFile((Resolve-Path $path).Path) } catch { return @() }
    try {
        $rows = Get-ImageOcrRows $path 2 $true; if (-not $rows) { return @() }
        $heads = @($rows | Where-Object { $_.x -lt 200 -and $_.t -cmatch '(?<![A-Za-z0-9])[A-Z][A-Z0-9]{1,11}USDT\b' } | Sort-Object y)      # el icono de la moneda a veces se lee como "@" u "O" delante del símbolo
        $ents = @($rows | Where-Object { $_.t -match '(?i)precio de entrada|precio de$' } | Sort-Object y)      # una posición real tiene su fila "Precio de entrada" debajo de la cabecera
        $ys = @(); foreach ($h in $heads) { if (-not $ys.Count -or ($h.y - $ys[-1]) -gt 120) { $ys += [int]$h.y } }
        $ys2 = @(); for ($i = 0; $i -lt $ys.Count; $i++) { $nxt = if ($i + 1 -lt $ys.Count) { $ys[$i + 1] } else { [int]::MaxValue }; if (@($ents | Where-Object { $_.y -gt $ys[$i] -and $_.y -lt $nxt }).Count) { $ys2 += $ys[$i] } }
        $ys = $ys2
        if ($ys.Count -lt 2) { return @() }
        $outs = @(); for ($i = 0; $i -lt $ys.Count; $i++) {
            $top = [Math]::Max(0, $ys[$i] - 28); $bot = if ($i + 1 -lt $ys.Count) { [Math]::Max($top + 40, $ys[$i + 1] - 10) } else { $img.Height }; if ($bot -gt $img.Height) { $bot = $img.Height }
            $rect = New-Object System.Drawing.Rectangle 0, $top, $img.Width, ($bot - $top); $bmp = New-Object System.Drawing.Bitmap $rect.Width, $rect.Height
            $g = [System.Drawing.Graphics]::FromImage($bmp); $g.DrawImage($img, (New-Object System.Drawing.Rectangle 0, 0, $rect.Width, $rect.Height), $rect, [System.Drawing.GraphicsUnit]::Pixel); $g.Dispose()
            $o = Join-Path ([IO.Path]::GetTempPath()) ("blk-" + [guid]::NewGuid().ToString('N') + ".png"); $bmp.Save($o, [System.Drawing.Imaging.ImageFormat]::Png); $bmp.Dispose(); $outs += $o }
        return $outs
    } catch { return @() } finally { $img.Dispose() }
}
function Read-ClosedPosition([string]$path) {      # captura del historial de una posición CERRADA: símbolo, lado, entrada, cierre, PYG y horas; $null si no es ese tipo de captura
    $rows = Get-ImageOcrRows $path 3 $true; if (-not $rows) { return $null }
    $all = ($rows | ForEach-Object { $_.t }) -join "`n"
    if ($all -notmatch '(?i)precio de cierre|hora de cierre|cantidad\s+cerrada') { return $null }
    $c = @{ notes = @() }
    $tick = @((Invoke-RestMethod "$($script:CmdBase)/tickers" -TimeoutSec 20).data); $bases = @($tick | ForEach-Object { $_.symbol -replace 'USDT$', '' })
    $sr = @($rows | Where-Object { $_.y -lt 110 -and $_.t -match '(?i)([A-Z0-9]{2,12})\s*USDT' } | Select-Object -First 1)[0]
    if ($sr -and $sr.t -match '(?i)([A-Z0-9]{2,12})\s*USDT') { $rs = Resolve-OcrSymbol $Matches[1] $bases; if ($rs.ok) { $c.sym = $rs.sym } }
    $sideRow = @($rows | Where-Object { $_.y -lt 110 -and $_.t -match '(?i)\b(largo|corto|long|short)\b' } | Select-Object -First 1)[0]
    if ($sideRow) { $c.side = $(if ($sideRow.t -match '(?i)largo|long') { 1 } else { -1 }) }
    # en el historial cada etiqueta y su valor salen como filas distintas en la MISMA línea (el valor a la derecha de la etiqueta)
    $valAt = { param($rx) $lab = @($rows | Where-Object { $_.t -match $rx } | Select-Object -First 1)[0]; if (-not $lab) { return $null }; $vx = @($rows | Where-Object { [Math]::Abs($_.y - $lab.y) -le 12 -and $_.x -gt $lab.x + 20 } | Sort-Object x | Select-Object -First 1)[0]; if ($vx) { return $vx.t } else { return $null } }
    $vE = & $valAt '(?i)^\s*precio de(\s+entrada)?\s*$'; if ($vE -match '([0-9][0-9.,]*)') { $c.entry = Convert-OcrNumber $Matches[1] }
    $vX = & $valAt '(?i)precio de cierre\s*$'; if ($vX -match '([0-9][0-9.,]*)') { $c.exit = Convert-OcrNumber $Matches[1] }
    $vP = & $valAt '(?i)^\s*posici.n de(\s*PYG)?\s*$'; if ($vP -match '([+-]\s*\d+\.\d{2,})') { $c.pnl = [double](($Matches[1] -replace '\s', '')) }
    $vC = & $valAt '(?i)^\s*(pyg\s*[%o0]|pyg)\s*\S{0,4}\s*$'; if ($vC -match '([+-]\s*\d+\.\d{2})') { $c.pct = [double](($Matches[1] -replace '\s', '')) }
    $vQ = & $valAt '(?i)cantidad\s+cerrada'; if ($vQ -match '([\d,]+(?:\.\d+)?)') { $c.qty = Convert-OcrNumber $Matches[1] $false }
    foreach ($r in $rows) { $t = $r.t
        if (-not $c.exit -and $t -match '(?i)precio de cierre\s*([0-9][0-9.,]*)') { $c.exit = Convert-OcrNumber $Matches[1] }
        elseif (-not $c.entry -and $t -match '(?i)precio de\s+(?!cierre)(?:entrada\s*)?([0-9][0-9.,]*)') { $c.entry = Convert-OcrNumber $Matches[1] }
        if (-not $c.pnl -and $t -match '([+-]\s*\d+\.\d{3,})\s*USDT') { $c.pnl = [double](($Matches[1] -replace '\s', '')) }
        if (-not $c.pct -and $t -match '([+-]\s*\d+\.\d+)\s*%') { $c.pct = [double](($Matches[1] -replace '\s', '')) }
        if (-not $c.qty -and $t -match '(?i)(?:m.ximo retenido|cantidad cerrada)\s*([\d,]+(?:\.\d+)?)') { $c.qty = Convert-OcrNumber $Matches[1] $false } }
    $dt = @([regex]::Matches($all, '\d{4}-\d{2}-\d{2}\s+\d{2}:\d{2}:\d{2}') | ForEach-Object { $_.Value }); if ($dt.Count -ge 2) { $c.open = $dt[0]; $c.close = $dt[1] }
    if ($c.entry -and $c.exit -and -not $c.side -and $c.pnl) { $c.side = $(if ((($c.exit - $c.entry) * $c.pnl) -ge 0) { 1 } else { -1 }); $c.notes += "lado deducido del signo del resultado" }
    $c.lev = $null; $lm = [regex]::Match($all, '(?<![\d.,])(\d{1,3})\s*[xX](?![A-Za-z0-9])'); if ($lm.Success) { $c.lev = [double]$lm.Groups[1].Value }
    return $c
}
function Format-ClosedPosition($c, [string]$who) {
    if (-not ($c.sym -and $c.entry -and $c.exit)) { return ("📕 Esto parece una posición CERRADA (historial) pero no he podido leer con seguridad: {0}.`nHe leído: {1}.`nDime el cierre con /cerrar PAR PRECIO (ej.: /cerrar OGN 0,03738) y la anoto." -f ((@('sym', 'entry', 'exit') | Where-Object { -not $c.$_ }) -join ', '), ((@('sym', 'side', 'entry', 'exit', 'pnl', 'pct', 'qty') | Where-Object { $c.$_ } | ForEach-Object { "$_=$($c.$_)" }) -join ' · ')) }
    $sg = if ($c.side) { [int]$c.side } else { if ($c.pnl -and $c.pnl -lt 0) { -1 * [Math]::Sign($c.exit - $c.entry) } else { [Math]::Sign($c.exit - $c.entry) } }
    $L = @(); $L += ("📕 POSICIÓN CERRADA leída · {0} {1}{2}" -f $c.sym, $(if ($sg -eq 1) { "LARGO" } else { "CORTO" }), $(if ($c.lev) { " x" + $c.lev } else { "" }))
    $L += ("   Entrada {0} → cierre {1} ({2:+0.00;-0.00}% del precio){3}" -f (TaFp $c.entry), (TaFp $c.exit), ($sg * ($c.exit / $c.entry - 1) * 100), $(if ($c.qty) { " · " + ("{0:N0}" -f $c.qty) + " uds" } else { "" }))
    if ($null -ne $c.pnl) { $L += ("   Resultado: {0:+0.00;-0.00} USDT{1}" -f $c.pnl, $(if ($null -ne $c.pct) { " ({0:+0.00;-0.00}% del margen)" -f $c.pct } else { "" })) }
    if ($c.open -and $c.close) { $L += ("   Abierta {0} · cerrada {1} (hora de la plataforma)" -f $c.open, $c.close) }
    $closed = @()
    try { $r1 = Close-ManualTrade $c.sym $c.exit; if ($r1) { $closed += "operación manual" } } catch {}
    try { $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds(); $all2 = @(Read-Signals); $dirty = $false
        foreach ($r in $all2) { if ($r.strat -eq 'tomada' -and $r.status -eq 'open' -and $r.sym -eq "$($c.sym)USDT" -and $r.dest -eq 'priv') { $mm = $r.side * ($c.exit - [double]$r.entry) / [double]$r.riskAbs; $rr = [double]$r.realized + $mm * $(switch ([int]$r.stage) { 0 { 1.0 } 1 { 2.0 / 3 } default { 1.0 / 3 } }); Close-TomadaRecord $r $c.exit 'cierre manual (captura del historial)' $rr; $dirty = $true; $closed += "seguimiento en vivo" } }
        if ($dirty) { Save-Signals $all2 } } catch {}
    if ($closed.Count) { $L += ("✅ Dejo de vigilarla: cerrado el " + (($closed | Select-Object -Unique) -join " y el ") + ".") } else { $L += "ℹ️ No tenía esta operación abierta en el seguimiento; solo la anoto como lectura." }
    foreach ($n in @($c.notes)) { if ($n) { $L += "   ($n)" } }
    return ($L -join "`n")
}
function Handle-Screenshot($token, $m, $chat) {
    $fid = $null
    if ($m.photo) { $fid = @($m.photo | Sort-Object { [int]$_.file_size } -Descending)[0].file_id } elseif ($m.document) { $fid = $m.document.file_id }
    if (-not $fid) { return "No he podido obtener la imagen." }
    $tmp = Join-Path ([IO.Path]::GetTempPath()) ("cap-" + [guid]::NewGuid().ToString('N') + ".img")
    try { $gf = Invoke-RestMethod "https://api.telegram.org/bot$token/getFile?file_id=$fid" -TimeoutSec 25; Invoke-WebRequest "https://api.telegram.org/file/bot$token/$($gf.result.file_path)" -OutFile $tmp -TimeoutSec 40 -UseBasicParsing } catch { return "No he podido descargar la imagen: $($_.Exception.Message)" }
    try {
        $cap = "$($m.caption)".Trim(); $capSym = $null; if ($cap -match '^[A-Za-z0-9]{2,12}$') { $capSym = $cap }
        # 1) captura del HISTORIAL de una posición ya cerrada: se lee el resultado y se cierra el seguimiento
        $clp = $null; try { $clp = Read-ClosedPosition $tmp } catch {}
        if ($clp) { return (Format-ClosedPosition $clp "$($m.from.first_name)") }
        # 2) varias posiciones abiertas en la misma imagen: se corta por bloques y se analiza cada una (máx. 3)
        $blocks = @(); try { $blocks = @(Split-PositionBlocks $tmp) } catch {}
        if ($blocks.Count -ge 2) { $outs = @(); $bi = 0; foreach ($bp in ($blocks | Select-Object -First 3)) { $bi++; try { $outs += ("📌 POSICIÓN {0} DE {1}`n{2}" -f $bi, [Math]::Min(3, $blocks.Count), (Get-OnePositionReport $bp $capSym $m)) } catch { $outs += ("📌 POSICIÓN {0}: no he podido leerla ({1})" -f $bi, $_.Exception.Message) } finally { try { Remove-Item $bp -Force -ErrorAction SilentlyContinue } catch {} } }; return ($outs -join "`n`n──────────`n`n") }
        return (Get-OnePositionReport $tmp $capSym $m)
    } finally { try { Remove-Item $tmp -Force -ErrorAction SilentlyContinue } catch {} }
}
function Get-OnePositionReport([string]$tmp, $capSym, $m) {
        $p = Read-PositionScreenshot $tmp $capSym
        if ($p.error) { return "⚠️ $($p.error) Mándame los datos con /operacion PAR LARGO|CORTO ENTRADA SL TP MARGEN APALANCAMIENTO." }
        $miss = @(); foreach ($k in 'sym', 'entry', 'side') { if (-not $p.$k) { $miss += $k } }
        if ($miss.Count) {
            $got = @(); foreach ($k in 'sym', 'entry', 'mark', 'margin', 'liq', 'sl', 'tp', 'lev') { if ($p.$k) { $got += "$k=$($p.$k)" } }
            $fv = { param($x, $ph) if ($x) { ("$x" -replace '\.', ',') } else { $ph } }
            $tpl = "/operacion {0} {1} {2} {3} {4} {5} {6}" -f (& $fv $p.sym 'PAR'), $(if ($p.side -eq 1) { 'LARGO' } elseif ($p.side -eq -1) { 'CORTO' } else { 'LARGO|CORTO' }), (& $fv $p.entry 'ENTRADA'), (& $fv $p.sl 'SL'), (& $fv $p.tp 'TP'), (& $fv $p.margin 'MARGEN'), (& $fv $p.lev 'APALANCAMIENTO')
            return ("⚠️ No he podido leer con seguridad: {0}.`nHe leído: {1}.`n{2}`nCopia, completa lo que falte (o corrige) y envíame esto:`n$tpl`n`nPara que la lea bien: recorta SOLO la tabla de 'Posiciones' (que ocupe toda la imagen) y envíala como ARCHIVO (clip → Archivo, sin comprimir); las fotos normales pierden calidad en Telegram. También puedes añadir el símbolo en el pie (ej. API3) o registrarla con /operacion PAR LARGO|CORTO ENTRADA SL TP MARGEN APALANCAMIENTO." -f ($miss -join ', '), $(if ($got.Count) { $got -join ' · ' } else { "nada fiable" }), (($p.notes | ForEach-Object { "· $_" }) -join "`n"))
        }
        $txt = Format-CapturaAnalysis $p $true "$($m.from.first_name)"
        $warn = @($p.notes | Where-Object { $_ }); if ($warn.Count) { $txt += "`n`nℹ️ Notas de lectura: " + ($warn -join "; ") + ". Si algún dato no coincide con tu pantalla, dímelo." }
        try { if ($p.sym -and $p.lev -and $p.margin -and $p.sl) { $rk = Get-RiskCheck $p.sym ([int]$p.side) ([double]$p.entry) ([double]$p.sl) $(if ($p.tp) { [double]$p.tp } else { [double]$p.entry }) ([double]$p.margin) ([double]$p.lev); $txt += "`n`n" + $rk } } catch {}
        return $txt
}
