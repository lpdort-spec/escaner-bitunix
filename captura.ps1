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
        if ($merged.sym -and $merged.entry -and $merged.side -and $merged.margin -and ($merged.levels -or $merged.sl)) { break }
    }
    if ($merged -and -not $merged.error -and $merged.entry -and $merged.side -and $merged.levels -and -not ($merged.sl -or $merged.tp)) { foreach ($n in $merged.levels) { if ($merged.side * ($n - $merged.entry) -gt 0) { $merged.tp = $n } else { $merged.sl = $n } } }
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
    # símbolo
    $symRow = @($rows | Where-Object { $_.y -lt 110 -and $_.t -match '(?i)[A-Z0-9]{2,12}\s*USDT' } | Select-Object -First 1)[0]
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
    # SL / TP (fila bajo "Posición TP/SL": uno o dos precios; se quitan los importes entre paréntesis)
    if ($hTp) {
        $txt = (@($rows | Where-Object { $_.y -gt $hTp.y + 10 -and $_.y -lt $hTp.y + 80 -and $_.x -ge $hTp.x - 60 } | Sort-Object y, x | ForEach-Object { $_.t }) -join ' ')
        $txt = $txt -replace '\(?\s*[\$S]\s*[\d,\.]+\s*\)?', ' ' -replace '\([^)]*\)', ' '
        $nums = @([regex]::Matches($txt, '\d+[\.,]\d{2,}') | ForEach-Object { Convert-OcrNumber $_.Value $false } | Where-Object { $_ -and ((-not $live) -or (& $near $_)) })
        $p.levels = $nums
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
    if ($p.notional -and $p.margin -and $p.margin -gt 0) { $lv = $p.notional / $p.margin; if ([Math]::Abs($lv - [Math]::Round($lv)) -lt 0.2 -and $lv -ge 1 -and $lv -le 150) { $p.lev = [Math]::Round($lv) } }
    if ($p.levels -and $p.entry -and $p.side) {
        foreach ($n in $p.levels) { if ($p.side * ($n - $p.entry) -gt 0) { $p.tp = $n } else { $p.sl = $n } }
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
    try { $k = @((Invoke-RestMethod "$($script:CmdBase)/kline?symbol=${sym}USDT&interval=1h&limit=60" -TimeoutSec 20).data | Sort-Object { [long]$_.time }); $k = @($k[0..($k.Count - 2)] | Select-Object -Last 48)
        $recent = if ($sg -eq 1) { ($k | ForEach-Object { [double]$_.high } | Measure-Object -Maximum).Maximum } else { ($k | ForEach-Object { [double]$_.low } | Measure-Object -Minimum).Minimum } } catch {}
    # veredicto con reglas fijas
    $L += ""; $verdict = "MANTENER"; $why = @()
    if (-not $sl) { $verdict = "PROTEGER YA"; $why += "no tiene stop: una posición sin SL puede liquidarse. Pon uno ahora (sugerido {0})" -f (TaFp ($en - $sg * [Math]::Max(1.2 * $atr, 0.02 * $en))) }
    else {
        $R = [Math]::Abs($en - $sl); $slPct = $R / $en * 100; $costMg = if ($lev) { $slPct * $lev } else { $null }; $dSl = $sg * ($px - $sl)
        if ($costMg) { $L += ("🛡️ Si salta el SL pierdes ≈ {0:N0} USDT ({1:N0}% del margen){2}" -f ($mg * $costMg / 100), $costMg, $(if ($costMg -gt 35) { " ⚠️ por encima de tu límite del 35%" } else { " ✔ dentro de tu regla del 35%" })) }
        if ($p.liq) { $dl = [Math]::Abs($px - $p.liq) / $px * 100; $L += ("   Liquidación a {0:N1}% del precio y SL a {2:N1}%: {1}" -f $dl, $(if ([Math]::Abs($sl - $px) / $px * 100 -lt $dl * 0.8) { "queda más lejos ✔" } else { "⚠️ demasiado cerca" }), ([Math]::Abs($sl - $px) / $px * 100)) }
        if ($atr -gt 0 -and $dSl -lt 0.8 * $atr) { $L += ("⚠️ El SL queda a solo {0:N1} ATR del precio: es fácil que el ruido normal lo toque." -f ($dSl / $atr)) }
        if ($sg * ($px - $en) / $R -ge 1.0) { $verdict = "PROTEGER"; $why += "ya vas a +{0:N1}R: cierra un tercio y mueve el SL a tu entrada ({1})" -f ($sg * ($px - $en) / $R), (TaFp $en) }
    }
    if ($null -ne $own -and $own -le 0 -and $opp -ge 6) { $verdict = "CERRAR"; $why += "la lectura del activo se ha dado la vuelta en contra" }
    elseif ($null -ne $own -and $own -lt 4 -and $verdict -eq "MANTENER") { $verdict = "VIGILAR"; $why += "la puntuación es floja ($own); si pierde más, valora cerrar" }
    if ($mg -and $mg -gt 200) { $L += ("⚠️ El margen ({0:N0} USDT) supera tu límite de 200 USDT." -f $mg) }
    $icon = switch ($verdict) { 'CERRAR' { "⛔" } 'PROTEGER YA' { "🚨" } 'PROTEGER' { "🔔" } 'VIGILAR' { "⚠️" } default { "✅" } }
    $L += ("{0} VEREDICTO: {1}{2}" -f $icon, $verdict, $(if ($why.Count) { " · " + ($why -join "; ") } else { " · la operación sigue vigente con el plan que tienes" }))
    # propuesta de objetivos
    $tgt = $null
    if ($sl) { $R = [Math]::Abs($en - $sl); $t1 = $en + $sg * $R; $t2 = $en + $sg * 2 * $R; $t3 = $en + $sg * 3 * $R
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
        $p = Read-PositionScreenshot $tmp $capSym
        if ($p.error) { return "⚠️ $($p.error) Mándame los datos con /operacion PAR LARGO|CORTO ENTRADA SL TP MARGEN APALANCAMIENTO." }
        $miss = @(); foreach ($k in 'sym', 'entry', 'side') { if (-not $p.$k) { $miss += $k } }
        if ($miss.Count) {
            $got = @(); foreach ($k in 'sym', 'entry', 'mark', 'margin', 'liq', 'sl', 'tp', 'lev') { if ($p.$k) { $got += "$k=$($p.$k)" } }
            return ("⚠️ No he podido leer con seguridad: {0}.`nHe leído: {1}.`n{2}`nPara que la lea bien: recorta SOLO la tabla de 'Posiciones' (que ocupe toda la imagen) y envíala como ARCHIVO (clip → Archivo, sin comprimir); las fotos normales pierden calidad en Telegram. También puedes añadir el símbolo en el pie (ej. API3) o registrarla con /operacion PAR LARGO|CORTO ENTRADA SL TP MARGEN APALANCAMIENTO." -f ($miss -join ', '), $(if ($got.Count) { $got -join ' · ' } else { "nada fiable" }), (($p.notes | ForEach-Object { "· $_" }) -join "`n"))
        }
        $txt = Format-CapturaAnalysis $p $true "$($m.from.first_name)"
        $warn = @($p.notes | Where-Object { $_ }); if ($warn.Count) { $txt += "`n`nℹ️ Notas de lectura: " + ($warn -join "; ") + ". Si algún dato no coincide con tu pantalla, dímelo." }
        try { if ($p.sym -and $p.lev -and $p.margin -and $p.sl) { $rk = Get-RiskCheck $p.sym ([int]$p.side) ([double]$p.entry) ([double]$p.sl) $(if ($p.tp) { [double]$p.tp } else { [double]$p.entry }) ([double]$p.margin) ([double]$p.lev); $txt += "`n`n" + $rk } } catch {}
        return $txt
    } finally { try { Remove-Item $tmp -Force -ErrorAction SilentlyContinue } catch {} }
}
