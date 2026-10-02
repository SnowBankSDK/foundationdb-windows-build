# Builds the Boost static libraries the FoundationDB Windows build links, with clang-cl: 1.86.0 for the
# 7.3 and 7.4 branches (the default), 1.89.0 for the 8.0 branch.
#
# The libraries are tagged with the clang major of the compiler that built them (clangw19 for clang 19),
# and FindBoost only matches libraries whose tag equals the clang-cl that builds FoundationDB. Rebuild
# Boost with this script whenever the Visual Studio clang major changes.
#
# Usage:
#   .\scripts\build-boost.ps1                                   # sources and stage at C:\boost_1_86_0
#   .\scripts\build-boost.ps1 -BoostRoot D:\boost_1_86_0        # elsewhere; pass the same path to build-fdb.ps1
#   .\scripts\build-boost.ps1 -Version 1.89.0                    # the 8.0 branch; sources and stage at C:\boost_1_89_0
#   .\scripts\build-boost.ps1 -Variant 'debug,release' -AllLibraries   # the full stage (slower)
#
# The script downloads and extracts the sources when <BoostRoot>\bootstrap.bat is absent. Expect the
# libraries in release to take 5 to 15 minutes; the full stage takes longer. Windows PowerShell 5.1 or 7.
[CmdletBinding()]
param(
    [ValidateSet('1.86.0', '1.89.0')] [string] $Version = '1.86.0',
    [string] $BoostRoot = '',
    [string] $StageDir = '',
    [string] $VsPath = '',
    # A standalone LLVM install (for example C:\Program Files\LLVM) instead of the clang-cl Visual Studio bundles.
    [string] $LlvmRoot = '',
    [string] $Variant = 'release',
    [int] $Jobs = 0,
    [switch] $AllLibraries
)

$ErrorActionPreference = 'Continue'
$boostVersion = $Version
$underscore = $Version.Replace('.', '_')               # 1_89_0, the archive and directory name
$libVersion = $underscore -replace '_0$', ''           # 1_89, the BOOST_LIB_VERSION and library name suffix
if ([string]::IsNullOrEmpty($BoostRoot)) { $BoostRoot = "C:\boost_$underscore" }
$archiveUrl = "https://archives.boost.io/release/$Version/source/boost_$underscore.tar.bz2"
# Boost 1.89 removed the boost_system stub library (Boost.System is header-only), and the 8.0 branch links
# neither system nor context on Windows.
$components = if ($Version -eq '1.86.0') { @('context', 'filesystem', 'iostreams', 'program_options', 'serialization', 'system', 'url') } else { @('filesystem', 'iostreams', 'program_options', 'serialization', 'url') }
if ([string]::IsNullOrEmpty($StageDir)) { $StageDir = Join-Path $BoostRoot 'stage' }
if ($Jobs -le 0) { $Jobs = [int] $env:NUMBER_OF_PROCESSORS }
$clock = [System.Diagnostics.Stopwatch]::StartNew()
function Format-Line($Item) {
    # a native command's stderr arrives as ErrorRecord objects whose ToString() is the exception type name
    if ($Item -is [System.Management.Automation.ErrorRecord]) { return $Item.Exception.Message }
    return [string] $Item
}
function Write-Phase([string] $Name) { Write-Host ("[{0}] [{1:hh\:mm\:ss}] === {2} ===" -f (Get-Date -Format 'HH:mm:ss'), $clock.Elapsed, $Name) -ForegroundColor Cyan }
function Stop-Build([string] $Message) { Write-Host "BOOST BUILD FAILED: $Message" -ForegroundColor Red; exit 1 }

# 1. Sources.
Write-Phase "boost $boostVersion sources at $BoostRoot"
if (-not (Test-Path (Join-Path $BoostRoot 'bootstrap.bat'))) {
    $parent = Split-Path -Parent $BoostRoot
    if (-not (Test-Path $parent)) { New-Item -ItemType Directory -Path $parent | Out-Null }
    # The archive goes to %TEMP%: a standard user may create a directory at a drive root but not a file.
    $archive = Join-Path $env:TEMP "boost_$underscore.tar.bz2"
    if (-not (Test-Path $archive)) {
        Write-Host "downloading $archiveUrl"
        & curl.exe -L --fail --silent --show-error -o $archive $archiveUrl
        if ($LASTEXITCODE -ne 0) { Stop-Build "download failed ($LASTEXITCODE)" }
    }
    Write-Host "extracting $archive"
    & "$env:SystemRoot\System32\tar.exe" -xf $archive -C $parent
    if ($LASTEXITCODE -ne 0) { Stop-Build "extract failed ($LASTEXITCODE)" }
    $extracted = Join-Path $parent "boost_$underscore"
    if ((Resolve-Path $extracted).Path -ne (Resolve-Path $BoostRoot -ErrorAction SilentlyContinue).Path) {
        if (Test-Path $BoostRoot) { Stop-Build "$BoostRoot exists but has no bootstrap.bat; remove it or point -BoostRoot at the extracted boost_$underscore" }
        Move-Item $extracted $BoostRoot
    }
}
$header = Join-Path $BoostRoot 'boost\version.hpp'
if (-not (Select-String -Path $header -Pattern "define BOOST_LIB_VERSION `"$libVersion`"" -Quiet)) { Stop-Build "$BoostRoot is not Boost $Version" }

# 2. Toolchain: clang-cl for the libraries, MSVC lib.exe as the archiver, cl.exe for bootstrap.
Write-Phase 'toolchain'
if ([string]::IsNullOrEmpty($VsPath)) {
    $vswhere = Join-Path ${env:ProgramFiles(x86)} 'Microsoft Visual Studio\Installer\vswhere.exe'
    if (-not (Test-Path $vswhere)) { Stop-Build "vswhere not found at $vswhere; pass -VsPath" }
    $VsPath = (& $vswhere -latest -products '*' -requires Microsoft.VisualStudio.Component.VC.Llvm.Clang -property installationPath | Select-Object -First 1)
    if ([string]::IsNullOrEmpty($VsPath)) { Stop-Build 'no Visual Studio instance with clang-cl; run scripts\check-prereqs.ps1' }
}
$clangCl = if ([string]::IsNullOrEmpty($LlvmRoot)) { Join-Path $VsPath 'VC\Tools\Llvm\x64\bin\clang-cl.exe' } else { Join-Path $LlvmRoot 'bin\clang-cl.exe' }
if (-not (Test-Path $clangCl)) { Stop-Build "clang-cl not found at $clangCl" }
$clangVersion = (& $clangCl --version | Select-Object -First 1)
if ($clangVersion -notmatch 'clang version (\d+)') { Stop-Build "clang version not parsed: $clangVersion" }
$clangMajor = [int] $Matches[1]
$msvc = Get-ChildItem (Join-Path $VsPath 'VC\Tools\MSVC') -Directory | Sort-Object Name | Select-Object -Last 1
$libExe = Join-Path $msvc.FullName 'bin\Hostx64\x64\lib.exe'
if (-not (Test-Path $libExe)) { Stop-Build "lib.exe not found at $libExe" }
Write-Host "clang    : $clangVersion (tag clangw$clangMajor)"
Write-Host "archiver : lib.exe from the developer shell PATH ($libExe)"

Import-Module (Join-Path $VsPath 'Common7\Tools\Microsoft.VisualStudio.DevShell.dll')
Enter-VsDevShell -VsInstallPath $VsPath -SkipAutomaticLocation -DevCmdArguments '-arch=x64 -host_arch=x64' | Out-Null
Set-Location $BoostRoot

# user-config.jam declares the clang-win toolset with the clang-cl path (forward slashes, quoted: it has
# spaces). No explicit <archiver>: the clang-win toolset drops an archiver value whose path has spaces and
# then runs an empty archive command ("failed clang-win.archive" on every library). Left unset, the
# archiver is the bare lib.exe, which the developer shell puts on PATH.
$jam = @(
    'using clang-win : :',
    "  `"$($clangCl -replace '\\', '/')`"",
    '  ;'
) -join "`n"
[System.IO.File]::WriteAllText((Join-Path $BoostRoot 'user-config.jam'), $jam + "`n", [System.Text.Encoding]::ASCII)
Write-Host "user-config.jam written"

# 3. Bootstrap b2 (the Boost.Build engine, built with MSVC), once. bootstrap.bat calls build.bat, and
# build.bat calls its helpers (guess_toolset.bat, config_toolset.bat) by bare name from the engine
# directory; a host that sets NoDefaultCurrentDirectoryInExePath blocks that and build.bat then reports
# "unable to detect your toolset installation". So the engine is built from its own directory, with that
# directory on PATH and the variable cleared for this process, then copied to the Boost root.
if (-not (Test-Path (Join-Path $BoostRoot 'b2.exe'))) {
    Write-Phase 'bootstrap b2 (msvc)'
    $engine = Join-Path $BoostRoot 'tools\build\src\engine'
    $env:PATH = "$engine;$env:PATH"
    Remove-Item Env:\NoDefaultCurrentDirectoryInExePath -ErrorAction SilentlyContinue
    & cmd /c "cd /d `"$engine`" && .\build.bat msvc" 2>&1 | ForEach-Object { Format-Line $_ }
    if (-not (Test-Path (Join-Path $engine 'b2.exe'))) { Stop-Build 'build.bat msvc produced no b2.exe (run it from a Visual Studio developer prompt to see why)' }
    Copy-Item (Join-Path $engine 'b2.exe') (Join-Path $BoostRoot 'b2.exe') -Force
    [System.IO.File]::WriteAllText((Join-Path $BoostRoot 'project-config.jam'), "using msvc ;`n", [System.Text.Encoding]::ASCII)
}

# 4. Build and stage.
Write-Phase "b2 stage (toolset clang-win, static, static runtime, x64, $Variant, $Jobs jobs)"
$b2Args = @('--user-config=user-config.jam', 'toolset=clang-win', 'link=static', 'runtime-link=static', 'threading=multi', 'address-model=64', "variant=$Variant", "--stagedir=$StageDir", "-j$Jobs")
if (-not $AllLibraries) { $b2Args += ($components | ForEach-Object { "--with-$_" }) }
$b2Args += 'stage'
Write-Host ".\b2.exe $($b2Args -join ' ')"
& .\b2.exe @b2Args 2>&1 | ForEach-Object { Format-Line $_ }
$rc = $LASTEXITCODE

# 5. Check the staged names FindBoost will look for.
Write-Phase 'staged libraries'
$missing = @()
foreach ($c in $components) {
    $lib = Join-Path $StageDir "lib\libboost_$c-clangw$clangMajor-mt-s-x64-$libVersion.lib"
    if (Test-Path $lib) { Write-Host ("  {0,-70} {1,12:N0} bytes" -f (Split-Path -Leaf $lib), (Get-Item $lib).Length) } else { $missing += (Split-Path -Leaf $lib) }
}
if ($rc -ne 0 -or $missing.Count -gt 0) { Stop-Build "b2 exit $rc; missing: $($missing -join ', ')" }
Write-Host "Boost staged under $StageDir\lib in $($clock.Elapsed.ToString('hh\:mm\:ss'))" -ForegroundColor Green
exit 0
