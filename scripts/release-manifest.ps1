# Checks a published GitHub release of this repository against the local artifacts and writes the
# manifest snippet for the FoundationDB.Client.Native package.
#
# Gates, each printed PASS or FAIL: the local artifacts and their .sha256 files agree; gh is
# authenticated; the release exists and is not a draft; the four Windows assets are uploaded; each
# downloaded asset hashes to the local .sha256; the uploaded .sha256 files carry the same hashes.
# Then it writes manifest-win-x64.json (the two win-x64 objects of a manifest.json entry) with the
# release asset URLs and the verified checksums. Exit 0 only when every gate passes.
#
# Usage:
#   .\scripts\release-manifest.ps1 -Tag 7.4.7
#   .\scripts\release-manifest.ps1 -Tag 7.4.4 -ArtifactDir C:\drops\7.4.4      # a read-only check of an existing release
#
# Needs the GitHub CLI (gh) logged in to an account that can read the repository. Read-only: it never
# creates or edits a release. Windows PowerShell 5.1 or PowerShell 7.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $Tag,
    [string] $ArtifactDir = '',
    [string] $Repo = 'SnowBankSDK/foundationdb-windows-build',
    [string] $OutFile = '',
    [string] $DownloadDir = '',
    [switch] $KeepDownloads
)

$ErrorActionPreference = 'Continue'
$repoRoot = Split-Path -Parent $PSScriptRoot
if ([string]::IsNullOrEmpty($ArtifactDir)) { $ArtifactDir = Join-Path $repoRoot "artifacts\$Tag" }
if ([string]::IsNullOrEmpty($OutFile)) { $OutFile = Join-Path $ArtifactDir 'manifest-win-x64.json' }
if ([string]::IsNullOrEmpty($DownloadDir)) { $DownloadDir = Join-Path $ArtifactDir 'release-check' }
$binaries = @('fdb_c.dll', 'fdbcli.exe')
$script:failed = $false
function Gate([string] $Name, [bool] $Ok, [string] $Detail) {
    $status = 'PASS'
    if (-not $Ok) { $status = 'FAIL'; $script:failed = $true }
    Write-Host ("{0,-4} {1,-30} {2}" -f $status, $Name, $Detail) -ForegroundColor $(if ($Ok) { 'Green' } else { 'Red' })
}
function Read-Sha256File([string] $Path) {
    if (-not (Test-Path $Path)) { return $null }
    return ((Get-Content $Path -Raw) -split '\s+')[0].ToLowerInvariant()
}

# 1. Local artifacts and their .sha256 files.
$local = @{}
foreach ($name in $binaries) {
    $file = Join-Path $ArtifactDir $name
    if (-not (Test-Path $file)) { Gate "local $name" $false "missing $file"; continue }
    $actual = (Get-FileHash -Algorithm SHA256 $file).Hash.ToLowerInvariant()
    $recorded = Read-Sha256File "$file.sha256"
    $local[$name] = $actual
    Gate "local $name" ($recorded -eq $actual) "$actual ($((Get-Item $file).Length.ToString('N0')) bytes); .sha256 says $recorded"
}
if ($script:failed) { Write-Host 'RELEASE CHECK FAILED' -ForegroundColor Red; exit 1 }

# 2. gh, authenticated.
$gh = Get-Command gh -ErrorAction SilentlyContinue
if ($null -eq $gh) { Gate 'gh' $false 'GitHub CLI not on PATH (https://cli.github.com)' }
else {
    & gh auth status 2>&1 | Out-Null
    Gate 'gh' ($LASTEXITCODE -eq 0) "$($gh.Source); auth status exit $LASTEXITCODE (run 'gh auth login' on a failure)"
}
if ($script:failed) { Write-Host 'RELEASE CHECK FAILED' -ForegroundColor Red; exit 1 }

# 3. The release and its assets.
$json = (& gh release view $Tag --repo $Repo --json tagName,url,isDraft,assets 2>&1 | ForEach-Object { if ($_ -is [System.Management.Automation.ErrorRecord]) { $_.Exception.Message } else { "$_" } } | Out-String)
if ($LASTEXITCODE -ne 0) {
    Gate "release $Tag" $false "not found on $Repo (the maintainer creates it and uploads the assets first): $($json.Trim())"
    Write-Host 'RELEASE CHECK FAILED' -ForegroundColor Red; exit 1
}
$release = $json | ConvertFrom-Json
Gate "release $Tag" (-not $release.isDraft) "$($release.url); draft = $($release.isDraft) (a draft's asset URLs do not resolve for consumers)"
$assets = @{}
foreach ($a in $release.assets) { $assets[$a.name] = $a }
foreach ($name in $binaries) {
    foreach ($asset in @($name, "$name.sha256")) {
        $present = $assets.ContainsKey($asset)
        $detail = if ($present) { "$($assets[$asset].size.ToString('N0')) bytes, $($assets[$asset].url)" } else { 'not uploaded' }
        Gate "asset $asset" $present $detail
    }
}
if ($script:failed) { Write-Host 'RELEASE CHECK FAILED' -ForegroundColor Red; exit 1 }

# 4. Download every asset and compare with the local artifacts.
New-Item -ItemType Directory -Force -Path $DownloadDir | Out-Null
$verified = @{}
foreach ($name in $binaries) {
    foreach ($asset in @($name, "$name.sha256")) {
        $target = Join-Path $DownloadDir $asset
        Remove-Item $target -ErrorAction SilentlyContinue
        & gh release download $Tag --repo $Repo --pattern $asset --dir $DownloadDir --clobber 2>&1 | Out-Null
        if (-not (Test-Path $target)) { Gate "download $asset" $false 'gh release download produced no file'; continue }
        if ($asset -eq $name) {
            $hash = (Get-FileHash -Algorithm SHA256 $target).Hash.ToLowerInvariant()
            $ok = ($hash -eq $local[$name])
            if ($ok) { $verified[$name] = $hash }
            Gate "download $asset" $ok "$hash ($((Get-Item $target).Length.ToString('N0')) bytes); local $($local[$name])"
        } else {
            $uploaded = Read-Sha256File $target
            Gate "download $asset" ($uploaded -eq $local[$name]) "uploaded file says $uploaded; local $($local[$name])"
        }
    }
}
if (-not $KeepDownloads) { Remove-Item -Recurse -Force $DownloadDir -ErrorAction SilentlyContinue }
if ($script:failed) { Write-Host 'RELEASE CHECK FAILED' -ForegroundColor Red; exit 1 }

# 5. The manifest snippet: the two win-x64 objects of the <Tag> entry of manifest.json, tab-indented
# like that file. The URLs are the release asset URLs as GitHub reports them.
$objects = foreach ($name in $binaries) {
    @(
        "`t`t`t`t{",
        "`t`t`t`t`t`"name`": `"$name`",",
        "`t`t`t`t`t`"rid`": `"win-x64`",",
        "`t`t`t`t`t`"url`": `"$($assets[$name].url)`",",
        "`t`t`t`t`t`"checksum`": `"$($verified[$name])`"",
        "`t`t`t`t}"
    ) -join "`n"
}
$snippet = "[`n" + ($objects -join ",`n") + "`n]`n"
[System.IO.File]::WriteAllText($OutFile, $snippet, [System.Text.Encoding]::ASCII)
Write-Host ''
Write-Host $snippet
Write-Host "manifest snippet written to $OutFile (paste the two objects into the `"$Tag`" entry of FoundationDB.Client.Native/manifest.json)" -ForegroundColor Green
Write-Host 'RELEASE CHECK PASSED' -ForegroundColor Green
exit 0
