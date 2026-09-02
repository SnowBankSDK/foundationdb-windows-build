# Renders the GitHub release body for a tag from the local artifacts, in the format of the existing
# releases of this repository, and writes it next to the artifacts as release-body.md.
#
# Usage:
#   .\scripts\release-body.ps1 -ArtifactDir .\artifacts\7.4.7
#   .\scripts\release-body.ps1 -ArtifactDir .\artifacts\7.4.7 -DylibSha256 <hash> -MacCliSha256 <hash>   # once the macOS files exist
#
# The version, source commit and protocol come from fdbcli.exe itself; the toolchain and patch lines
# come from build-info.txt when build-fdb.ps1 wrote one. Windows PowerShell 5.1 or PowerShell 7.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $ArtifactDir,
    [string] $OutFile = '',
    [string] $DylibSha256 = '',
    [string] $MacCliSha256 = ''
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
$dllHash = (Get-FileHash -Algorithm SHA256 $dll).Hash.ToLowerInvariant()
$cliHash = (Get-FileHash -Algorithm SHA256 $cli).Hash.ToLowerInvariant()

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
$dylibLine = if ($DylibSha256) { "``$($DylibSha256.ToLowerInvariant())``" } else { '<SHA256 of the macOS build, fill in when uploaded>' }
$macCliLine = if ($MacCliSha256) { "``$($MacCliSha256.ToLowerInvariant())``" } else { '<SHA256 of the macOS build, fill in when uploaded>' }

$body = @(
    "Windows and macOS Client Binaries for FoundationDB $version",
    '',
    '- Windows x86_64:',
    "  - ``fdb_c.dll``, SHA256 ``$dllHash``",
    "  - ``fdbcli.exe``, SHA256 ``$cliHash``",
    '',
    '- macOS arm64:',
    "  - ``libfdb_c.dylib``: SHA256 $dylibLine",
    "  - ``fdbcli``: SHA256 $macCliLine",
    '',
    "Windows build: upstream tag ``$version`` (commit ``$source``), protocol ``$protocol``, $($toolchain -join ', '), $patchLine. The Windows client library is built without TLS support and without AVX instructions."
) -join "`n"
[System.IO.File]::WriteAllText($OutFile, $body + "`n", [System.Text.Encoding]::UTF8)
Write-Host $body
Write-Host ''
Write-Host "release body written to $OutFile" -ForegroundColor Green
exit 0
