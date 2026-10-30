$ErrorActionPreference = 'Stop'
$tool = Join-Path $PSScriptRoot '.tools/zig-x86_64-windows-0.15.2/zig.exe'
if (!(Test-Path $tool)) { throw 'Run .\scripts\bootstrap-zig.ps1 first (repo-local download).' }
& $tool @args
exit $LASTEXITCODE
