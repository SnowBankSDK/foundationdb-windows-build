# Builds fdb_c.dll and fdbcli.exe for one upstream FoundationDB tag on Windows.
#
# Steps: clone apple/foundationdb at the tag, apply the branch patch from patches\ (7.3 or 7.4 by tag)
# plus the extra patches that still apply, add vcpkg.json, configure with CMake (Visual Studio 2022,
# ClangCL toolset, vcpkg manifest for zlib and lz4), build the actor compiler with dotnet, build the
# fdb_c and fdbcli targets, copy the artifacts and write their .sha256 files.
#
# Usage (foreground):
#   .\scripts\build-fdb.ps1 -Tag 7.4.7
# Usage (detached, survives the calling session; the log is the only output):
#   Start-Process powershell -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','.\scripts\build-fdb.ps1','-Tag','7.4.7' -WindowStyle Hidden
#   Get-Content C:\fdb-build\7.4.7\build-7.4.7.log -Wait
#
# Defaults: sources under C:\fdb-build\<Tag>\foundationdb, artifacts under <repo>\artifacts\<Tag>,
# Boost at C:\boost_1_86_0, OpenSSL at C:\Program Files\OpenSSL-Win64, Visual Studio found by vswhere.
# Windows PowerShell 5.1 or PowerShell 7.
[CmdletBinding()]
param(
    [Parameter(Mandatory = $true)] [string] $Tag,
    [string] $WorkRoot = 'C:\fdb-build',
    [string] $SourceDir = '',
    [string] $OutputDir = '',
    [string] $LogFile = '',
    [string] $BoostRoot = 'C:\boost_1_86_0',
    [string] $OpenSslRoot = 'C:\Program Files\OpenSSL-Win64',
    [string] $VsPath = '',
    [string] $Upstream = 'https://github.com/apple/foundationdb.git',
    [string] $ReferenceClone = '',
    [int] $Jobs = 0,
    [switch] $SkipClone,
    [switch] $Rebuild
)

$ErrorActionPreference = 'Continue'
$repo = Split-Path -Parent $PSScriptRoot
$version = [version] $Tag
$line = "$($version.Major).$($version.Minor)"
$tagRoot = Join-Path $WorkRoot $Tag
if ([string]::IsNullOrEmpty($SourceDir)) { $SourceDir = Join-Path $tagRoot 'foundationdb' }
if ([string]::IsNullOrEmpty($OutputDir)) { $OutputDir = Join-Path $repo "artifacts\$Tag" }
if ([string]::IsNullOrEmpty($LogFile)) { $LogFile = Join-Path $tagRoot "build-$Tag.log" }
$buildDir = Join-Path $SourceDir 'build'

New-Item -ItemType Directory -Force -Path $tagRoot, $OutputDir | Out-Null
Start-Transcript -Path $LogFile -Append | Out-Null

$clock = [System.Diagnostics.Stopwatch]::StartNew()
$timings = [ordered] @{}
function Format-Line($Item) {
    # a native command's stderr arrives as ErrorRecord objects whose ToString() is the exception type name
    if ($Item -is [System.Management.Automation.ErrorRecord]) { return $Item.Exception.Message }
    return [string] $Item
}
function Write-Phase([string] $Name) {
    Write-Host ("[{0}] [{1:hh\:mm\:ss}] === {2} ===" -f (Get-Date -Format 'HH:mm:ss'), $clock.Elapsed, $Name) -ForegroundColor Cyan
}
function Stop-Build([string] $Message) {
    Write-Host "BUILD FAILED: $Message" -ForegroundColor Red
    Stop-Transcript | Out-Null
    exit 1
}
function Invoke-Logged([string] $Name, [string] $Exe, [string[]] $Arguments, [string] $WorkingDirectory) {
    # Long native steps (dotnet, MSBuild through cmake --build) run as a child process with stdout and
    # stderr redirected to their own file, so progress is readable while the step runs; the transcript
    # gets the path and the last lines. MSBuild buffers its output when piped inside PowerShell.
    $stepLog = Join-Path $tagRoot "$Name.log"
    $stepErr = Join-Path $tagRoot "$Name.err"
    Write-Host "step log : $stepLog"
    $proc = Start-Process -FilePath $Exe -ArgumentList $Arguments -WorkingDirectory $WorkingDirectory -NoNewWindow -Wait -PassThru -RedirectStandardOutput $stepLog -RedirectStandardError $stepErr
    Get-Content $stepLog -Tail 12 -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "  $_" }
    if ($proc.ExitCode -ne 0) {
        Get-Content $stepLog -ErrorAction SilentlyContinue | Where-Object { $_ -match ': error |error C[0-9]|error LNK|fatal error|CMake Error|error MSB' } | Select-Object -First 20 | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
        Get-Content $stepErr -Tail 10 -ErrorAction SilentlyContinue | ForEach-Object { Write-Host "  $_" -ForegroundColor Red }
    }
    return $proc.ExitCode
}
function Invoke-Git([string[]] $GitArgs) {
    # git writes progress to stderr; fold both streams into plain lines so the transcript stays readable.
    # The lines go to the host, not to the pipeline: the only output of this function is the exit code.
    & git @GitArgs 2>&1 | ForEach-Object { Write-Host (Format-Line $_) }
    return $LASTEXITCODE
}

try {
    Write-Phase "build-fdb $Tag (line $line)"
    Write-Host "source   : $SourceDir"
    Write-Host "output   : $OutputDir"
    Write-Host "log      : $LogFile"
    Write-Host "boost    : $BoostRoot"
    Write-Host "openssl  : $OpenSslRoot"

    # Patch and flags by release line.
    switch ($line) {
        '7.3' { $patchName = 'windows-7.3.52.patch'; $cxxFlags = '/DWIN32 /D_WINDOWS /Zc:__cplusplus' }
        '7.4' { $patchName = 'windows-7.4.7.patch'; $cxxFlags = '/Zc:__cplusplus' }
        default { Stop-Build "no patch for release line $line (patches\ covers 7.3 and 7.4)" }
    }
    $patchPath = Join-Path $repo "patches\$patchName"
    if (-not (Test-Path $patchPath)) { Stop-Build "patch not found: $patchPath" }

    # Visual Studio developer environment (clang-cl, lld-link, MSBuild, the Windows SDK, vcpkg).
    Write-Phase 'toolchain'
    if ([string]::IsNullOrEmpty($VsPath)) {
        $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
        if (-not (Test-Path $vswhere)) { Stop-Build "vswhere not found at $vswhere; pass -VsPath" }
        $VsPath = (& $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Llvm.ClangToolset -property installationPath | Select-Object -First 1)
        if ([string]::IsNullOrEmpty($VsPath)) { Stop-Build 'no Visual Studio instance with the ClangCL toolset; run scripts\check-prereqs.ps1' }
    }
    Import-Module (Join-Path $VsPath 'Common7\Tools\Microsoft.VisualStudio.DevShell.dll')
    Enter-VsDevShell -VsInstallPath $VsPath -SkipAutomaticLocation -DevCmdArguments '-arch=x64 -host_arch=x64' | Out-Null
    $env:VCPKG_ROOT = Join-Path $VsPath 'VC\vcpkg'
    $clangVersion = (& (Join-Path $VsPath 'VC\Tools\Llvm\x64\bin\clang-cl.exe') --version | Select-Object -First 1)
    $cmakeVersion = (& cmake --version | Select-Object -First 1)
    Write-Host "vs       : $VsPath"
    Write-Host "clang    : $clangVersion"
    Write-Host "cmake    : $cmakeVersion"
    Write-Host "vcpkg    : $env:VCPKG_ROOT"

    # Sources at the tag.
    Write-Phase "sources at tag $Tag"
    if (-not (Test-Path (Join-Path $SourceDir '.git'))) {
        if ($SkipClone) { Stop-Build "-SkipClone given but $SourceDir is not a git checkout" }
        $cloneArgs = @('clone')
        if (-not [string]::IsNullOrEmpty($ReferenceClone)) { $cloneArgs += @('--reference-if-able', $ReferenceClone, '--dissociate') }
        $cloneArgs += @($Upstream, $SourceDir)
        if ((Invoke-Git $cloneArgs) -ne 0) { Stop-Build 'git clone failed' }
    }
    if (-not $SkipClone) {
        $dirty = @(& git -C $SourceDir status --porcelain)
        if ($dirty.Count -gt 0) { Stop-Build "$SourceDir has local changes (a previous run?). Remove the directory, or pass -SkipClone to build it as it is." }
        if ((Invoke-Git @('-C', $SourceDir, 'fetch', '--quiet', '--tags', 'origin')) -ne 0) { Stop-Build 'git fetch failed' }
        if ((Invoke-Git @('-C', $SourceDir, 'checkout', '--quiet', $Tag)) -ne 0) { Stop-Build "git checkout $Tag failed" }
    }
    $commit = (& git -C $SourceDir rev-parse HEAD)
    $describe = (& git -C $SourceDir describe --tags --always)
    Write-Host "commit   : $commit ($describe)"
    $expected = (& git -C $SourceDir rev-parse "$Tag^{commit}" 2>$null)
    if (-not $SkipClone -and $expected -ne $commit) { Stop-Build "HEAD $commit is not the commit of tag $Tag ($expected)" }

    # Patches. The branch patch carries the tag's VERSION in its CMakeLists.txt context, so the
    # version is rewritten to the requested tag before the check. Extra patches apply when they can.
    if (-not $SkipClone) {
        Write-Phase "patch $patchName"
        $patchText = [System.IO.File]::ReadAllText($patchPath)
        $patchText = [regex]::Replace($patchText, 'VERSION \d+\.\d+\.\d+', "VERSION $Tag")
        $tempPatch = Join-Path $tagRoot "windows-$Tag.patch"
        [System.IO.File]::WriteAllText($tempPatch, $patchText)
        $check = @(& git -C $SourceDir apply --check --verbose $tempPatch 2>&1 | ForEach-Object { Format-Line $_ })
        if ($LASTEXITCODE -ne 0) {
            $check | Where-Object { $_ -notmatch '^Checking patch' } | ForEach-Object { Write-Host $_ }
            Stop-Build "the patch does not apply to $Tag. Port the failing hunks by hand (see CLAUDE.md, 'A hunk fails on a new tag'), then rerun with -SkipClone."
        }
        $check | Where-Object { $_ -match 'offset' } | ForEach-Object { Write-Host "  $_" }
        & git -C $SourceDir apply $tempPatch 2>&1 | ForEach-Object { Format-Line $_ } | Where-Object { $_ -notmatch 'whitespace' } | ForEach-Object { Write-Host $_ }
        if ($LASTEXITCODE -ne 0) { Stop-Build 'git apply failed after a clean check' }
        Write-Host "applied  : $patchName (VERSION rewritten to $Tag)"

        foreach ($extra in @(Get-ChildItem (Join-Path $repo 'patches\extra') -Filter '*.patch' -ErrorAction SilentlyContinue | Sort-Object Name)) {
            & git -C $SourceDir apply --check $extra.FullName 2>&1 | Out-Null
            if ($LASTEXITCODE -eq 0) {
                & git -C $SourceDir apply $extra.FullName 2>&1 | Out-Null
                Write-Host "applied  : extra\$($extra.Name)"
            } else {
                Write-Host "skipped  : extra\$($extra.Name) (does not apply: already present in the branch patch, or not needed by this tag)"
            }
        }

        # The branch patch pins Boost at C:/boost_1_86_0; point it at the requested root.
        $boostForward = ($BoostRoot -replace '\\', '/').TrimEnd('/')
        if ($boostForward -ne 'C:/boost_1_86_0') {
            $cmakeLists = Join-Path $SourceDir 'CMakeLists.txt'
            $text = [System.IO.File]::ReadAllText($cmakeLists)
            if ($text -notmatch [regex]::Escape('set(BOOST_ROOT "C:/boost_1_86_0")')) { Stop-Build 'BOOST_ROOT line not found in the patched CMakeLists.txt' }
            [System.IO.File]::WriteAllText($cmakeLists, $text.Replace('set(BOOST_ROOT "C:/boost_1_86_0")', "set(BOOST_ROOT `"$boostForward`")"))
            Write-Host "boost    : BOOST_ROOT rewritten to $boostForward"
        }
        Copy-Item (Join-Path $repo 'patches\vcpkg.json') (Join-Path $SourceDir 'vcpkg.json') -Force
        Write-Host 'applied  : vcpkg.json'
    }

    # Configure.
    if ($Rebuild -and (Test-Path $buildDir)) { Remove-Item -Recurse -Force $buildDir }
    New-Item -ItemType Directory -Force -Path $buildDir | Out-Null
    Set-Location $buildDir
    Write-Phase 'configure'
    $t = [System.Diagnostics.Stopwatch]::StartNew()
    & cmake .. -G 'Visual Studio 17 2022' -A x64 -T ClangCL `
        -DCMAKE_BUILD_TYPE=Release `
        -DCMAKE_TOOLCHAIN_FILE="$env:VCPKG_ROOT\scripts\buildsystems\vcpkg.cmake" `
        -DVCPKG_TARGET_TRIPLET=x64-windows `
        -DPython3_EXECUTABLE='python.exe' `
        -DOPENSSL_ROOT_DIR="$OpenSslRoot" `
        -DCMAKE_CXX_STANDARD=20 -DCMAKE_CXX_STANDARD_REQUIRED=ON -DCMAKE_CXX_EXTENSIONS=OFF `
        -DCMAKE_CXX_FLAGS="$cxxFlags" -DCMAKE_REQUIRED_FLAGS='/std:c++20' `
        -DCMAKE_TRY_COMPILE_TARGET_TYPE=STATIC_LIBRARY 2>&1 | ForEach-Object { Format-Line $_ }
    if ($LASTEXITCODE -ne 0) { Stop-Build "configure failed ($LASTEXITCODE)" }
    $timings['configure'] = $t.Elapsed

    # The CMake actorcompiler_build target never runs dotnet under MSBuild, so the actor compiler is
    # built by hand into the build root, where every actor-compile rule expects build\actorcompiler.exe.
    Write-Phase 'actor compiler (dotnet build)'
    $t = [System.Diagnostics.Stopwatch]::StartNew()
    # No node reuse and no shared compiler: Invoke-Logged waits for the process and its descendants, and the
    # MSBuild worker nodes and VBCSCompiler that a dotnet build leaves behind for reuse would keep it waiting
    # for their idle timeout (15 minutes) after the build itself has finished.
    $rc = Invoke-Logged 'actorcompiler' 'dotnet' @('build', (Join-Path $SourceDir 'flow\actorcompiler\actorcompiler.csproj'), '-c', 'Release', '-nologo', '-v', 'q', '-nodeReuse:false', '-p:UseSharedCompilation=false', '-o', $buildDir) $buildDir
    if ($rc -ne 0) { Stop-Build "actor compiler build failed ($rc)" }
    if (-not (Test-Path (Join-Path $buildDir 'actorcompiler.exe'))) { Stop-Build 'actorcompiler.exe not produced' }
    $timings['actorcompiler'] = $t.Elapsed

    # the same node-reuse rule for the MSBuild runs under cmake --build
    $buildExtra = @('--', '/nodeReuse:false')
    if ($Jobs -gt 0) { $buildExtra += @("/m:$Jobs", "/p:CL_MPCount=$Jobs") }
    foreach ($target in @('fdb_c', 'fdbcli')) {
        Write-Phase "build $target"
        $t = [System.Diagnostics.Stopwatch]::StartNew()
        $rc = Invoke-Logged "build-$target" 'cmake' (@('--build', '.', '--config', 'Release', '--target', $target) + $buildExtra) $buildDir
        if ($rc -ne 0) { Stop-Build "$target failed ($rc)" }
        $timings[$target] = $t.Elapsed
    }

    # Artifacts and checksums (lowercase hex, two spaces, the sha256sum text format).
    Write-Phase 'artifacts'
    $dll = Join-Path $buildDir 'lib\Release\fdb_c.dll'
    $cli = Join-Path $buildDir 'bin\Release\fdbcli.exe'
    foreach ($f in @($dll, $cli)) { if (-not (Test-Path $f)) { Stop-Build "missing artifact $f" } }
    $info = @()
    $info += "tag: $Tag"
    $info += "commit: $commit ($describe)"
    $info += "clang: $clangVersion"
    $info += "cmake: $cmakeVersion"
    $info += "boost: $BoostRoot"
    $info += "patch: $patchName"
    $info += "built: $(Get-Date -Format 'yyyy-MM-dd HH:mm:ss') on $env:COMPUTERNAME ($env:NUMBER_OF_PROCESSORS threads)"
    foreach ($f in @($dll, $cli)) {
        $name = Split-Path -Leaf $f
        Copy-Item $f (Join-Path $OutputDir $name) -Force
        $hash = (Get-FileHash -Algorithm SHA256 $f).Hash.ToLowerInvariant()
        [System.IO.File]::WriteAllText((Join-Path $OutputDir "$name.sha256"), "$hash  $name`n", [System.Text.Encoding]::ASCII)
        $size = (Get-Item $f).Length
        $info += ("{0}: {1} bytes, sha256 {2}" -f $name, $size, $hash)
        Write-Host ("{0,-12} {1,12:N0} bytes  {2}" -f $name, $size, $hash)
    }
    foreach ($k in $timings.Keys) { $info += ("time {0}: {1:hh\:mm\:ss}" -f $k, $timings[$k]) }
    [System.IO.File]::WriteAllLines((Join-Path $OutputDir 'build-info.txt'), [string[]] $info)
    foreach ($k in $timings.Keys) { Write-Host ("{0,-14} {1:hh\:mm\:ss}" -f $k, $timings[$k]) }
    Write-Host "artifacts in $OutputDir" -ForegroundColor Green
    Write-Phase "done in $($clock.Elapsed.ToString('hh\:mm\:ss'))"
}
finally {
    Stop-Transcript | Out-Null
}
exit 0
