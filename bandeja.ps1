# BANDEJA DE REGISTROS (22/10/2026): permite dar de alta operaciones del usuario (strat 'tomada', las que normalmente se registran al enviar una captura) desde el repositorio, sin pasar por Telegram.
# bandeja-registros.jsonl = un registro JSON por línea; cada turno del bot los importa a signals.jsonl si su id aún no existe (Add-SignalRecord ya evita duplicados) y con la hora de importación (así cuentan para el punto de partida de limites.json).
function Import-InboxRecords {
    try { $f = Join-Path $PSScriptRoot "bandeja-registros.jsonl"; if (-not (Test-Path $f)) { return }
        $now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds(); $n = 0
        foreach ($ln in @(Get-Content $f -Encoding UTF8 | Where-Object { $_.Trim() })) {
            try { $r = $ln | ConvertFrom-Json; if (-not $r.id) { continue }
                if ((Test-Path $script:SigFile) -and (Select-String -Path $script:SigFile -SimpleMatch ('"id":"' + $r.id + '"') -Quiet)) { continue }
                $r.time = $now; if ($r.chkAt) { $r.chkAt = $now }; Add-SignalRecord $r; $n++ } catch {} }
        if ($n) { Write-Host ("  [bandeja] registros importados: {0}" -f $n) -ForegroundColor DarkGray }
    } catch {}
}
