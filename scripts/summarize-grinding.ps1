# Read-only phase summary. Run after grinding-demo; no Python required.
param([Parameter(Mandatory=$true)][string]$Report)
$ErrorActionPreference = 'Stop'
$r = Get-Content -LiteralPath $Report -Raw | ConvertFrom-Json
if ($r.format -ne 'menkh-job-report-v1') { throw 'Expected a menkh job report' }
$cut = 0.0; $history = 0.0; $collision = 0.0; $pieces = 0L
foreach ($op in $r.operations) {
    $cut += $op.cut_ns; $history += $op.history_write_ns
    $collision += $op.collision_ns; $pieces += $op.sweep_pieces
}
[ordered]@{
    report_sha256 = (Get-FileHash -LiteralPath $Report -Algorithm SHA256).Hash
    os = [Environment]::OSVersion.VersionString
    logical_processors = [Environment]::ProcessorCount
    zig = $r.zig; mode = $r.mode; workers_requested = $r.workers
    voxel_mm = $r.voxel_mm; operations = $r.operations.Count; sweep_pieces = $pieces
    total_seconds = $r.timing.total_ns / 1e9
    cutting_seconds = $cut / 1e9
    history_write_seconds = $history / 1e9
    collision_seconds = $collision / 1e9
    other_seconds = ($r.timing.total_ns - $cut - $history - $collision) / 1e9
    peak_rss_bytes = $r.process_peak_rss_bytes
    history_bytes = $r.history_bytes
    remaining_occupied = $r.remaining_occupied
    note = 'Recorded simulation times; excludes viewer and video export. Writes are cached, not durable-storage timings.'
} | ConvertTo-Json
