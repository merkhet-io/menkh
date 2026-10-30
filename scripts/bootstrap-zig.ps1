$ErrorActionPreference = 'Stop'
Set-Location (Join-Path $PSScriptRoot '..')
$tool = '.tools/zig-x86_64-windows-0.15.2/zig.exe'
if (Test-Path $tool) {
    $version = & $tool version
    if ($LASTEXITCODE -ne 0 -or $version -ne '0.15.2') { throw 'Unexpected local Zig version' }
    Write-Output $version
    exit 0
}
New-Item -ItemType Directory -Force .tools | Out-Null
$archive = '.tools/zig-windows-0.15.2.zip'
Invoke-WebRequest 'https://ziglang.org/download/0.15.2/zig-x86_64-windows-0.15.2.zip' -OutFile $archive
$expected = '3a0ed1e8799a2f8ce2a6e6290a9ff22e6906f8227865911fb7ddedc3cc14cb0c'
if ((Get-FileHash $archive -Algorithm SHA256).Hash.ToLowerInvariant() -ne $expected) { throw 'Zig archive checksum mismatch' }
Expand-Archive $archive -DestinationPath .tools -Force
& $tool version
if ($LASTEXITCODE -ne 0) { throw 'Local Zig failed' }
