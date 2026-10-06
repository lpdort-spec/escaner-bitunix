# Ampliación del seguimiento: operaciones manuales del usuario, hora de España, informe diario y estado de los envíos programados.
# Regla: solo cifras calculadas con datos reales; lo que no se puede calcular, se dice.

function Get-MadridNow {
    foreach ($id in 'Romance Standard Time', 'Europe/Madrid') { try { return [TimeZoneInfo]::ConvertTimeBySystemTimeZoneId([DateTime]::UtcNow, $id) } catch {} }
    return [DateTime]::UtcNow.AddHours(2)
}

# ---------- Estado de los envíos programados (en last-report.txt, que el flujo de trabajo ya guarda en el repositorio) ----------
function Get-ReportState($key) {
    $f = Join-Path $PSScriptRoot "last-report.txt"; if (-not (Test-Path $f)) { return $null }
    foreach ($l in (Get-Content $f -Encoding UTF8)) { if ($l -match ('^' + [regex]::Escape($key) + '=(.*)$')) { return $Matches[1].Trim() } }
    return $null
}
function Set-ReportState($key, $value) {
    $f = Join-Path $PSScriptRoot "last-report.txt"; $lines = @()
    if (Test-Path $f) { $lines = @(Get-Content $f -Encoding UTF8 | Where-Object { $_ -match '^(daily|weekly|mercado|mercadook|iren|irensnap|vigia|vigiahoy|momact|momc|momm|salud|saludw|macrord|noticiasw|noticiasu|ajustes)=' -and $_ -notmatch ('^' + [regex]::Escape($key) + '=') }) }
    $lines += "$key=$value"
    Set-Content $f $lines -Encoding UTF8
}

# ---------- Operaciones manuales ----------
function New-ManualRecord($sym, [int]$sg, [double]$en, [double]$sl, [double]$tp, [double]$mg, [double]$lv, $qtyOverride = $null, $id = $null, $sl0 = $null) {
    $qty = if ($qtyOverride) { [double]$qtyOverride } else { $mg * $lv / $en }
    $slRef = if ($sl0) { [double]$sl0 } else { $sl }                                  # SL inicial (si el SL actual ya se movió a beneficio)
    $loss = $sg * ($slRef - $en) -lt 0
    $riskAbs = if ($loss) { [Math]::Abs($en - $slRef) } else { 0.35 * $mg / $qty }     # sin SL inicial en pérdida: R de referencia = 35% del margen (regla del usuario)
    $lastLabel = [long]0
    try { $k = @((Invoke-RestMethod "$($script:TrkBase)/kline?symbol=${sym}USDT&interval=1h&limit=5" -TimeoutSec 20).data | Sort-Object { [long]$_.time }); $lastLabel = [long]$k[$k.Count - 2].time } catch {}
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    return [ordered]@{
        id = $(if ($id) { $id } else { "manual-$sym-$now" }); time = $now; sym = "${sym}USDT"; tf = "1h"; strat = "manual"; side = $sg
        entryType = "market"; entry = $en; sl = $sl; sl0 = $slRef; tp1 = $tp; tp2 = $tp; tp3 = $tp; riskAbs = $riskAbs; slPct = ($riskAbs / $en * 100)
        lev = $lv; margin = $mg; qty = $qty; ratio = $null; trend = $null; aligned = $null; btcAligned = $null; squeeze = $null; pool = ""; funding = $null; book = $null
        risk = "MANUAL"; roiTp2 = $null; status = "open"; stage = 0; realized = 0.0; age = 0; lastLabel = $lastLabel; lab0 = $lastLabel
        outcome = $null; R = $null; net = $null; manual = $true; mode = "single"; exit = $null; pnlUsd = $null; note = $null; closedAt = $null; sentiment = $null; closeNote = $null
    }
}
function Register-ManualTrade($sym, [int]$sg, [double]$en, [double]$sl, [double]$tp, [double]$mg, [double]$lv, $qtyOverride = $null, $id = $null) {
    # si ya hay una operación manual abierta del mismo par y lado, solo se actualizan SL y TP (la R original no cambia); si no, se crea
    $sigs = @(Read-Signals)
    $ex = $sigs | Where-Object { $_.manual -eq $true -and $_.status -eq 'open' -and $_.sym -eq "${sym}USDT" -and [int]$_.side -eq $sg } | Select-Object -First 1
    if ($ex) {
        $ex.sl = $sl; $ex.tp1 = $tp; $ex.tp2 = $tp; $ex.tp3 = $tp; Save-Signals $sigs
        return @{ action = "actualizada"; rec = $ex }
    }
    $rec = New-ManualRecord $sym $sg $en $sl $tp $mg $lv $qtyOverride $id
    Add-SignalRecord $rec
    return @{ action = "registrada"; rec = $rec }
}
function Import-ManualTrades($file) {
    if (-not (Test-Path $file)) { return }
    try { $list = Get-Content $file -Raw -Encoding UTF8 | ConvertFrom-Json } catch { return }
    $have = @(Read-Signals | ForEach-Object { $_.id })
    foreach ($m in $list) {
        if (-not $m.id) { continue }
        if ($m.id -in $have) {
            if ($m.exit) {      # cierre real comunicado por el usuario (captura de Bitunix): se registra una sola vez
                $sigs = @(Read-Signals); $ex = $sigs | Where-Object { $_.id -eq $m.id -and $_.status -eq 'open' } | Select-Object -First 1
                if ($ex) {
                    $sg0 = [int]$ex.side; $px0 = [double]$m.exit; $q0 = [double]$ex.qty
                    $ex.status = 'closed'; $ex.exit = $px0; $ex.outcome = $(if ($m.outcome) { "$($m.outcome)" } else { 'cierre manual' }); $ex.closeNote = 'cerrada a mano por el usuario'
                    $ex.R = $sg0 * ($px0 - [double]$ex.entry) / [double]$ex.riskAbs
                    $ex.pnlUsd = $(if ($m.pnlReal) { [double]$m.pnlReal } else { [Math]::Round($sg0 * ($px0 - [double]$ex.entry) * $q0 - $q0 * [double]$ex.entry * $script:CostRT, 2) })
                    $ex.net = [double]$ex.R - $script:CostRT / ([double]$ex.slPct / 100); $ex.closedAt = $(if ($m.closedAt) { [long]$m.closedAt } else { [DateTimeOffset]::UtcNow.ToUnixTimeSeconds() })
                    Save-Signals $sigs; Write-Host ("Cierre real registrado: {0} a {1}" -f $m.id, $px0) -ForegroundColor Cyan
                }
            }
            # ya importada: si el fichero trae un SL inicial distinto, se corrige la R de referencia (solo mientras sigue abierta)
            if ($m.sl0) {
                $sigs = @(Read-Signals); $ex = $sigs | Where-Object { $_.id -eq $m.id -and $_.status -eq 'open' } | Select-Object -First 1
                if ($ex -and [double]$ex.sl0 -ne [double]$m.sl0) {
                    $ex.sl0 = [double]$m.sl0; $ex.riskAbs = [Math]::Abs([double]$ex.entry - [double]$m.sl0); $ex.slPct = [double]$ex.riskAbs / [double]$ex.entry * 100
                    Save-Signals $sigs; Write-Host ("R de referencia corregida con el SL inicial: {0}" -f $m.id) -ForegroundColor Cyan
                }
            }
            continue
        }
        $rec = New-ManualRecord $m.sym ([int]$m.side) ([double]$m.entry) ([double]$m.sl) ([double]$m.tp) ([double]$m.margin) ([double]$m.lev) $m.qty $m.id $m.sl0
        if ($m.note) { $rec.note = $m.note }
        Add-SignalRecord $rec
        Write-Host ("Operación manual importada al seguimiento: {0} {1}" -f $m.sym, $m.id) -ForegroundColor Cyan
    }
}
function Close-ManualTrade($sym, [double]$px) {
    $sigs = @(Read-Signals)
    $ex = $sigs | Where-Object { $_.manual -eq $true -and $_.status -eq 'open' -and $_.sym -eq "${sym}USDT" } | Select-Object -First 1
    if (-not $ex) { return $null }
    $sgn = [int]$ex.side; $q = [double]$ex.qty
    $ex.status = 'closed'; $ex.exit = $px; $ex.outcome = 'cierre manual'; $ex.closeNote = 'cerrada a mano por el usuario'
    $ex.R = $sgn * ($px - [double]$ex.entry) / [double]$ex.riskAbs
    $ex.pnlUsd = [Math]::Round($sgn * ($px - [double]$ex.entry) * $q - $q * [double]$ex.entry * $script:CostRT, 2)
    $ex.net = [double]$ex.R - $script:CostRT / ([double]$ex.slPct / 100); $ex.closedAt = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
    Save-Signals $sigs
    return $ex
}
function Get-ManualSection {
    $man = @(Read-Signals | Where-Object { $_.manual -eq $true })
    if ($man.Count -eq 0) { return @() }
    $L = @("", "👤 TUS OPERACIONES MANUALES (seguidas igual que las señales; resultado en USDT, comisiones estimadas al 0,10%)")
    $tot = 0.0
    foreach ($m in $man) {
        $sgn = [int]$m.side; $name = $m.sym -replace 'USDT$', ''; $dir = if ($sgn -eq 1) { "LARGO" } else { "CORTO" }; $q = [double]$m.qty
        if ($m.status -eq 'open') {
            $px = $null; try { $px = [double]((Invoke-RestMethod "$($script:TrkBase)/tickers?symbols=$($m.sym)" -TimeoutSec 15).data[0].lastPrice) } catch {}
            if ($px) {
                $unr = $sgn * ($px - [double]$m.entry) * $q; $tot += $unr
                $toTp = $sgn * ([double]$m.tp1 - $px) * $q; $toSl = $sgn * ($px - [double]$m.sl) * $q
                $rr = if ($toSl -gt 0) { " · R:B restante 1:{0:N2}" -f ($toTp / $toSl) } else { "" }
                $L += ("• {0} {1} x{2:N0} ABIERTA · entrada {3} · ahora {4} · latente {5:+0.00;-0.00} USDT ({6:+0.0;-0.0}% del margen) · SL {7} · TP {8}{9}" -f $name, $dir, [double]$m.lev, (Fmt ([double]$m.entry)), (Fmt $px), $unr, ($unr / [double]$m.margin * 100), (Fmt ([double]$m.sl)), (Fmt ([double]$m.tp1)), $rr)
                if (Get-Command Get-TradeTechNote -ErrorAction SilentlyContinue) { try { $L += @(Get-TradeTechNote $name $sgn ([double]$m.entry) ([double]$m.sl) ([double]$m.tp1) -Short | ForEach-Object { "   " + $_ }) } catch {} }
            } else { $L += ("• {0} {1} ABIERTA · entrada {2} · SL {3} · TP {4} (sin precio ahora)" -f $name, $dir, (Fmt ([double]$m.entry)), (Fmt ([double]$m.sl)), (Fmt ([double]$m.tp1))) }
        } else {
            $pnl = [double]$m.pnlUsd; $tot += $pnl
            $L += ("• {0} {1} CERRADA ({2}) · salida {3} · resultado {4:+0.00;-0.00} USDT ({5:+0.0;-0.0}% del margen) · {6:+0.00;-0.00}R" -f $name, $dir, $m.outcome, (Fmt ([double]$m.exit)), $pnl, ($pnl / [double]$m.margin * 100), [double]$m.net)
        }
    }
    $L += ("Total manuales (cerradas + latente): {0:+0.00;-0.00} USDT" -f $tot)
    return $L
}

# ---------- Estrategia en observación: barrido de liquidez en 4h (seguimiento en silencio, sin enviar señales) ----------
function Get-ObsSection {
    $o = @(Read-Signals | Where-Object { $_.strat -eq 'barrido-obs' })
    $L = @("", "🧪 ESTRATEGIA EN OBSERVACIÓN · barrido de liquidez en 4h (NO se envían señales: se sigue en silencio para validarla con datos reales)")
    if ($o.Count -eq 0) { $L += "• Aún no ha aparecido ningún setup. Criterios fijados de antemano: liquidez igual (EQH/EQL con ≥2 toques) → barrido → confirmación (la vela siguiente cierra más allá del cuerpo de la vela de barrido) → entrada; SL detrás del extremo del barrido; objetivo en la liquidez opuesta (R:B ≥1,5); tendencia diaria sin contra."; return $L }
    $cl = @($o | Where-Object { $_.status -eq 'closed' }); $op = @($o | Where-Object { $_.status -eq 'open' }).Count
    $L += ("• Setups registrados: {0} · cerrados: {1} · abiertos: {2}" -f $o.Count, $cl.Count, $op)
    if ($cl.Count) {
        $w = @($cl | Where-Object { [double]$_.net -gt 0 }).Count; $ex = ($cl | Measure-Object net -Average).Average
        $L += ("• Resultado: {0}/{1} ganadores ({2:N0}%) · esperanza {3:+0.00;-0.00}R por operación (neta de comisiones del 0,15%)" -f $w, $cl.Count, (100.0 * $w / $cl.Count), $ex)
    }
    $L += $(if ($cl.Count -lt 30) { "• Muestra insuficiente (n={0}): hacen falta al menos 30-60 operaciones cerradas con esperanza positiva sostenida antes de plantearse enviarla como señal. El backtest (4h) dio +0,2R ± 0,3R: un indicio, no una prueba." -f $cl.Count } else { "• Con n={0} ya se puede valorar; la decisión de activarla la tomamos Luis y yo con estos datos." -f $cl.Count })
    return $L
}

# ---------- Señales de MERCADO (acciones/ETFs, velas diarias) para el grupo Alertas Mercados: su seguimiento se informa solo en privado ----------
function Get-MarketSection {
    $o = @(Read-Signals | Where-Object { $_.strat -eq 'ruptura-mercado' })
    $L = @("", "🌍 SEÑALES DE MERCADO (grupo Alertas Mercados: acciones y ETFs, velas diarias)")
    if ($o.Count -eq 0) { $L += "• Aún no se ha emitido ninguna señal de mercado (se escanea cada día laborable a partir de las 22:30 hora de España)."; return $L }
    $cl = @($o | Where-Object { $_.status -eq 'closed' }); $op = @($o | Where-Object { $_.status -in 'open', 'pending' }).Count; $un = @($o | Where-Object { $_.status -eq 'unfilled' }).Count
    $L += ("• Emitidas: {0} · cerradas: {1} · abiertas/pendientes: {2} · sin ejecutar: {3}" -f $o.Count, $cl.Count, $op, $un)
    if ($cl.Count) {
        $tp1 = @($cl | Where-Object { $_.outcome -in 'TP1 + BE', 'TP2 + BE', 'TP3' }).Count; $ex = ($cl | Measure-Object net -Average).Average
        $L += ("• Cerradas: llegan a TP1 {0:N0}% · esperanza {1:+0.00;-0.00}R (neta de comisiones del 0,10%). Referencia del backtest (348 activos, 10 años): ≈63% a TP1 y ≈ +0,29R (≈ +0,12R en el último 40%)." -f (100.0 * $tp1 / $cl.Count), $ex)
    }
    $L += $(if ($cl.Count -lt 30) { "• Muestra insuficiente (n={0}): no se puede concluir nada todavía; el backtest es solo una referencia." -f $cl.Count } else { "• Con n={0} ya se puede comparar con el backtest." -f $cl.Count })
    return $L
}

# ---------- Disciplina: racha y pérdida acumulada de la semana (aviso, nunca una orden) ----------
function Get-DisciplineLines {
    $cl = @(Read-Signals | Where-Object { $_.manual -ne $true -and $_.strat -ne 'barrido-obs' -and $_.strat -ne 'ruptura-mercado' -and $_.strat -ne 'seg-grupo' -and $_.strat -ne 'seg-priv' -and $_.strat -ne 'momento-obs' -and $_.strat -ne 'aviso-momento' -and $_.strat -ne 'tomada' -and $_.status -eq 'closed' -and $_.closedAt } | Sort-Object { [long]$_.closedAt })
    $L = @("", "🛡️ DISCIPLINA Y RIESGO")
    if ($cl.Count -eq 0) { $L += "• Aún no hay señales cerradas. Recuerda el plan: cada operación debe acabar en pequeño beneficio, gran beneficio, pequeña pérdida o breakeven; nunca en una gran pérdida (SL siempre puesto en Bitunix y ≤35% del margen)."; return $L }
    $streak = 0; $dirWin = $null
    for ($i = $cl.Count - 1; $i -ge 0; $i--) { $w = ([double]$cl[$i].net -gt 0); if ($null -eq $dirWin) { $dirWin = $w }; if ($w -eq $dirWin) { $streak++ } else { break } }
    $now = Get-MadridNow; $monday = $now.Date.AddDays(-(([int]$now.DayOfWeek + 6) % 7)); $mondayUtc = [DateTimeOffset]::new($monday, [TimeZoneInfo]::FindSystemTimeZoneById("Romance Standard Time").GetUtcOffset($monday)).ToUnixTimeSeconds()
    $wk = @($cl | Where-Object { [long]$_.closedAt -ge $mondayUtc }); $wkR = if ($wk.Count) { ($wk | Measure-Object net -Sum).Sum } else { 0.0 }
    $L += ("• Racha actual: {0} {1} seguida(s) · esta semana: {2} operaciones cerradas, {3:+0.00;-0.00}R acumulados" -f $streak, $(if ($dirWin) { "ganadora(s)" } else { "perdedora(s)" }), $wk.Count, $wkR)
    if (-not $dirWin -and $streak -ge 3) { $L += "• 🛑 $streak pérdidas seguidas: en el backtest la racha máxima normal era de 3-4. Haz una pausa de revisión; NO aumentes el margen para recuperar." }
    elseif ($dirWin -and $streak -ge 3) { $L += "• ⚠️ $streak ganadoras seguidas: es cuando aparece la euforia. No relajes las reglas ni subas el margen; el mercado no debe nada. Valora asegurar beneficios y seguir con el mismo tamaño." }
    if ($wkR -le -3) { $L += ("• 🛑 Pérdida acumulada de la semana: {0:N1}R. Plan prudente: reducir tamaño o parar hasta el lunes y revisar con calma." -f $wkR) }
    $L += "• Recordatorio: ninguna operación debería acabar en una gran pérdida; SL siempre puesto en Bitunix, parcial en TP1 y SL a la entrada tras TP1."
    return $L
}
# ---------- Informe diario sencillo ----------
function Get-DailyReport {
    $now = Get-MadridNow; $all = @(Read-Signals); $auto = @($all | Where-Object { $_.manual -ne $true -and $_.strat -ne 'barrido-obs' -and $_.strat -ne 'ruptura-mercado' -and $_.strat -ne 'seg-grupo' -and $_.strat -ne 'seg-priv' -and $_.strat -ne 'momento-obs' -and $_.strat -ne 'aviso-momento' -and $_.strat -ne 'tomada' })
    $since = [DateTimeOffset]::UtcNow.AddHours(-24).ToUnixTimeSeconds()
    $new = @($auto | Where-Object { [long]$_.time -ge $since }).Count
    $clNew = @($auto | Where-Object { $_.status -eq 'closed' -and $_.closedAt -and [long]$_.closedAt -ge $since }).Count
    $L = @(("📊 INFORME DIARIO · {0:dd/MM/yyyy} {0:HH:mm} (hora de España)" -f $now))
    $L += ("Últimas 24 h: {0} señal(es) nueva(s) · {1} cerrada(s)" -f $new, $clNew)
    $L += ""
    $L += (Get-Report)
    $L += (Get-ManualSection)
    try { $L += (Get-DisciplineLines) } catch {}
    try { $L += (Get-ObsSection) } catch {}
    try { $L += (Get-MarketSection) } catch {}
    $L += ""; $L += "Resultados descontando comisiones. Comando para pedirlo cuando quieras: /resultados"
    return ($L -join "`n")
}
