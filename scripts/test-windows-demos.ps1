# Run in Windows CI after building the CLI. Deliberately uses no viewer/Python.
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$launcher = Join-Path $PSScriptRoot 'demo.ps1'
$testRoot = Join-Path $root ('out/launcher tests-' + [guid]::NewGuid().ToString('N'))
New-Item -ItemType Directory -Path $testRoot | Out-Null
$previousCulture = [Threading.Thread]::CurrentThread.CurrentCulture
Push-Location $testRoot
try {
    [Threading.Thread]::CurrentThread.CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo('de-DE')
    & $launcher -Demo scene -Out 'scene result' -SkipBuild -NoViewer
    $scene = Get-Content -LiteralPath 'scene result/scene.json' -Raw | ConvertFrom-Json
    if ($scene.format -ne 'menkh-scene-result-v1' -or $scene.results.Count -ne 2) { throw 'Scene launcher failed' }
    & $launcher -Demo grinding -Voxel 0.5 -Tolerance 0.08 -StepsPerTurn 16 -Workers 1 -Out 'grinding result' -SkipBuild -NoViewer
    $grind = Get-Content -LiteralPath 'grinding result/result/report.json' -Raw | ConvertFrom-Json
    if ($grind.voxel_mm -ne 0.5 -or $grind.operations.Count -ne 128 -or $grind.remaining_occupied -ge $grind.initial_occupied) { throw 'Grinding launcher failed' }
    if (!(Test-Path -LiteralPath 'grinding result/result/voxel-animation.json')) { throw 'Playback missing' }
    & $launcher -Demo rays -Spacing 0.5 -Workers 1 -Out 'ray result' -SkipBuild -NoViewer
    $ray = Get-Content -LiteralPath 'ray result/report.json' -Raw | ConvertFrom-Json
    if ($ray.method -ne 'sweep' -or $ray.spacing_mm -ne 0.5) { throw 'Ray launcher failed' }
    $before = (Get-FileHash -LiteralPath 'scene result/scene.json').Hash
    $rejected = $false
    try { & $launcher -Demo scene -Out 'scene result' -SkipBuild -NoViewer } catch { $rejected = $true }
    if (!$rejected -or (Get-FileHash -LiteralPath 'scene result/scene.json').Hash -ne $before) { throw 'Existing result protection failed' }
    $rejected = $false
    try { & $launcher -Demo scene -Voxel 0.5 -Out 'invalid' -SkipBuild -NoViewer } catch { $rejected = $true }
    if (!$rejected -or (Test-Path -LiteralPath 'invalid')) { throw 'Irrelevant option was silently accepted' }
    $rejected = $false
    try { & $launcher -Demo rays -Spacing ([double]::NaN) -Out 'invalid' -SkipBuild -NoViewer } catch { $rejected = $true }
    if (!$rejected -or (Test-Path -LiteralPath 'invalid')) { throw 'Invalid spacing accepted' }
    Write-Host 'Windows demos: scene, grinding, rays, locale, paths with spaces and failure protection passed.'
} finally {
    [Threading.Thread]::CurrentThread.CurrentCulture = $previousCulture
    Pop-Location
}
