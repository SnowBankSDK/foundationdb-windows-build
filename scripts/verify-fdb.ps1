# Verifies a built fdb_c.dll and fdbcli.exe: export set, version and protocol, checksum files, and an
# optional smoke test against a foundationdb/foundationdb:<Tag> container when Docker is running.
#
# Usage:
#   .\scripts\verify-fdb.ps1 -ArtifactDir .\artifacts\7.4.7
#   .\scripts\verify-fdb.ps1 -ArtifactDir .\artifacts\7.3.78 -NoDocker
#
# Exit code 0 when every gate passes, 1 otherwise. Windows PowerShell 5.1 or PowerShell 7.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $ArtifactDir,
    [string] $Tag = '',
    [string] $VsPath = '',
    [string] $DockerImage = '',
    [int] $DockerPort = 0,
    [switch] $NoDocker
)

$ErrorActionPreference = 'Continue'
$repo = Split-Path -Parent $PSScriptRoot
$script:failed = $false
function Format-Line($Item) {
    # a native command's stderr arrives as ErrorRecord objects whose ToString() is the exception type name
    if ($Item -is [System.Management.Automation.ErrorRecord]) { return $Item.Exception.Message }
    return [string] $Item
}
function Gate([string] $Name, [bool] $Ok, [string] $Detail) {
    $status = 'PASS'
    if (-not $Ok) { $status = 'FAIL'; $script:failed = $true }
    Write-Host ("{0,-4} {1,-22} {2}" -f $status, $Name, $Detail) -ForegroundColor $(if ($Ok) { 'Green' } else { 'Red' })
}

$dll = Join-Path $ArtifactDir 'fdb_c.dll'
$cli = Join-Path $ArtifactDir 'fdbcli.exe'
foreach ($f in @($dll, $cli)) { if (-not (Test-Path $f)) { Write-Host "missing $f" -ForegroundColor Red; exit 1 } }

# 1. fdbcli --version: version, source commit, protocol.
$versionOut = @(& $cli --version 2>&1 | ForEach-Object { Format-Line $_ })
$cliVersion = ''; $protocol = ''; $source = ''
foreach ($l in $versionOut) {
    if ($l -match '\(v(\d+\.\d+\.\d+)\)') { $cliVersion = $Matches[1] }
    if ($l -match '^protocol\s+([0-9a-f]+)') { $protocol = $Matches[1] }
    if ($l -match '^source version\s+([0-9a-f]+)') { $source = $Matches[1] }
}
if ([string]::IsNullOrEmpty($Tag)) { $Tag = $cliVersion }
$v = [version] $Tag
$line = "$($v.Major).$($v.Minor)"
$expectedProtocol = 'fdb00b0{0}{1}000000' -f $v.Major, $v.Minor
Gate 'fdbcli version' ($cliVersion -eq $Tag) "reported v$cliVersion, expected v$Tag (source $source)"
Gate 'protocol' ($protocol -eq $expectedProtocol) "reported $protocol, expected $expectedProtocol"

# 2. Export set of fdb_c.dll against the reference list of the release line.
if ([string]::IsNullOrEmpty($VsPath)) {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (Test-Path $vswhere) { $VsPath = (& $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath | Select-Object -First 1) }
}
$dumpbin = $null
if (-not [string]::IsNullOrEmpty($VsPath)) {
    $dumpbin = Get-ChildItem (Join-Path $VsPath 'VC\Tools\MSVC') -Recurse -Filter dumpbin.exe -ErrorAction SilentlyContinue | Where-Object { $_.FullName -match '\\Hostx64\\x64\\' } | Select-Object -First 1
}
if ($null -eq $dumpbin) {
    Gate 'exports' $false 'dumpbin.exe not found (Visual Studio with the C++ workload); pass -VsPath'
} else {
    $names = @(& $dumpbin.FullName /exports $dll | ForEach-Object {
        $parts = ($_.Trim() -split '\s+')
        if ($parts.Count -ge 4 -and $parts[0] -match '^\d+$' -and $parts[2] -match '^[0-9A-Fa-f]{8}$') { $parts[3] }
    } | Sort-Object)
    $referencePath = Join-Path $repo "reference\exports-$line.txt"
    if (-not (Test-Path $referencePath)) {
        Gate 'exports' $false "no reference list for line $line ($referencePath); $($names.Count) exports found"
    } else {
        $reference = @(Get-Content $referencePath | Where-Object { $_.Trim().Length -gt 0 } | ForEach-Object { $_.Trim() } | Sort-Object)
        $diff = @(Compare-Object -ReferenceObject $reference -DifferenceObject $names)
        $foreign = @($names | Where-Object { $_ -notlike 'fdb_*' })
        $detail = "$($names.Count) exports, reference $($reference.Count)"
        if ($diff.Count -gt 0) { $detail += '; ' + (($diff | ForEach-Object { "$($_.SideIndicator) $($_.InputObject)" }) -join ', ') }
        if ($foreign.Count -gt 0) { $detail += '; non-fdb_ exports: ' + ($foreign -join ', ') }
        Gate 'exports' (($diff.Count -eq 0) -and ($foreign.Count -eq 0)) $detail
    }
}

# 3. Checksum files next to the artifacts.
foreach ($f in @($dll, $cli)) {
    $name = Split-Path -Leaf $f
    $shaFile = "$f.sha256"
    if (-not (Test-Path $shaFile)) { Gate "sha256 $name" $false 'no .sha256 file'; continue }
    $recorded = ((Get-Content $shaFile -Raw) -split '\s+')[0].ToLowerInvariant()
    $actual = (Get-FileHash -Algorithm SHA256 $f).Hash.ToLowerInvariant()
    Gate "sha256 $name" ($recorded -eq $actual) "$actual ($((Get-Item $f).Length.ToString('N0')) bytes)"
}

# 4. Smoke test against a live cluster (optional).
if ($NoDocker) {
    Write-Host 'SKIP smoke test          -NoDocker given'
} else {
    $dockerOk = $false
    if (Get-Command docker -ErrorAction SilentlyContinue) { & docker info 2>$null | Out-Null; $dockerOk = ($LASTEXITCODE -eq 0) }
    if (-not $dockerOk) {
        Write-Host 'SKIP smoke test          Docker is not running (start Docker Desktop to run it)'
    } else {
        if ([string]::IsNullOrEmpty($DockerImage)) { $DockerImage = "foundationdb/foundationdb:$Tag" }
        if ($DockerPort -le 0) { $DockerPort = 4600 + (Get-Random -Maximum 100) }
        $name = "fdb-verify-$DockerPort"
        $clusterFile = Join-Path $ArtifactDir 'verify.cluster'
        & docker rm -f $name 2>$null | Out-Null
        & docker pull -q $DockerImage 2>&1 | Out-Null
        $id = (& docker run --detach --name $name --publish "127.0.0.1:${DockerPort}:${DockerPort}" --env FDB_NETWORKING_MODE=host --env FDB_PORT=$DockerPort --env FDB_COORDINATOR_PORT=$DockerPort $DockerImage 2>&1)
        if ($LASTEXITCODE -ne 0) {
            Gate 'smoke test' $false "docker run failed for ${DockerImage}: $id"
        } else {
            $joined = $false
            for ($i = 0; $i -lt 60 -and -not $joined; $i++) {
                Start-Sleep -Seconds 1
                $logs = (& docker logs $name 2>&1 | Out-String)
                if ($logs -match 'FDBD joined cluster') { $joined = $true }
            }
            if (-not $joined) {
                Gate 'smoke test' $false "$DockerImage did not join its cluster within 60 s"
            } else {
                $cluster = (& docker exec $name cat /var/fdb/fdb.cluster).Trim()
                [System.IO.File]::WriteAllText($clusterFile, "$cluster`n", [System.Text.Encoding]::ASCII)
                $configure = (& $cli -C $clusterFile --exec 'configure new single memory' --timeout 30 2>&1 | Out-String)
                $status = (& $cli -C $clusterFile --exec 'status minimal' --timeout 30 2>&1 | Out-String)
                $roundTrip = (& $cli -C $clusterFile --exec 'writemode on; set verify_key verify_value; get verify_key' --timeout 30 2>&1 | Out-String)
                # fdbcli prints `verify_key' is `verify_value' (backtick, then a straight quote)
                $ok = ($status -match 'available') -and ($roundTrip -match "verify_key' is .verify_value'")
                Gate 'smoke test' $ok ("$DockerImage on 127.0.0.1:${DockerPort}: " + $configure.Trim() + '; ' + $status.Trim() + '; ' + ($roundTrip.Trim() -replace '\s+', ' '))
            }
            & docker rm -f $name 2>$null | Out-Null
            Remove-Item $clusterFile -ErrorAction SilentlyContinue
        }
    }
}

if ($script:failed) { Write-Host 'VERIFY FAILED' -ForegroundColor Red; exit 1 }
Write-Host 'VERIFY PASSED' -ForegroundColor Green
exit 0
