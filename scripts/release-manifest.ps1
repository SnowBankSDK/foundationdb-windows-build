# Checks a published GitHub release of this repository against the local artifacts and writes the
# manifest snippet for the FoundationDB.Client.Native package.
#
# A release carries six binaries and a .sha256 file for each: fdb_c.dll and fdbcli.exe (win-x64),
# libfdb_c.arm64.dylib and fdbcli.arm64 (osx-arm64), libfdb_c.x86_64.dylib and fdbcli.x86_64 (osx-x64).
# Gates, each printed PASS or FAIL: the local files and their .sha256 files agree; gh is authenticated;
# the release exists and is not a draft; the assets are uploaded; each downloaded binary hashes to the
# local .sha256; the uploaded .sha256 files carry the same hashes. Then it writes manifest-snippet.json:
# the objects of a manifest.json entry for the selected runtime identifiers, with the release asset URLs
# and the verified checksums. In the manifest the file name stays the on-disk name the loader expects
# (libfdb_c.dylib, fdbcli); only the url points at the architecture-suffixed asset. Exit 0 only when
# every gate passes.
#
# Usage:
#   .\scripts\release-manifest.ps1 -Tag 7.4.7
#   .\scripts\release-manifest.ps1 -Tag 7.4.4 -ArtifactDir C:\drops\7.4.4 -Rids win-x64    # a read-only check of an older release
#
# Needs the GitHub CLI (gh) logged in to an account that can read the repository. Read-only: it never
# creates or edits a release. Windows PowerShell 5.1 or PowerShell 7.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $Tag,
    [string] $ArtifactDir = '',
    [string] $Repo = 'SnowBankSDK/foundationdb-windows-build',
    [string[]] $Rids = @('win-x64', 'osx-arm64', 'osx-x64'),
    [string] $OutFile = '',
    [string] $DownloadDir = '',
    [switch] $KeepDownloads
)

$ErrorActionPreference = 'Continue'
$repoRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrEmpty($ArtifactDir)) { $ArtifactDir = Join-Path $repoRoot "artifacts\$Tag" }
if ([string]::IsNullOrEmpty($OutFile)) { $OutFile = Join-Path $ArtifactDir 'manifest-snippet.json' }
if ([string]::IsNullOrEmpty($DownloadDir)) { $DownloadDir = Join-Path $ArtifactDir 'release-check' }
# Asset = the file name in the artifact directory and in the release; Name = the name in manifest.json
$all = @(
    @{ Asset = 'fdb_c.dll'; Name = 'fdb_c.dll'; Rid = 'win-x64' },
    @{ Asset = 'fdbcli.exe'; Name = 'fdbcli.exe'; Rid = 'win-x64' },
    @{ Asset = 'libfdb_c.arm64.dylib'; Name = 'libfdb_c.dylib'; Rid = 'osx-arm64' },
    @{ Asset = 'fdbcli.arm64'; Name = 'fdbcli'; Rid = 'osx-arm64' },
    @{ Asset = 'libfdb_c.x86_64.dylib'; Name = 'libfdb_c.dylib'; Rid = 'osx-x64' },
    @{ Asset = 'fdbcli.x86_64'; Name = 'fdbcli'; Rid = 'osx-x64' }
)
$binaries = @($all | Where-Object { $Rids -contains $_.Rid })
if ($binaries.Count -eq 0) { Write-Host "no known runtime identifier in -Rids ($($Rids -join ', '))" -ForegroundColor Red; exit 1 }
$script:failed = $false
function Gate([string] $Name, [bool] $Ok, [string] $Detail) {
    $status = 'PASS'
    if (-not $Ok) { $status = 'FAIL'; $script:failed = $true }
    Write-Host ("{0,-4} {1,-36} {2}" -f $status, $Name, $Detail) -ForegroundColor $(if ($Ok) { 'Green' } else { 'Red' })
}
function Read-Sha256File([string] $Path) {
    if (-not (Test-Path $Path)) { return $null }
    return ((Get-Content $Path -Raw) -split '\s+')[0].ToLowerInvariant()
}
function Stop-Check() { Write-Host 'RELEASE CHECK FAILED' -ForegroundColor Red; exit 1 }

# 1. Local files and their .sha256 files.
$local = @{}
foreach ($b in $binaries) {
    $file = Join-Path $ArtifactDir $b.Asset
    if (-not (Test-Path $file)) { Gate "local $($b.Asset)" $false "missing $file (Windows: build-fdb.ps1; macOS: fetch-macos-client.ps1)"; continue }
    $actual = (Get-FileHash -Algorithm SHA256 $file).Hash.ToLowerInvariant()
    $recorded = Read-Sha256File "$file.sha256"
    $local[$b.Asset] = $actual
    Gate "local $($b.Asset)" ($recorded -eq $actual) "$actual ($((Get-Item $file).Length.ToString('N0')) bytes); .sha256 says $recorded"
}
if ($script:failed) { Stop-Check }

# 2. gh, authenticated.
$gh = Get-Command gh -ErrorAction SilentlyContinue
if ($null -eq $gh) { Gate 'gh' $false 'GitHub CLI not on PATH (https://cli.github.com)' }
else {
    & gh auth status 2>&1 | Out-Null
    Gate 'gh' ($LASTEXITCODE -eq 0) "$($gh.Source); auth status exit $LASTEXITCODE (run 'gh auth login' on a failure)"
}
if ($script:failed) { Stop-Check }

# 3. The release and its assets.
$json = (& gh release view $Tag --repo $Repo --json tagName,url,isDraft,assets 2>&1 | ForEach-Object { if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.Exception.Message } else { "$_" } } | Out-String)
if ($LASTEXITCODE -ne 0) {
    Gate "release $Tag" $false "not found on $Repo (the maintainer creates it and uploads the assets first): $($json.Trim())"
    Stop-Check
}
$release = $json | ConvertFrom-Json
Gate "release $Tag" (-not $release.isDraft) "$($release.url); draft = $($release.isDraft) (a draft's asset URLs do not resolve for consumers)"
$assets = @{}
foreach ($a in $release.assets) { $assets[$a.name] = $a }
foreach ($b in $binaries) {
    foreach ($asset in @($b.Asset, "$($b.Asset).sha256")) {
        $present = $assets.ContainsKey($asset)
        $detail = if ($present) { "$($assets[$asset].size.ToString('N0')) bytes, $($assets[$asset].url)" } else { 'not uploaded' }
        Gate "asset $asset" $present $detail
    }
}
if ($script:failed) { Stop-Check }

# 4. Download every asset and compare with the local files.
New-Item -ItemType Directory -Force -Path $DownloadDir | Out-Null
$verified = @{}
foreach ($b in $binaries) {
    foreach ($asset in @($b.Asset, "$($b.Asset).sha256")) {
        $target = Join-Path $DownloadDir $asset
        Remove-Item $target -ErrorAction SilentlyContinue
        & gh release download $Tag --repo $Repo --pattern $asset --dir $DownloadDir --clobber 2>&1 | Out-Null
        if (-not (Test-Path $target)) { Gate "download $asset" $false 'gh release download produced no file'; continue }
        if ($asset -eq $b.Asset) {
            $hash = (Get-FileHash -Algorithm SHA256 $target).Hash.ToLowerInvariant()
            $ok = ($hash -eq $local[$b.Asset])
            if ($ok) { $verified[$b.Asset] = $hash }
            Gate "download $asset" $ok "$hash ($((Get-Item $target).Length.ToString('N0')) bytes); local $($local[$b.Asset])"
        } else {
            $uploaded = Read-Sha256File $target
            Gate "download $asset" ($uploaded -eq $local[$b.Asset]) "uploaded file says $uploaded; local $($local[$b.Asset])"
        }
    }
}
if (-not $KeepDownloads) { Remove-Item -Recurse -Force $DownloadDir -ErrorAction SilentlyContinue }
if ($script:failed) { Stop-Check }

# 5. The manifest snippet: the objects of the <Tag> entry that come from this repository's release,
# tab-indented like manifest.json. The URLs are the release asset URLs as GitHub reports them.
$objects = foreach ($b in $binaries) {
    @(
        "`t`t`t`t{",
        "`t`t`t`t`t`"name`": `"$($b.Name)`",",
        "`t`t`t`t`t`"rid`": `"$($b.Rid)`",",
        "`t`t`t`t`t`"url`": `"$($assets[$b.Asset].url)`",",
        "`t`t`t`t`t`"checksum`": `"$($verified[$b.Asset])`"",
        "`t`t`t`t}"
    ) -join "`n"
}
$snippet = "[`n" + ($objects -join ",`n") + "`n]`n"
[System.IO.File]::WriteAllText($OutFile, $snippet, [System.Text.Encoding]::ASCII)
Write-Host ''
Write-Host $snippet
Write-Host "manifest snippet written to $OutFile (paste the objects into the `"$Tag`" entry of FoundationDB.Client.Native/manifest.json; the linux-x64 and linux-arm64 objects come from the upstream release)" -ForegroundColor Green
Write-Host 'RELEASE CHECK PASSED' -ForegroundColor Green
exit 0
