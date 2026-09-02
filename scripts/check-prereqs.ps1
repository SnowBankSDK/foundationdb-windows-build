# Checks every prerequisite of the FoundationDB Windows client build and prints a pass/fail table.
# Exit code 0 when every check passes, 1 otherwise. Warnings do not fail the run.
#
# Usage:
#   .\scripts\check-prereqs.ps1
#   .\scripts\check-prereqs.ps1 -BoostRoot D:\boost_1_86_0 -OpenSslRoot 'D:\OpenSSL-Win64' -SourceDrive D
#
# Windows PowerShell 5.1 or PowerShell 7. Run it outside a Visual Studio developer shell: the script
# locates Visual Studio through vswhere on its own.
[CmdletBinding()]
param(
    [string] $BoostRoot = 'C:\boost_1_86_0',
    [string] $OpenSslRoot = 'C:\Program Files\OpenSSL-Win64',
    [string] $VsPath = '',
    [string] $SourceDrive = 'C',
    [int] $MinFreeGB = 40
)

$ErrorActionPreference = 'Continue'
$script:rows = @()
$script:failed = $false

function Add-Check {
    param([string] $Name, [bool] $Ok, [string] $Detail, [switch] $Warn)
    $status = 'PASS'
    if (-not $Ok) {
        if ($Warn) { $status = 'WARN' } else { $status = 'FAIL'; $script:failed = $true }
    }
    $script:rows += [pscustomobject]@{ Check = $Name; Status = $status; Detail = $Detail }
}

function Get-CommandVersion {
    param([string] $Exe, [string[]] $Arguments)
    try {
        $out = & $Exe @Arguments 2>&1 | Select-Object -First 3
        return ($out | Out-String).Trim()
    } catch {
        return $null
    }
}

# 1. Visual Studio with the C++ workload, the ClangCL toolset and vcpkg.
$vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
if (-not (Test-Path $vswhere)) {
    Add-Check 'vswhere' $false "not found at $vswhere (install Visual Studio 2022)"
} else {
    Add-Check 'vswhere' $true $vswhere
    if ([string]::IsNullOrEmpty($VsPath)) {
        $VsPath = (& $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Llvm.ClangToolset -property installationPath 2>$null | Select-Object -First 1)
    }
    if ([string]::IsNullOrEmpty($VsPath) -or -not (Test-Path $VsPath)) {
        Add-Check 'Visual Studio' $false 'no instance with the ClangCL toolset component (Microsoft.VisualStudio.Component.VC.Llvm.ClangToolset)'
    } else {
        $vsVersion = (& $vswhere -path $VsPath -property catalog_productDisplayVersion 2>$null | Select-Object -First 1)
        Add-Check 'Visual Studio' $true "$VsPath ($vsVersion)"
        foreach ($component in @(
            'Microsoft.VisualStudio.Workload.NativeDesktop',
            'Microsoft.VisualStudio.Component.VC.Llvm.Clang',
            'Microsoft.VisualStudio.Component.VC.Llvm.ClangToolset',
            'Microsoft.VisualStudio.Component.Vcpkg')) {
            $hit = (& $vswhere -path $VsPath -requires $component -property installationPath 2>$null | Select-Object -First 1)
            Add-Check "VS component $($component.Split('.')[-1])" (-not [string]::IsNullOrEmpty($hit)) $component
        }
    }
}

# 2. clang-cl and lld-link (the compiler and linker of the build).
$clangMajor = $null
if (-not [string]::IsNullOrEmpty($VsPath) -and (Test-Path $VsPath)) {
    $clangCl = Join-Path $VsPath 'VC\Tools\Llvm\x64\bin\clang-cl.exe'
    $lldLink = Join-Path $VsPath 'VC\Tools\Llvm\x64\bin\lld-link.exe'
    if (Test-Path $clangCl) {
        $v = Get-CommandVersion $clangCl @('--version')
        if ($v -match 'clang version (\d+)\.(\d+)\.(\d+)') {
            $clangMajor = [int] $Matches[1]
            Add-Check 'clang-cl' $true "$($Matches[0]) at $clangCl"
        } else {
            Add-Check 'clang-cl' $false "version not parsed: $v"
        }
    } else {
        Add-Check 'clang-cl' $false "not found at $clangCl"
    }
    Add-Check 'lld-link' (Test-Path $lldLink) $lldLink

    $msvcDirs = @(Get-ChildItem (Join-Path $VsPath 'VC\Tools\MSVC') -Directory -ErrorAction SilentlyContinue | Sort-Object Name)
    Add-Check 'MSVC toolset' ($msvcDirs.Count -gt 0) ("versions: " + (($msvcDirs | ForEach-Object Name) -join ', '))

    $vcpkgCmake = Join-Path $VsPath 'VC\vcpkg\scripts\buildsystems\vcpkg.cmake'
    $vcpkgExe = Join-Path $VsPath 'VC\vcpkg\vcpkg.exe'
    $vcpkgVersion = ''
    if (Test-Path $vcpkgExe) { $vcpkgVersion = ((Get-CommandVersion $vcpkgExe @('version')) -split "`n" | Select-Object -First 1).Trim() }
    Add-Check 'vcpkg (bundled)' (Test-Path $vcpkgCmake) "$vcpkgCmake; $vcpkgVersion"
}

# 3. Tools on PATH.
$cmake = Get-Command cmake -ErrorAction SilentlyContinue
if ($cmake) {
    $v = Get-CommandVersion $cmake.Source @('--version')
    $ok = $v -match 'cmake version (\d+)\.(\d+)\.(\d+)'
    $cmakeOk = $ok -and ([int] $Matches[1] -gt 3 -or ([int] $Matches[1] -eq 3 -and [int] $Matches[2] -ge 30))
    Add-Check 'CMake 3.30+' $cmakeOk "$($Matches[0]) at $($cmake.Source)"
} else {
    Add-Check 'CMake 3.30+' $false 'cmake not on PATH'
}

$dotnet = Get-Command dotnet -ErrorAction SilentlyContinue
if ($dotnet) {
    $sdks = @(& dotnet --list-sdks 2>$null)
    Add-Check '.NET SDK' ($sdks.Count -gt 0) ("sdks: " + (($sdks | ForEach-Object { $_.Split(' ')[0] }) -join ', '))
} else {
    Add-Check '.NET SDK' $false 'dotnet not on PATH (needed to build the actor compiler)'
}

$python = Get-Command python -ErrorAction SilentlyContinue
if ($python) {
    $v = Get-CommandVersion $python.Source @('-c', 'import sys; print(sys.version.split()[0])')
    Add-Check 'Python 3' ($v -match '^3\.') "$v at $($python.Source)"
} else {
    Add-Check 'Python 3' $false 'python not on PATH (needed for code generation during the build)'
}

$git = Get-Command git -ErrorAction SilentlyContinue
if ($git) { Add-Check 'git' $true (Get-CommandVersion $git.Source @('--version')) } else { Add-Check 'git' $false 'git not on PATH' }

# 4. OpenSSL, static /MT libraries.
$sslLib = Join-Path $OpenSslRoot 'lib\VC\x64\MT\libssl_static.lib'
$cryptoLib = Join-Path $OpenSslRoot 'lib\VC\x64\MT\libcrypto_static.lib'
$sslHeader = Join-Path $OpenSslRoot 'include\openssl\opensslv.h'
$sslVersion = ''
if (Test-Path $sslHeader) {
    $line = Select-String -Path $sslHeader -Pattern 'OPENSSL_VERSION_STR\s+"([^"]+)"' | Select-Object -First 1
    if ($line) { $sslVersion = $line.Matches[0].Groups[1].Value }
}
$sslOk = (Test-Path $sslLib) -and (Test-Path $cryptoLib) -and ($sslVersion -match '^3\.')
Add-Check 'OpenSSL 3.x static' $sslOk "version '$sslVersion' at $OpenSslRoot (lib\VC\x64\MT\libssl_static.lib, libcrypto_static.lib)"

# 5. Boost 1.86.0, staged, static, tagged with the same clang major as clang-cl.
$boostHeader = Join-Path $BoostRoot 'boost\version.hpp'
$boostLibVersion = ''
if (Test-Path $boostHeader) {
    $line = Select-String -Path $boostHeader -Pattern 'define BOOST_LIB_VERSION "([^"]+)"' | Select-Object -First 1
    if ($line) { $boostLibVersion = $line.Matches[0].Groups[1].Value }
}
Add-Check 'Boost sources' ($boostLibVersion -eq '1_86') "BOOST_LIB_VERSION '$boostLibVersion' at $BoostRoot (expected 1_86)"

$stage = Join-Path $BoostRoot 'stage\lib'
$components = @('context', 'filesystem', 'iostreams', 'program_options', 'serialization', 'system', 'url')
if ($null -eq $clangMajor) {
    Add-Check 'Boost stage' $false "clang major unknown, cannot check the library tag under $stage"
} else {
    $missing = @()
    foreach ($c in $components) {
        $lib = Join-Path $stage "libboost_$c-clangw$clangMajor-mt-s-x64-1_86.lib"
        if (-not (Test-Path $lib)) { $missing += "libboost_$c-clangw$clangMajor-mt-s-x64-1_86.lib" }
    }
    $present = @(Get-ChildItem $stage -Filter 'libboost_*-mt-s-x64-1_86.lib' -ErrorAction SilentlyContinue | ForEach-Object { if ($_.Name -match '-(clangw\d+)-') { $Matches[1] } } | Sort-Object -Unique)
    if ($missing.Count -eq 0) {
        Add-Check 'Boost stage' $true "7 static release libraries tagged clangw$clangMajor under $stage"
    } else {
        Add-Check 'Boost stage' $false ("missing " + ($missing -join ', ') + "; tags present: " + ($present -join ', ') + ". Rebuild Boost with the clang-cl of this Visual Studio (scripts\build-boost.ps1).")
    }
}

# 6. Free disk on the drive that will hold the clone and the build tree.
$drive = Get-PSDrive -Name $SourceDrive.TrimEnd(':') -ErrorAction SilentlyContinue
if ($drive) {
    $freeGB = [math]::Round($drive.Free / 1GB, 1)
    Add-Check "Free disk on $($SourceDrive.TrimEnd(':')):" ($freeGB -ge $MinFreeGB) "$freeGB GB free, $MinFreeGB GB needed (clone 0.7 GB, build tree 2 GB per tag, vcpkg 0.5 GB)"
} else {
    Add-Check "Free disk on $($SourceDrive):" $false 'drive not found'
}

# 7. 7-Zip, used by fetch-macos-client.ps1 to unpack the upstream macOS package (xar, gzip, cpio).
$sevenZip = 'C:\Program Files\7-Zip\7z.exe'
Add-Check '7-Zip' (Test-Path $sevenZip) "$sevenZip (7-zip.org; needed to fetch the macOS client files for a release)"

# 8. Docker (optional, only the smoke test of verify-fdb.ps1 uses it).
$docker = Get-Command docker -ErrorAction SilentlyContinue
$dockerOk = $false
if ($docker) { & docker info 2>$null | Out-Null; $dockerOk = ($LASTEXITCODE -eq 0) }
Add-Check 'Docker (optional)' $dockerOk 'a running Docker engine enables the live-cluster smoke test' -Warn

$script:rows | Format-Table Check, Status, Detail -AutoSize -Wrap | Out-String -Width 200 | Write-Host

if ($script:failed) {
    Write-Host 'At least one prerequisite is missing. Fix the FAIL rows before building.' -ForegroundColor Red
    exit 1
}
Write-Host 'All prerequisites present.' -ForegroundColor Green
exit 0
