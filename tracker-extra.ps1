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
    if (Test-Path $f) { $lines = @(Get-Content $f -Encoding UTF8 | Where-Object { $_ -match '^(daily|weekly)=' -and $_ -notmatch ('^' + [regex]::Escape($key) + '=') }) }
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
            } else { $L += ("• {0} {1} ABIERTA · entrada {2} · SL {3} · TP {4} (sin precio ahora)" -f $name, $dir, (Fmt ([double]$m.entry)), (Fmt ([double]$m.sl)), (Fmt ([double]$m.tp1))) }
        } else {
            $pnl = [double]$m.pnlUsd; $tot += $pnl
            $L += ("• {0} {1} CERRADA ({2}) · salida {3} · resultado {4:+0.00;-0.00} USDT ({5:+0.0;-0.0}% del margen) · {6:+0.00;-0.00}R" -f $name, $dir, $m.outcome, (Fmt ([double]$m.exit)), $pnl, ($pnl / [double]$m.margin * 100), [double]$m.net)
        }
    }
    $L += ("Total manuales (cerradas + latente): {0:+0.00;-0.00} USDT" -f $tot)
    return $L
}

# ---------- Informe diario sencillo ----------
function Get-DailyReport {
    $now = Get-MadridNow; $all = @(Read-Signals); $auto = @($all | Where-Object { $_.manual -ne $true })
    $since = [DateTimeOffset]::UtcNow.AddHours(-24).ToUnixTimeSeconds()
    $new = @($auto | Where-Object { [long]$_.time -ge $since }).Count
    $clNew = @($auto | Where-Object { $_.status -eq 'closed' -and $_.closedAt -and [long]$_.closedAt -ge $since }).Count
    $L = @(("📊 INFORME DIARIO · {0:dd/MM/yyyy} {0:HH:mm} (hora de España)" -f $now))
    $L += ("Últimas 24 h: {0} señal(es) nueva(s) · {1} cerrada(s)" -f $new, $clNew)
    $L += ""
    $L += (Get-Report)
    $L += (Get-ManualSection)
    $L += ""; $L += "Resultados descontando comisiones. Comando para pedirlo cuando quieras: /resultados"
    return ($L -join "`n")
}
