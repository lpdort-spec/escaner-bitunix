# /señal tomada [SIMBOLO] PRECIO [xAPALANCAMIENTO]  ·  /señal cerrada SIMBOLO [PRECIO]   (SOLO chat privado de Luis)
# Cuando el bot te envía una señal y la tomas, se lo dices con este comando: el bot valora tu entrada con los datos de ese momento (precio, SL y TP de la señal, relación R:B desde TU entrada,
# lectura del mercado, control de riesgo) y a partir de ahí vigila la operación: te avisa si debes cerrar, subir el SL, mover el TP o cerrar parcial. No opera por ti: solo te asesora.
# Con el símbolo se elige la señal; sin símbolo se usa la última señal enviada (hasta 36 h). Ejemplos:  /señal tomada 85200  ·  /señal tomada BTC 85200 x20  ·  /señal cerrada BTC 85800

function ConvertTo-Num($s) {
    $x = ("$s" -replace '\s', '' -replace '[^0-9,\.\-]', ''); if (-not $x) { return $null }
    if ($x -match ',' -and $x -match '\.') { if ($x.LastIndexOf(',') -gt $x.LastIndexOf('.')) { $x = ($x -replace '\.', '') -replace ',', '.' } else { $x = $x -replace ',', '' } } elseif ($x -match ',') { $x = $x -replace ',', '.' }
    $d = 0.0; if ([double]::TryParse($x, [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref]$d)) { return $d } else { return $null }
}
function Get-LastClosedLabel($sym, $tf) {
    try { $k = @((Invoke-RestMethod "$($script:CmdBase)/kline?symbol=${sym}USDT&interval=$tf&limit=3" -TimeoutSec 20).data | Sort-Object { [long]$_.time }); $dur = if ($tf -eq '1h') { 3600000L } else { 14400000L }; return ([long]$k[$k.Count - 1].time + $dur) } catch { return [long]0 }
}
function Handle-SenalTomada($ra) {
    $uso = "Uso: /señal tomada [SIMBOLO] PRECIO [xAPALANCAMIENTO]  (ej.: /señal tomada BTC 85200 x20)`n     /señal cerrada SIMBOLO [PRECIO]`nSin símbolo, se usa la última señal que te envié."
    $words = @($ra | ForEach-Object { "$_" }); if (-not $words.Count) { return $uso }
    $kw = 'orden', 'orde', 'tomada', 'tomado', 'cogida', 'cogido', 'entrada', 'en', 'a', 'precio', 'señal', 'senal', 'cerrada', 'cerrado', 'cierre', 'cerrar'
    $closing = [bool](@($words | Where-Object { $_.ToLower() -in 'cerrada', 'cerrado', 'cierre', 'cerrar' }).Count)
    $sym = $null; $nums = @(); $lev = $null
    foreach ($w in $words) {
        $lw = $w.ToLower()
        if ($lw -in $kw) { continue }
        if ($lw -match '^x(\d+)$') { $lev = [double]$Matches[1]; continue }
        $n = ConvertTo-Num $w
        if ($null -ne $n -and $w -match '^[\d\.,]+$') { $nums += $n; continue }
        if ($w -match '^[A-Za-z0-9]{2,12}$') { $sym = ($w.ToUpper() -replace 'USDT$', '') }
    }
    $all = @(Read-Signals)
    if ($closing) {
        $open = @($all | Where-Object { $_.id -like 'tomada-*' -and $_.status -eq 'open' -and ((-not $sym) -or $_.sym -eq "${sym}USDT") } | Sort-Object { [long]$_.time } -Descending)
        if (-not $open.Count) { return "No tengo ninguna operación tomada abierta" + $(if ($sym) { " de $sym" } else { "" }) + ".`n$uso" }
        $o = $open[0]; $sg = [int]$o.side; $s0 = $o.sym -replace 'USDT$', ''
        $px = if ($nums.Count) { $nums[0] } else { try { [double]((Invoke-RestMethod "$($script:CmdBase)/tickers").data | Where-Object symbol -eq $o.sym).lastPrice } catch { 0 } }
        if ($px -le 0) { return "No he podido leer el precio de $s0; indícalo: /señal cerrada $s0 PRECIO" }
        $R = [double]$o.riskAbs; $rr = $sg * ($px - [double]$o.entry) / $R
        $all2 = Read-Signals; foreach ($r in $all2) { if ($r.id -eq $o.id) { $r.status = 'closed'; $r.exit = $px; $r.outcome = 'cierre manual'; $r.R = [Math]::Round($rr, 2); $r.net = [Math]::Round($rr - 0.0015 / ([double]$o.slPct / 100), 2); $r.closedAt = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds(); $r.closeNote = "$($r.closeNote)XC" } }; Save-Signals $all2
        return ("✅ Cerrada la operación tomada {0} {1}: entrada {2} → salida {3} · {4:+0.00;-0.00}R. Dejo de vigilarla." -f $s0, $(if ($sg -eq 1) { "LARGO" } else { "CORTO" }), (TaFp ([double]$o.entry)), (TaFp $px), $rr)
    }
    if (-not $nums.Count) { return "Dime el precio al que tomaste la orden.`n$uso" }
    $entry = $nums[0]
    $cand = @($all | Where-Object { $_.strat -in 'ruptura', 'aviso-momento' -and ((-not $sym) -or $_.sym -eq "${sym}USDT") -and ([DateTimeOffset]::UtcNow.ToUnixTimeSeconds() - [long]$_.time) -le 129600 -and $_.sym -like '*USDT' } | Sort-Object { [long]$_.time } -Descending)
    if (-not $cand.Count) { return "No encuentro una señal reciente" + $(if ($sym) { " de $sym" } else { "" }) + " (últimas 36 h) en mi registro.`nSi la operación es tuya, regístrala con /operacion PAR LARGO|CORTO ENTRADA SL TP MARGEN APALANCAMIENTO." }
    $sig = $cand[0]; $sg = [int]$sig.side; $s0 = $sig.sym -replace 'USDT$', ''; $dirTxt = if ($sg -eq 1) { "LARGO" } else { "CORTO" }
    $sl = [double]$sig.sl; $t1 = [double]$sig.tp1; $t2 = [double]$sig.tp2; $t3 = [double]$sig.tp3
    if ($sg * ($entry - $sl) -le 0) { return "Con tu entrada ($(TaFp $entry)) el SL de la señal ($(TaFp $sl)) queda al otro lado del precio: revisa el valor o la señal elegida ($s0 $dirTxt)." }
    $R = [Math]::Abs($entry - $sl); $slPct = $R / $entry * 100
    if (-not $lev) { $lev = if ($sig.lev) { [double]$sig.lev } else { 10 } }
    $px = 0; try { $px = [double]((Invoke-RestMethod "$($script:CmdBase)/tickers").data | Where-Object symbol -eq $sig.sym).lastPrice } catch {}
    $L = @(); $L += ("📌 ORDEN TOMADA registrada · {0} {1} · tu entrada {2} (la señal decía {3}{4})" -f $s0, $dirTxt, (TaFp $entry), (TaFp ([double]$sig.entry)), $(if ($sig.entryType -eq 'limit') { ", orden limit" } else { ", a mercado" }))
    $dif = $sg * ([double]$sig.entry - $entry) / [double]$sig.entry * 100
    $L += ("   Entraste {0:N2}% {1} que el precio de la señal." -f [Math]::Abs($dif), $(if ($dif -ge 0) { "mejor" } else { "peor" }))
    $L += ("   Plan: SL {0} (a {1:N2}% de tu entrada) · TP1 {2} · TP2 {3} · TP final {4}" -f (TaFp $sl), $slPct, (TaFp $t1), (TaFp $t2), (TaFp $t3))
    $rb1 = $sg * ($t1 - $entry) / $R; $rb3 = $sg * ($t3 - $entry) / $R
    $L += ("   Desde TU entrada: TP1 = {0:N1}R · TP final = {1:N1}R {2}" -f $rb1, $rb3, $(if ($rb3 -lt 1.5) { "⚠️ relación R:B pobre: valora no entrar o tomar el TP1 como objetivo principal" } else { "✔" }))
    if ($px -gt 0) { $unr = $sg * ($px / $entry - 1) * 100; $L += ("   Ahora: {0} · resultado latente {1:+0.00;-0.00}% del precio (≈ {2:+0.0;-0.0}% del margen con x{3:N0})" -f (TaFp $px), $unr, ($unr * $lev), $lev) }
    $mgEst = if ($sig.margin) { [double]$sig.margin } else { 200 }
    try { $L += ""; $L += (Get-RiskCheck $s0 $sg $entry $sl $t3 $mgEst $lev) } catch {}
    # se registra como posición vigilada (estrategia seg-priv: solo avisos al chat privado)
    $tf = if ($sig.tf -eq '1h') { '1h' } else { '4h' }; $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    $last = Get-LastClosedLabel $s0 $tf
    $dup = @($all | Where-Object { $_.id -like "tomada-$s0-*" -and $_.status -eq 'open' })
    if ($dup.Count) { $L += "`n(Ya tenías una operación tomada abierta de $s0; la nueva se añade al seguimiento. Cierra la anterior con /señal cerrada $s0 si ya no existe.)" }
    Add-SignalRecord ([ordered]@{
        id = "tomada-$s0-$now"; time = $now; sym = $sig.sym; tf = $tf; strat = 'seg-priv'; side = $sg; entryType = 'market'; entry = $entry; sl = $sl; tp1 = $t1; tp2 = $t2; tp3 = $t3
        riskAbs = $R; slPct = $slPct; lev = $lev; status = 'open'; stage = 0; realized = 0.0; age = 0; lastLabel = $last; lab0 = $last; cost = 0.0015; outcome = $null; R = $null; net = $null
        note = "Operación tomada por Luis tras la señal $($sig.id)"
    })
    $L += ""; $L += "👁️ Desde ahora la vigilo: te aviso aquí si debes CERRAR, SUBIR el SL, mover el TP o CERRAR PARCIAL (al tocar TP1/TP2 y ante cambios de mercado, soportes/resistencias nuevos o noticias de riesgo). Cuando la cierres, dímelo con /señal cerrada $s0 PRECIO. No opero por ti: decides tú."
    return ($L -join "`n")
}
