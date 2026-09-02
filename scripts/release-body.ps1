# Renders the GitHub release body for a tag from the local artifacts, in the format of the existing
# releases of this repository, and writes it next to the artifacts as release-body.md.
#
# Usage:
#   .\scripts\release-body.ps1 -ArtifactDir .\artifacts\7.4.7
#
# The version, source commit and protocol come from fdbcli.exe itself; the toolchain and patch lines
# come from build-info.txt when build-fdb.ps1 wrote one. The macOS sections carry the hashes of the
# files fetch-macos-client.ps1 placed in the directory (libfdb_c.arm64.dylib, fdbcli.arm64,
# libfdb_c.x86_64.dylib, fdbcli.x86_64), placeholders otherwise. Windows PowerShell 5.1 or PowerShell 7.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $ArtifactDir,
    [string] $OutFile = ''
)

$ErrorActionPreference = 'Continue'
if ([string]::IsNullOrEmpty($OutFile)) { $OutFile = Join-Path $ArtifactDir 'release-body.md' }
$dll = Join-Path $ArtifactDir 'fdb_c.dll'
$cli = Join-Path $ArtifactDir 'fdbcli.exe'
foreach ($f in @($dll, $cli)) { if (-not (Test-Path $f)) { Write-Host "missing $f" -ForegroundColor Red; exit 1 } }

$version = ''; $source = ''; $protocol = ''
foreach ($l in @(& $cli --version 2>&1 | ForEach-Object { "$_" })) {
    if ($l -match '\(v(\d+\.\d+\.\d+)\)') { $version = $Matches[1] }
    if ($l -match '^source version\s+([0-9a-f]+)') { $source = $Matches[1] }
    if ($l -match '^protocol\s+([0-9a-f]+)') { $protocol = $Matches[1] }
}
if ([string]::IsNullOrEmpty($version)) { Write-Host 'fdbcli --version reported no version' -ForegroundColor Red; exit 1 }
function Get-Sha([string] $Path) { return (Get-FileHash -Algorithm SHA256 $Path).Hash.ToLowerInvariant() }
function Get-Line([string] $Name) {
    $path = Join-Path $ArtifactDir $Name
    if (Test-Path $path) { return "  - ``$Name``: SHA256 ``$(Get-Sha $path)``" }
    return "  - ``$Name``: SHA256 <not fetched yet: run fetch-macos-client.ps1 -Tag $version>"
}

$info = @{}
$infoPath = Join-Path $ArtifactDir 'build-info.txt'
if (Test-Path $infoPath) {
    foreach ($l in Get-Content $infoPath) { if ($l -match '^([a-z_. ]+?):\s*(.+)$') { $info[$Matches[1].Trim()] = $Matches[2].Trim() } }
}
$toolchain = @()
if ($info['clang']) { $toolchain += ($info['clang'] -replace '^clang version ', 'clang-cl ') }
if ($info['cmake']) { $toolchain += ($info['cmake'] -replace '^cmake version ', 'CMake ') }
$toolchain += 'Boost 1.86.0'
$patchLine = if ($info['patch']) { "patch set ``$($info['patch'])``" } else { 'the patch set of this repository' }

$body = @(
    "Windows and macOS Client Binaries for FoundationDB $version",
    '',
    '- Windows x86_64:',
    "  - ``fdb_c.dll``, SHA256 ``$(Get-Sha $dll)``",
    "  - ``fdbcli.exe``, SHA256 ``$(Get-Sha $cli)``",
    '',
    '- macOS arm64:',
    (Get-Line 'libfdb_c.arm64.dylib'),
    (Get-Line 'fdbcli.arm64'),
    '',
    '- macOS x86_64:',
    (Get-Line 'libfdb_c.x86_64.dylib'),
    (Get-Line 'fdbcli.x86_64'),
    '',
    "Windows build: upstream tag ``$version`` (commit ``$source``), protocol ``$protocol``, $($toolchain -join ', '), $patchLine. The Windows client library is built without TLS support and without AVX instructions.",
    "macOS files: the unmodified client payloads of the upstream ``FoundationDB-${version}_arm64.pkg`` and ``FoundationDB-${version}_x86_64.pkg``, renamed with their architecture."
) -join "`n"
[System.IO.File]::WriteAllText($OutFile, $body + "`n", [System.Text.Encoding]::UTF8)
Write-Host $body
Write-Host ''
Write-Host "release body written to $OutFile" -ForegroundColor Green
exit 0
