# COLOCACIÓN DEL SL FRENTE A SOPORTES/RESISTENCIAS (cripto de Bitunix). Origen: FET 06/10/2026: el SL quedó justo encima de un grupo de soportes (EMA200 1h, EMA50 4h, EMA10 diaria, soporte 4h) donde el precio suele rebotar y barrer el stop.
# Niveles: EMAs de 1h (50/100/200), 4h (20/50/100/200) y 1d (10/20/50/100/200) + soportes/resistencias de Analyze-TF. Regla: si hay niveles en la zona [SL - 0,5 ATR4h, SL + 0,1 ATR4h] (largos; espejo en cortos), el SL se baja por debajo
# del más lejano con un margen de 0,15 ATR4h; el apalancamiento se recalcula solo con la nueva distancia (presupuesto de pérdida <= 20% del margen). Si el nuevo SL queda a más de 3 ATR4h, o el recorrido hasta el obstáculo cae por debajo de 1,5R, no se emite.
function Get-EmaValue($closes, [int]$n) { if ($closes.Count -lt 5) { return $null }; $k = 2.0 / ($n + 1); $e = [double]$closes[0]; foreach ($x in $closes) { $e = [double]$x * $k + $e * (1 - $k) }; return $e }
function Get-StructLevels($sym, [double]$px = 0) {
    $out = @(); $base = "$($script:CmdBase)"; $s0 = if ("$sym" -like '*USDT') { $sym } else { "${sym}USDT" }
    foreach ($cfg in @(@('1h', @(50, 100, 200)), @('4h', @(20, 50, 100, 200)), @('1d', @(10, 20, 50, 100, 200)))) {
        try { $k = @((Invoke-RestMethod "$base/kline?symbol=$s0&interval=$($cfg[0])&limit=200" -TimeoutSec 20).data | Sort-Object { [long]$_.time }); if ($k.Count -lt 30) { continue }
            $cl = @($k[0..($k.Count - 2)] | ForEach-Object { [double]$_.close }); if ($px -gt 0) { $cl += $px }      # la EMA incluye el precio actual, como en el gráfico
            foreach ($n in $cfg[1]) { if ($cl.Count -ge [Math]::Min($n, 40)) { $v = Get-EmaValue $cl $n; if ($v) { $out += [pscustomobject]@{ p = $v; tag = ("EMA{0} {1}" -f $n, $cfg[0]) } } } } } catch {}
    }
    return $out
}
function Get-SweepFlag($sym, [int]$sg) {      # barrido de liquidez en 4h: en las 3 últimas velas CERRADAS el precio perfora el mínimo (largo) o máximo (corto) de las 20 previas y cierra de nuevo dentro. Estudio bt-ema-obstaculo: largos tras barrido de mínimos 58% TP1 +0,19R (referencia +0,06R); cortos sin ventaja.
    try { $s0 = if ("$sym" -like '*USDT') { $sym } else { "${sym}USDT" }
        $k = @((Invoke-RestMethod "$($script:CmdBase)/kline?symbol=$s0&interval=4h&limit=40" -TimeoutSec 20).data | Sort-Object { [long]$_.time }); if ($k.Count -lt 30) { return $false }
        $cl = @($k[0..($k.Count - 2)]); $n = $cl.Count; $prev = @($cl[($n - 23)..($n - 4)]); $last3 = @($cl[($n - 3)..($n - 1)])
        if ($sg -eq 1) { $ref = ($prev | ForEach-Object { [double]$_.low } | Measure-Object -Minimum).Minimum; return [bool](@($last3 | Where-Object { [double]$_.low -lt $ref -and [double]$_.close -gt $ref }).Count) }
        $ref = ($prev | ForEach-Object { [double]$_.high } | Measure-Object -Maximum).Maximum; return [bool](@($last3 | Where-Object { [double]$_.high -gt $ref -and [double]$_.close -lt $ref }).Count)
    } catch { return $false }
}
function Get-EmaSweepFlags([int]$sg, $sym, [double]$entry, [double]$risk, [double]$px = 0) {      # texto para ctxFlags de las señales reales: ¿había una EMA entre la entrada y +1R? ¿hubo barrido? Sirve para medir con datos propios qué pesa de verdad
    $eo = 0; try { if ($risk -gt 0) { $lv = @(Get-StructLevels $sym $px | Where-Object { $_.tag -like 'EMA*' }); if (@($lv | Where-Object { $sg * ($_.p - $entry) -gt 0 -and $sg * ($_.p - $entry) -le $risk }).Count) { $eo = 1 } } } catch {}
    $sw = 0; try { if (Get-SweepFlag $sym $sg) { $sw = 1 } } catch {}
    return ("emaObs={0};sweep={1}" -f $eo, $sw)
}
function Find-SlCluster([int]$sg, [double]$entry, [double]$sl, [double]$atr, $levels) {
    $lo = $sl - 0.5 * $atr; $hi = $sl + 0.1 * $atr
    if ($sg -eq 1) { return @($levels | Where-Object { $_.p -ge $lo -and $_.p -le $hi -and $_.p -lt $entry } | Sort-Object p) }
    $lo2 = $sl - 0.1 * $atr; $hi2 = $sl + 0.5 * $atr
    return @($levels | Where-Object { $_.p -ge $lo2 -and $_.p -le $hi2 -and $_.p -gt $entry } | Sort-Object p)
}
function Format-ClusterTags($cl) { return (($cl | Select-Object -First 4 | ForEach-Object { "{0} {1}" -f $_.tag, (TaFp ([double]$_.p)) }) -join ' · ') }
function Apply-SlStructure($plan, [string]$side, $sym, [double]$px, $extraLevels = @()) {      # modifica el plan (SL, R, objetivos) y devuelve @{ skip; moved; note }
    if (-not $plan) { return @{ skip = $false; moved = $false; delta = 0; note = $null; ctx = $null } }
    $sg = if ($side -eq 'L') { 1 } else { -1 }; $en = [double]$plan.entry; $sl = [double]$plan.sl; $atr = [double]$plan.atr4h
    if ($atr -le 0) { $atr = [Math]::Abs($en - $sl) / 1.5 }
    $lv = @(Get-StructLevels $sym $px) + @($extraLevels); $cl = @(Find-SlCluster $sg $en $sl $atr $lv)
    # 1) contexto de EMAs clave: cuántas quedan a favor del trade (largo: precio por encima; corto: por debajo)
    $key = @($lv | Where-Object { $_.tag -in 'EMA200 1h', 'EMA50 4h', 'EMA200 4h', 'EMA50 1d', 'EMA200 1d' }); $fav = @($key | Where-Object { $sg * ($px - $_.p) -gt 0 }).Count; $delta = 0; $ctx = $null
    if ($key.Count -ge 3) { if ($fav -ge $key.Count - 0 -and $key.Count -ge 4) { $delta = 1; $ctx = ("✅ EMAs clave (1h/4h/diaria): {0} de {1} a favor del {2}" -f $fav, $key.Count, $(if ($sg -eq 1) { "largo (precio por encima)" } else { "corto (precio por debajo)" })) } elseif ($fav -le 1) { $delta = -2; $ctx = ("⚠️ EMAs clave (1h/4h/diaria): solo {0} de {1} a favor del {2}: la tendencia en varios marcos va en contra" -f $fav, $key.Count, $(if ($sg -eq 1) { "largo" } else { "corto" })) } elseif ($fav -le $key.Count / 2 - 0.5) { $delta = -1; $ctx = ("⚠️ EMAs clave (1h/4h/diaria): {0} de {1} a favor del {2}" -f $fav, $key.Count, $(if ($sg -eq 1) { "largo" } else { "corto" })) } }
    # 1b) barrido de liquidez a favor (solo largos: tras barrer mínimos de 20 velas de 4h el estudio da 58% TP1 y +0,19R frente a +0,06R de referencia): +1 punto
    $sweep = 0; if ($sg -eq 1) { try { if (Get-SweepFlag $sym 1) { $sweep = 1; $delta += 1; $ctx = (@($ctx, "✅ Barrido de liquidez: el precio perforó mínimos recientes de 4h y recuperó (en largos suele anticipar rebote)") | Where-Object { $_ }) -join "`n" } } catch {} }
    $plan.sweep = $sweep
    # 2) el SL no debe quedar justo sobre (largo) / bajo (corto) un grupo de EMAs o soportes
    $moved = $false; $note = $null
    if ($cl.Count) {
        $ext = if ($sg -eq 1) { $cl[0].p } else { $cl[$cl.Count - 1].p }; $new = $ext - $sg * 0.15 * $atr
        if ($sg * ($en - $new) -gt 3.0 * $atr) { return @{ skip = $true; moved = $false; delta = $delta; note = "SL bajo soportes a más de 3 ATR: sin recorrido razonable"; ctx = $ctx } }
        $R = $sg * ($en - $new)
        if ($R -gt 0) { $plan.sl = $new; $plan.R = $R; $plan.tp1 = $en + $sg * $R; $plan.tp2 = $en + $sg * 2 * $R; $plan.tp3 = $en + $sg * 3 * $R; $moved = $true
            $note = ("SL colocado bajo soportes ({0}) para que un rebote ahí no lo barra" -f (Format-ClusterTags $cl)); $plan.slNote = $note }
    }
    # 3) las EMAs también frenan el recorrido: el primer nivel entre la entrada y el TP final pasa a ser el obstáculo
    $R = [Math]::Abs($en - [double]$plan.sl); $beyond = @($lv | Where-Object { $sg * ($_.p - $en) -gt 0.3 * $atr } | Sort-Object { $sg * $_.p })
    if ($beyond.Count) { $first = $beyond[0]; if (-not $plan.ob -or $sg * ([double]$plan.ob - $first.p) -gt 0) { $plan.ob = $first.p; $plan.obTag = $first.tag } }
    $plan.emaObs = [int](@($lv | Where-Object { $_.tag -like 'EMA*' -and $sg * ($_.p - $en) -gt 0 -and $sg * ($_.p - $en) -le $R }).Count -gt 0)      # para medir con señales reales
    # Estudio bt-ema-obstaculo (150 monedas, 4h): con una EMA entre la entrada y +1R los largos dan 56% TP1 y +0,17R (sin EMA: 50% y -0,01R) y los cortos no cambian: una EMA NO justifica vetar. Solo se veta por soportes/resistencias; la EMA sigue limitando el TP final.
    if ($plan.ob -and $R -gt 0) { $plan.room = [Math]::Abs([double]$plan.ob - $en) / $R; if ($plan.room -lt 1.5 -and "$($plan.obTag)" -notlike 'EMA*') { return @{ skip = $true; moved = $moved; delta = $delta; note = ("el primer obstáculo ({0}) queda a solo {1:N1}R de la entrada" -f $(if ($plan.obTag) { $plan.obTag + " " + (TaFp ([double]$plan.ob)) } else { TaFp ([double]$plan.ob) }), $plan.room); ctx = $ctx } } }
    return @{ skip = $false; moved = $moved; delta = $delta; note = $note; ctx = $ctx }
}
function Get-SlClusterNote([int]$sg, $sym, [double]$entry, [double]$sl, [double]$atr, [double]$px) {      # solo advertencia (rupturas validadas: no se toca su SL)
    try { $cl = @(Find-SlCluster $sg $entry $sl $atr @(Get-StructLevels $sym $px)); if ($cl.Count) { return ("⚠️ El SL queda justo sobre soportes ({0}): el precio suele rebotar ahí y barrer el stop. Valora un SL más abajo con menos apalancamiento." -f (Format-ClusterTags $cl)) } } catch {}
    return $null
}
