# MESA DE BALLENAS (observación silenciosa). NO envía nada: cada ballena nueva (>= umbral, Hyperliquid) pasa por etapas y, si la moneda está en Bitunix y hay plan, se registra una orden HIPOTÉTICA en signals.jsonl
# (strat 'arranque-obs', id 'mesa-...') para medir si seguir a una ballena, con o sin la lectura del bot a favor, tiene ventaja. Etapas: ATLAS (ballena) -> ORION (puntuación 4h/1d/1h del lado de la ballena y plan) -> NOVA (SL con estructura, apalancamiento y SL <= 20% del margen) -> ficha hipotética.
# NOVA veta (veto=1) cuando el primer obstáculo queda pegado a la entrada; esos casos también se registran para comparar. Orden hipotética: la del plan de /momento (entrada limit en retroceso o a mercado, SL, tercios 1R/2R/3R). ctxFlags guarda si la lectura del bot coincidía ('agree=1', puntuación >= umbral de momento) o no, para comparar ambos grupos. Máx. 6 por pasada y 12 al día.
# No se avisa hasta confirmar con >=30 casos reales por grupo, TP1 > 60% y esperanza neta positiva. El bot no opera: solo mediría.
function Get-MesaBxSym($coin, $bx) {      # nombre de Hyperliquid -> símbolo de Bitunix ('kPEPE' -> '1000PEPE'); $null si no cotiza en Bitunix
    $c = "$coin".ToUpper(); $cands = @($c); if ("$coin" -cmatch '^k[A-Z0-9]+$') { $cands = @(('1000' + "$coin".Substring(1).ToUpper()), "$coin".Substring(1).ToUpper()) }
    foreach ($x in $cands) { if ($bx.ContainsKey($x)) { return $x } }; return $null
}
function Run-MesaObs($positions) {
    if (-not $positions -or -not @($positions).Count) { return }
    $bx = @{}; try { foreach ($t in (Invoke-RestMethod "$($script:CmdBase)/tickers" -TimeoutSec 20).data) { if ($t.symbol -like '*USDT') { $bx[($t.symbol -replace 'USDT$', '')] = $t } } } catch { return }
    $today = (Get-Date).ToUniversalTime().ToString('yyyyMMdd'); $nToday = 0; try { $nToday = @(Read-Signals | Where-Object { $_.id -like "mesa-*" -and [DateTimeOffset]::FromUnixTimeSeconds([long]$_.time).UtcDateTime.ToString('yyyyMMdd') -eq $today }).Count } catch {}
    $thr = [int](Get-MomCfg 'umbralMomento' 7); $done = 0
    foreach ($p in @($positions | Select-Object -First 6)) {
        if ($nToday + $done -ge 12) { break }
        try {
            $sym = Get-MesaBxSym $p.coin $bx; if (-not $sym) { continue }
            $id = "mesa-$sym-$($p.side)-$($p.addr.Substring(2, 6))-$((Get-Date).ToUniversalTime().ToString('yyyyMMdd'))"; if (@(Read-Signals | Where-Object { $_.id -eq $id }).Count) { continue }
            $px = [double]$bx[$sym].lastPrice; if ($px -le 0) { continue }
            $s = @{ src = 'bitunix'; sym = $sym; name = "$sym/USDT"; currency = 'USDT'; exch = ''; price = $px; extra = @{ funding = $null } }
            $sc = Get-MomScores $s; if (-not $sc) { continue }
            $side = $p.side; $me = if ($side -eq 'L') { $sc.lg } else { $sc.st }; $score = [int]$me.score; $plan = $me.plan; if (-not $plan) { continue }
            if ($plan.pullback -and [Math]::Abs([double]$plan.entry - $px) / $px * 100 -gt 1.5) { continue }
            $veto = 0; if (Get-Command Apply-SlStructure -ErrorAction SilentlyContinue) { $slx = $null; try { $slx = Apply-SlStructure $plan $side $sym $px } catch {}; if ($slx) { if ($slx.skip) { $veto = 1 } else { $score = $score + [int]$slx.delta } } }      # NOVA: si veta (obstáculo pegado a la entrada) se registra igualmente con veto=1 para medir si el veto acierta
            $lv = Get-OrderLevels $side $plan 'cripto' $score; if (-not $lv -or [int]$lv.lev -lt 1) { continue }
            $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
            $k = @((Invoke-RestMethod "$($script:CmdBase)/kline?symbol=${sym}USDT&interval=4h&limit=3" -TimeoutSec 20).data | Sort-Object { [long]$_.time }); $last = [long]$k[$k.Count - 1].time
            Add-SignalRecord ([ordered]@{
                id = $id; time = $now; sym = "${sym}USDT"; tf = '4h'; strat = 'arranque-obs'; side = $lv.sg
                entryType = $(if ($plan.pullback) { 'limit' } else { 'market' }); entry = $lv.entry; sl = $lv.sl; tp1 = $lv.t1; tp2 = $lv.t2; tp3 = $lv.t3; riskAbs = [Math]::Abs($lv.entry - $lv.sl); slPct = $lv.slPct; lev = $lv.lev
                status = $(if ($plan.pullback) { 'pending' } else { 'open' }); stage = 0; realized = 0.0; age = 0; expiry = 6; lastLabel = $last; lab0 = $last; cost = 0.0015; outcome = $null; R = $null; net = $null
                ctxScore = $score; ctxFlags = ("mesa;agree={0};veto={1};whale={2:N0}M;lev={3}x" -f $(if ($score -ge $thr) { 1 } else { 0 }), $veto, ($p.usd / 1e6), $p.lev); note = "observación silenciosa: mesa de ballenas (ATLAS->ORION->NOVA)"
            })
            $done++
        } catch {}
    }
    if ($done) { Write-Host ("  [mesa-ballenas] órdenes hipotéticas registradas: {0}" -f $done) -ForegroundColor DarkGray }
}
