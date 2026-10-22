# Reglas de disciplina de Luis (18/10/2026), SOLO para su chat privado: capital, margen por posición y pérdida máxima al día y a la semana (limites.json; 18/10/2026: 450 USDT, 75 por posición, 5% al día y 10% a la semana), no reentrar en la misma moneda
# en las 2 horas siguientes a cerrar con pérdida, y resumen semanal de sus operaciones. Se calcula con las operaciones CERRADAS que el bot conoce (las que registras con /operacion, /cerrar o capturas de cierre).
$script:ReentradaMin = 120
function Get-MisCerradas {
    $d0 = Get-DesdeEpoch; return @(Read-Signals | Where-Object { $_.manual -eq $true -and $_.status -eq 'closed' -and $_.closedAt -and $null -ne $_.pnlUsd -and [long]$_.closedAt -ge $d0 })
}
function Get-LimitesStatus {      # PnL realizado hoy y en la semana (lunes a domingo, hora de España)
    $now = Get-MadridNow; $hoy = $now.Date; $lunes = $hoy.AddDays( - (([int]$now.DayOfWeek + 6) % 7)); $dia = 0.0; $sem = 0.0; $nd = 0; $ns = 0
    foreach ($r in (Get-MisCerradas)) { $dt = [DateTimeOffset]::FromUnixTimeSeconds([long]$r.closedAt).ToOffset((New-TimeSpan -Hours 2)).Date
        if ($dt -ge $lunes) { $sem += [double]$r.pnlUsd; $ns++ }; if ($dt -eq $hoy) { $dia += [double]$r.pnlUsd; $nd++ } }
    return @{ dia = $dia; sem = $sem; nd = $nd; ns = $ns; hoy = $hoy.ToString('yyyy-MM-dd'); lunes = $lunes.ToString('yyyy-MM-dd') }
}
function Get-LimitesLine {
    $s = Get-LimitesStatus
    return ("📏 Tus límites: hoy {0:+0;-0;0} USDT (máx. pérdida {1:N0}) · semana {2:+0;-0;0} USDT (máx. pérdida {3:N0}) · margen por posición {4:N0} USDT (capital {5:N0}) · sin reentrar en la misma moneda en 2 h tras perder" -f $s.dia, (Get-LimConfig).dia, $s.sem, (Get-LimConfig).sem, (Get-LimConfig).margen, (Get-LimConfig).capital)
}
function Check-LimitesRiesgo {      # aviso proactivo al chat privado: 80% y 100% del límite diario y semanal (una vez por periodo y nivel)
    $s = Get-LimitesStatus
    foreach ($c in @(@('limd', $s.dia, (Get-LimConfig).dia, $s.hoy, 'HOY', 'el límite diario'), @('limw', $s.sem, (Get-LimConfig).sem, $s.lunes, 'ESTA SEMANA', 'el límite semanal'))) {
        $loss = - [double]$c[1]; if ($loss -le 0) { continue }; $lim = [double]$c[2]; $stage = if ($loss -ge $lim) { 2 } elseif ($loss -ge 0.8 * $lim) { 1 } else { 0 }; if ($stage -eq 0) { continue }
        $st = Get-ReportState $c[0]; $prev = 0; if ($st -match ('^' + [regex]::Escape($c[3]) + ':(\d)$')) { $prev = [int]$Matches[1] }; if ($prev -ge $stage) { continue }
        Set-ReportState $c[0] ("{0}:{1}" -f $c[3], $stage)
        $msg = if ($stage -eq 2) { "🛑 LÍMITE ALCANZADO · llevas {0:N0} USDT de pérdida realizada {1} y tu regla es {2:N0}. Hoy no abras más operaciones: cierra la pantalla, revisa el diario y vuelve mañana con la cabeza fría. (El bot no opera por ti: la decisión es tuya, pero esta es la regla que tú mismo pusiste.)" -f $loss, $c[4], $lim }
                else { "⚠️ Te acercas a {0}: {1:N0} de {2:N0} USDT de pérdida realizada {3}. Una pérdida más puede dejarte fuera por hoy: solo operaciones que cumplan TODAS tus reglas, con el margen y el SL de siempre." -f $c[5], $loss, $lim, $c[4] }
        Send-ToSignalChats $msg
    }
}
function Get-MisOperacionesResumen([int]$dias = 7) {
    $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds(); $ini = $now - $dias * 86400
    $all = @(Get-MisCerradas | Where-Object { [long]$_.closedAt -ge $ini } | Sort-Object { [long]$_.closedAt })
    if (-not $all.Count) { return "📒 RESUMEN DE TUS OPERACIONES · últimos $dias días`nNo hay operaciones cerradas registradas en este periodo (el bot solo conoce las que registras con /operacion, /cerrar o capturas de cierre)." }
    $gan = @($all | Where-Object { [double]$_.pnlUsd -gt 0 }); $perd = @($all | Where-Object { [double]$_.pnlUsd -le 0 }); $net = ($all | Measure-Object pnlUsd -Sum).Sum
    $gw = if ($gan.Count) { ($gan | Measure-Object pnlUsd -Sum).Sum } else { 0.0 }; $gl = if ($perd.Count) { ($perd | Measure-Object pnlUsd -Sum).Sum } else { 0.0 }
    $lev = @($all | Where-Object { $_.lev } | ForEach-Object { [double]$_.lev }); $avgLev = if ($lev.Count) { ($lev | Measure-Object -Average).Average } else { 0 }
    $worst = $all | Sort-Object { [double]$_.pnlUsd } | Select-Object -First 1; $best = $all | Sort-Object { [double]$_.pnlUsd } -Descending | Select-Object -First 1
    # reentradas en la misma moneda dentro de las 2 h posteriores a una pérdida, y operaciones con apalancamiento mayor que la pérdida anterior
    $re = 0; $esc = 0; $prev = $null
    foreach ($r in @(Get-MisCerradas | Sort-Object { [long]$_.time })) { if ($prev -and [long]$r.time -ge $ini) {
            foreach ($p in @(Get-MisCerradas | Where-Object { [double]$_.pnlUsd -lt 0 -and [long]$_.closedAt -lt [long]$r.time -and ([long]$r.time - [long]$_.closedAt) -le 7200 })) { if ($p.sym -eq $r.sym) { $re++; break } }
            $lp = @(Get-MisCerradas | Where-Object { [double]$_.pnlUsd -lt 0 -and [long]$_.closedAt -lt [long]$r.time -and ([long]$r.time - [long]$_.closedAt) -le 21600 } | Sort-Object { [long]$_.closedAt } -Descending | Select-Object -First 1); if ($lp.Count -and $r.lev -and $lp[0].lev -and [double]$r.lev -gt [double]$lp[0].lev) { $esc++ } }; $prev = $r }
    $out = @("📒 RESUMEN DE TUS OPERACIONES · últimos $dias días (solo cerradas registradas)")
    $out += ("• {0} operaciones: {1} ganadoras y {2} perdedoras ({3:N0}% de acierto) · resultado neto {4:+0;-0;0} USDT" -f $all.Count, $gan.Count, $perd.Count, (100.0 * $gan.Count / $all.Count), $net)
    $out += ("• Ganado {0:N0} USDT · perdido {1:N0} USDT · media por ganadora {2:N0} y por perdedora {3:N0} USDT" -f $gw, [Math]::Abs($gl), $(if ($gan.Count) { $gw / $gan.Count } else { 0 }), $(if ($perd.Count) { [Math]::Abs($gl) / $perd.Count } else { 0 }))
    if ($avgLev -gt 0) { $out += ("• Apalancamiento medio x{0:N0}" -f $avgLev) }
    $out += ("• Mejor: {0} {1:+0;-0} USDT · peor: {2} {3:+0;-0} USDT" -f ($best.sym -replace 'USDT$', ''), [double]$best.pnlUsd, ($worst.sym -replace 'USDT$', ''), [double]$worst.pnlUsd)
    $out += ("• Disciplina: {0} reentrada(s) en la misma moneda en menos de 2 h tras perder · {1} vez(ces) subiste el apalancamiento tras una pérdida" -f $re, $esc)
    if ($gw -gt 0 -and $perd.Count -and [Math]::Abs($gl) / $perd.Count -gt $gw / [Math]::Max(1, $gan.Count)) { $out += "• Ojo: tu pérdida media supera tu ganancia media; con este acierto no sale a cuenta. Corta antes las perdedoras o deja correr más las ganadoras." }
    $s = Get-LimitesStatus; $out += ("• Semana en curso: {0:+0;-0;0} USDT de {1:N0} de pérdida máxima permitida" -f $s.sem, (Get-LimConfig).sem)
    return ($out -join "`n")
}
function Send-MisOperacionesSemanal {      # domingos tras las 22:00 (hora de España), una vez por semana; solo chat privado
    $now = Get-MadridNow; if ($now.DayOfWeek -ne [DayOfWeek]::Sunday -or $now.Hour -lt 22) { return }
    $k = $now.ToString('yyyy-MM-dd'); if ((Get-ReportState 'misops') -eq $k) { return }; Set-ReportState 'misops' $k
    Send-ToSignalChats (Get-MisOperacionesResumen 7)
}
