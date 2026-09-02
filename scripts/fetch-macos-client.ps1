# Fetches the macOS client files of an upstream FoundationDB tag from the upstream macOS packages and
# places them next to the Windows artifacts, named with their architecture so both fit in one release:
# libfdb_c.arm64.dylib, fdbcli.arm64, libfdb_c.x86_64.dylib, fdbcli.x86_64, and a .sha256 file for each.
#
# The upstream release carries FoundationDB-<Tag>_arm64.pkg and FoundationDB-<Tag>_x86_64.pkg, each with
# a .sha256 asset. A .pkg is a xar archive; inside it, FoundationDB-clients.pkg\Payload is a gzip stream
# whose content is a cpio archive with usr/local/lib/libfdb_c.dylib and usr/local/bin/fdbcli. 7-Zip
# unpacks all three layers. The files are copied unmodified; only the names change.
#
# Usage:
#   .\scripts\fetch-macos-client.ps1 -Tag 7.4.7                 # both architectures
#   .\scripts\fetch-macos-client.ps1 -Tag 7.4.4 -Arch arm64 -ArtifactDir C:\drops\7.4.4
#
# Needs 7-Zip (C:\Program Files\7-Zip\7z.exe by default) and curl.exe. Windows PowerShell 5.1 or 7.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $Tag,
    [ValidateSet('arm64', 'x86_64', 'both')] [string] $Arch = 'both',
    [string] $ArtifactDir = '',
    [string] $WorkDir = '',
    [string] $SevenZip = 'C:\Program Files\7-Zip\7z.exe',
    [switch] $KeepWork
)

$ErrorActionPreference = 'Continue'
$repoRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrEmpty($ArtifactDir)) { $ArtifactDir = Join-Path $repoRoot "artifacts\$Tag" }
if ([string]::IsNullOrEmpty($WorkDir)) { $WorkDir = Join-Path $ArtifactDir 'macos-pkg' }
$archs = if ($Arch -eq 'both') { @('arm64', 'x86_64') } else { @($Arch) }
$script:failed = $false
function Gate([string] $Name, [bool] $Ok, [string] $Detail) {
    $status = 'PASS'
    if (-not $Ok) { $status = 'FAIL'; $script:failed = $true }
    Write-Host ("{0,-4} {1,-30} {2}" -f $status, $Name, $Detail) -ForegroundColor $(if ($Ok) { 'Green' } else { 'Red' })
}
function Stop-Fetch() { Write-Host 'MACOS FETCH FAILED' -ForegroundColor Red; exit 1 }
function Invoke-7z([string[]] $Arguments) {
    & $SevenZip @Arguments 2>&1 | Out-Null
    return $LASTEXITCODE
}
function Get-Magic([string] $Path) {
    $stream = [System.IO.File]::OpenRead($Path)
    $bytes = New-Object byte[] 4
    $read = $stream.Read($bytes, 0, 4)
    $stream.Close()
    if ($read -ne 4) { return '' }
    return (($bytes | ForEach-Object { $_.ToString('x2') }) -join '')
}

# 1. Tools.
Gate '7-Zip' (Test-Path $SevenZip) "$SevenZip (install 7-Zip or pass -SevenZip)"
$curl = Get-Command curl.exe -ErrorAction SilentlyContinue
Gate 'curl.exe' ($null -ne $curl) $(if ($curl) { $curl.Source } else { 'not found' })
if ($script:failed) { Stop-Fetch }
New-Item -ItemType Directory -Force -Path $ArtifactDir | Out-Null

foreach ($a in $archs) {
    $pkgName = "FoundationDB-${Tag}_$a.pkg"
    $pkgUrl = "https://github.com/apple/foundationdb/releases/download/$Tag/$pkgName"
    $work = Join-Path $WorkDir $a
    New-Item -ItemType Directory -Force -Path $work | Out-Null

    # 2. Download the package and its upstream .sha256, verify the package hash.
    $pkg = Join-Path $work $pkgName
    $pkgSha = "$pkg.sha256"
    foreach ($pair in @(@($pkgUrl, $pkg), @("$pkgUrl.sha256", $pkgSha))) {
        if (Test-Path $pair[1]) { continue }
        & curl.exe -L --fail --silent --show-error -o $pair[1] $pair[0]
        if ($LASTEXITCODE -ne 0) { Gate "$a download" $false "$($pair[0]) (curl exit $LASTEXITCODE)"; Stop-Fetch }
    }
    $expected = ((Get-Content $pkgSha -Raw) -split '\s+')[0].ToLowerInvariant()
    $actual = (Get-FileHash -Algorithm SHA256 $pkg).Hash.ToLowerInvariant()
    Gate "$a package hash" ($expected -eq $actual) "$pkgName $((Get-Item $pkg).Length.ToString('N0')) bytes, sha256 $actual; upstream .sha256 says $expected"
    if ($script:failed) { Stop-Fetch }

    # 3. Unpack the three layers: xar, then the gzip Payload of the clients package, then the cpio archive.
    $xarDir = Join-Path $work 'xar'
    $gzDir = Join-Path $work 'gz'
    $cpioDir = Join-Path $work 'cpio'
    foreach ($d in @($xarDir, $gzDir, $cpioDir)) { if (Test-Path $d) { Remove-Item -Recurse -Force $d } }
    $rc = Invoke-7z @('x', '-y', "-o$xarDir", $pkg)
    $payload = Join-Path $xarDir 'FoundationDB-clients.pkg\Payload'
    Gate "$a xar layer" (($rc -eq 0) -and (Test-Path $payload)) "7z exit $rc; $payload"
    if ($script:failed) { Stop-Fetch }
    $rc = Invoke-7z @('x', '-y', "-o$gzDir", $payload)
    $cpio = Join-Path $gzDir 'Payload~'
    Gate "$a gzip layer" (($rc -eq 0) -and (Test-Path $cpio)) "7z exit $rc; $cpio"
    if ($script:failed) { Stop-Fetch }
    $rc = Invoke-7z @('x', '-y', "-o$cpioDir", $cpio)
    $dylib = Join-Path $cpioDir 'usr\local\lib\libfdb_c.dylib'
    $cli = Join-Path $cpioDir 'usr\local\bin\fdbcli'
    Gate "$a cpio layer" (($rc -eq 0) -and (Test-Path $dylib) -and (Test-Path $cli)) "7z exit $rc; $dylib, $cli"
    if ($script:failed) { Stop-Fetch }

    # 4. Both files are Mach-O 64-bit (magic cf fa ed fe, MH_MAGIC_64 in little-endian order).
    foreach ($f in @($dylib, $cli)) {
        $hex = Get-Magic $f
        Gate "$a Mach-O $(Split-Path -Leaf $f)" ($hex -eq 'cffaedfe') "magic $hex, $((Get-Item $f).Length.ToString('N0')) bytes"
    }
    if ($script:failed) { Stop-Fetch }

    # 5. Place the files next to the Windows artifacts, named with the architecture, with their .sha256
    # (lowercase hex, two spaces, name).
    foreach ($pair in @(@($dylib, "libfdb_c.$a.dylib"), @($cli, "fdbcli.$a"))) {
        $target = Join-Path $ArtifactDir $pair[1]
        Copy-Item $pair[0] $target -Force
        $hash = (Get-FileHash -Algorithm SHA256 $target).Hash.ToLowerInvariant()
        [System.IO.File]::WriteAllText("$target.sha256", "$hash  $($pair[1])`n", [System.Text.Encoding]::ASCII)
        Write-Host ("{0,-24} {1,12:N0} bytes  {2}" -f $pair[1], (Get-Item $target).Length, $hash)
    }
}
if (-not $KeepWork) { Remove-Item -Recurse -Force $WorkDir -ErrorAction SilentlyContinue }
Write-Host "macOS client files ($($archs -join ', ')) in $ArtifactDir, from the upstream $Tag packages" -ForegroundColor Green
exit 0
