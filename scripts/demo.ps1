# Native Windows demos: no Bash, Python, WSL or geometry generator required.
[CmdletBinding()]
param(
    [Parameter(Mandatory=$true)][ValidateSet('scene','grinding','rays')][string]$Demo,
    [string]$Out,
    [double]$Voxel = 0.1,
    [double]$Spacing = 0.025,
    [double]$Tolerance = 0.01,
    [ValidateRange(1,64)][int]$Workers = 8,
    [ValidateRange(4,4096)][int]$StepsPerTurn = 128,
    [string]$Workpiece,
    [switch]$NoViewer,
    [switch]$SkipBuild
)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
$allowed = switch ($Demo) {
    'scene' { @('Workpiece') }
    'grinding' { @('Voxel','Tolerance','Workers','StepsPerTurn') }
    'rays' { @('Spacing','Tolerance','Workers') }
}
foreach ($name in @('Voxel','Spacing','Tolerance','Workers','StepsPerTurn','Workpiece')) {
    if ($PSBoundParameters.ContainsKey($name) -and $name -notin $allowed) {
        throw "-$name is not supported by the $Demo demo."
    }
}
foreach ($value in @($Voxel,$Spacing,$Tolerance)) {
    if ([double]::IsNaN($value) -or [double]::IsInfinity($value) -or $value -le 0) {
        throw 'Voxel spacing, ray spacing and motion tolerance must be finite and positive.'
    }
}
if ($Out) {
    if (![IO.Path]::IsPathRooted($Out)) { $Out = Join-Path (Get-Location).Path $Out }
    $Out = [IO.Path]::GetFullPath($Out)
} else {
    $Out = Join-Path $root ('out/windows-' + $Demo + '-' + [guid]::NewGuid().ToString('N'))
}
if (Test-Path -LiteralPath $Out) { throw "Output already exists; choose a new directory: $Out" }
function Number([double]$value) { $value.ToString('R', [Globalization.CultureInfo]::InvariantCulture) }
Push-Location $root
try {
    if (!$SkipBuild) {
        & ./zig.ps1 build -Doptimize=ReleaseFast
        if ($LASTEXITCODE -ne 0) { throw 'CLI build failed; run scripts/bootstrap-zig.ps1 first.' }
    }
    $engine = Join-Path $root 'zig-out/bin/menkh.exe'
    if (!(Test-Path -LiteralPath $engine)) { throw 'CLI missing: run scripts/bootstrap-zig.ps1 and zig.ps1 build -Doptimize=ReleaseFast.' }
    $viewer = Join-Path $root 'out/windows-viewer/menkh-viewer.exe'
    if (!$NoViewer -and $Demo -ne 'rays' -and !(Test-Path -LiteralPath $viewer)) {
        if ($SkipBuild) { throw 'Viewer missing: run viewer/windows/build.bat, or use -NoViewer.' }
        & ./viewer/windows/build.bat
        if ($LASTEXITCODE -ne 0) { throw 'Viewer build failed; Visual Studio C++ desktop tools and Windows SDK are required. Use -NoViewer for calculation only.' }
    }
    $viewerArgs = @()
    switch ($Demo) {
        'scene' {
            & $engine scene examples/two-workpieces.json --out $Out
            $viewerArgs = @((Join-Path $Out 'scene.json'))
            if ($Workpiece) { $viewerArgs += @('--workpiece',$Workpiece) }
        }
        'grinding' {
            & $engine grinding-demo --voxel (Number $Voxel) --tolerance (Number $Tolerance) --workers $Workers --steps-per-turn $StepsPerTurn --out $Out
            $viewerArgs = @((Join-Path $Out 'result/voxel-animation.json'),'--color-operation')
        }
        'rays' {
            & $engine raydexel-bench --method sweep --spacing (Number $Spacing) --tolerance (Number $Tolerance) --workers $Workers --out $Out
        }
    }
    if ($LASTEXITCODE -ne 0) { throw "The $Demo calculation failed (exit $LASTEXITCODE)." }
    Write-Host "Result: $Out"
    if ($Demo -eq 'rays') {
        Write-Host 'Final-state interval result: report.json, intervals.bin/json and PPM sections.'
        Write-Host 'The Windows viewer cannot load interval results. Use -Demo grinding for voxel playback.'
    } elseif (!$NoViewer) {
        & $viewer @viewerArgs
        if ($LASTEXITCODE -ne 0) { throw "Viewer failed (exit $LASTEXITCODE)." }
    }
} finally {
    Pop-Location
}
