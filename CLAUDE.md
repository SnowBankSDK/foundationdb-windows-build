# FoundationDB Windows build kit

This repository builds the FoundationDB client binaries for Windows, `fdb_c.dll` and `fdbcli.exe`, from an
upstream `apple/foundationdb` release tag, and publishes them as GitHub releases of this repository.
Upstream ships no Windows binaries. The build needs a Windows host with Visual Studio 2022; it needs
no Docker and no Linux.

Follow this file top to bottom. Every step is a script under `scripts\`; run them from the repository
root in Windows PowerShell 5.1 or PowerShell 7. Nothing here needs administrator rights.

## 1. Prerequisites

| Component | Version | Where it comes from |
|---|---|---|
| Visual Studio 2022 (Community works) | 17.x, with the "Desktop development with C++" workload, the "C++ Clang tools for Windows" component (clang-cl and the ClangCL MSBuild toolset) and the "vcpkg package manager" component | Visual Studio Installer. One line: `vs_installer.exe modify --installPath "<VS path>" --add Microsoft.VisualStudio.Workload.NativeDesktop --add Microsoft.VisualStudio.Component.VC.Llvm.Clang --add Microsoft.VisualStudio.Component.VC.Llvm.ClangToolset --add Microsoft.VisualStudio.Component.Vcpkg --includeRecommended --passive --norestart` |
| clang-cl | the one Visual Studio ships (19.1.5 with VS 17.14) | part of the component above. The clang major number must equal the tag of the staged Boost libraries (`clangw19` for clang 19), see section 3 |
| CMake | 3.30.x (3.30.4 proven) | cmake.org installer, on `PATH` |
| .NET SDK | any supported SDK (8, 9 or 10) | dot.net; builds the actor compiler (`flow\actorcompiler`) |
| Python 3 | 3.10 to 3.12 proven | python.org or the Microsoft Store; `python.exe` on `PATH`; the build uses it for code generation and needs the `jinja2` module or it creates a venv on its own |
| OpenSSL 3.3.x Win64, static libraries | 3.3.2 proven | the "Win64 OpenSSL v3.3.x" full installer (not the Light one) from slproweb.com, default path `C:\Program Files\OpenSSL-Win64`; the build links `lib\VC\x64\MT\libssl_static.lib` and `libcrypto_static.lib` |
| Boost | 1.86.0 sources, built by `scripts\build-boost.ps1` | archives.boost.io; default root `C:\boost_1_86_0` |
| git | any recent Git for Windows | git-scm.com |
| Docker Desktop | optional | only the live-cluster smoke test of `verify-fdb.ps1` uses it |

Budgets measured on a 16-core AMD Ryzen 9 7950X (32 threads) with an NVMe disk: configure 67 s (12 s
when re-run), `fdb_c` about 4 minutes, `fdbcli` 68 s, the actor compiler a few seconds. Boost, 7
libraries in release: see `scripts\build-boost.ps1`. Disk: clone 0.7 GB, build tree 2 GB per tag, vcpkg
packages 0.5 GB, Boost sources plus stage 1 GB. Other hosts scale with core count; the build is
compile-bound.

Run the check. It must end with `All prerequisites present.`:

```powershell
.\scripts\check-prereqs.ps1
```

`check-prereqs.ps1` finds Visual Studio through `vswhere`, parses the clang-cl version, and checks that
the Boost stage holds the 7 libraries with the matching `clangw<major>` tag. A `FAIL` row names what to
install or rebuild.

## 2. Order of operations

1. `.\scripts\check-prereqs.ps1` (section 1).
2. `.\scripts\build-boost.ps1` once per clang major (section 3). Skip it when the check already passes
   the "Boost stage" row.
3. `.\scripts\build-fdb.ps1 -Tag <upstream tag>` (section 4).
4. `.\scripts\verify-fdb.ps1 -ArtifactDir .\artifacts\<tag>` (section 5).
5. Publish (section 6).

One build at a time per host. A build is compile-bound and uses every core.

## 3. Boost

FoundationDB links these Boost compiled libraries: context, filesystem, iostreams, program_options,
serialization, system, url. They must be static, built against the static `/MT` runtime, x64, and built
by the same clang major as the FoundationDB build, because CMake's FindBoost looks for
`libboost_<name>-clangw<major>-mt-s-x64-1_86.lib` and matches nothing else.

```powershell
.\scripts\build-boost.ps1                       # sources and stage under C:\boost_1_86_0
.\scripts\build-boost.ps1 -BoostRoot D:\boost_1_86_0   # elsewhere: pass the same -BoostRoot to build-fdb.ps1
```

The script downloads and extracts the 1.86.0 sources when they are absent, writes `user-config.jam`
(clang-cl as the `clang-win` toolset, the MSVC `lib.exe` as archiver), bootstraps `b2` with MSVC, and
stages the 7 libraries in release. `-Variant 'debug,release'` and `-AllLibraries` produce the full stage.

## 4. Build

```powershell
.\scripts\build-fdb.ps1 -Tag 7.4.7
```

Defaults: sources cloned to `C:\fdb-build\<tag>\foundationdb`, build tree in its `build\` subdirectory,
artifacts in `.\artifacts\<tag>\` (ignored by git), log at `C:\fdb-build\<tag>\build-<tag>.log`.
Parameters: `-WorkRoot`, `-SourceDir`, `-OutputDir`, `-LogFile`, `-BoostRoot`, `-OpenSslRoot`, `-VsPath`,
`-ReferenceClone <local clone>` (seeds the clone from a local repository, then dissociates), `-Jobs`,
`-Rebuild` (deletes the build tree first), `-SkipClone` (builds an existing, already patched checkout).

For a run that survives the calling session, start it detached and follow the log:

```powershell
Start-Process powershell -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','.\scripts\build-fdb.ps1','-Tag','7.4.7' -WindowStyle Hidden
Get-Content C:\fdb-build\7.4.7\build-7.4.7.log -Wait
```

What the script does, in order, with a timestamped `=== phase ===` line for each:

1. Enters the Visual Studio developer environment (clang-cl, lld-link, MSBuild, the Windows SDK) and
   points `VCPKG_ROOT` at the vcpkg bundled with Visual Studio.
2. Clones `apple/foundationdb` and checks out the tag. It refuses a checkout with local changes.
3. Applies the branch patch: `patches\windows-7.3.52.patch` for a 7.3 tag, `patches\windows-7.4.7.patch`
   for a 7.4 tag, after rewriting the `VERSION x.y.z` lines of the patch to the requested tag. It then
   tries every `patches\extra\*.patch` and applies the ones that fit. It copies `patches\vcpkg.json` to the
   source root and, when `-BoostRoot` is not the default, rewrites the `BOOST_ROOT` line the patch sets.
4. Configures with CMake: generator `Visual Studio 17 2022`, platform `x64`, toolset `ClangCL`, the
   vcpkg toolchain file (vcpkg builds zlib 1.3.1 and lz4 1.10.0 from the manifest at this step), C++20,
   `CMAKE_BUILD_TYPE=Release`. The 7.3 line adds `/DWIN32 /D_WINDOWS` to `CMAKE_CXX_FLAGS`.
5. Builds the actor compiler with `dotnet build` into `build\` (the CMake target that should do it never
   runs under MSBuild).
6. Builds the `fdb_c` and `fdbcli` targets.
7. Copies `fdb_c.dll` and `fdbcli.exe` to the output directory, writes `<name>.sha256` for each (lowercase
   hex, two spaces, the file name, one line, the `sha256sum` text format) and `build-info.txt` (tag,
   commit, toolchain, timings, sizes, hashes).

The script stops at the first failure with `BUILD FAILED: <reason>` in the log and exit code 1.

## 5. Verify

```powershell
.\scripts\verify-fdb.ps1 -ArtifactDir .\artifacts\7.4.7
```

"Verified" means all four gates pass:

1. `fdbcli --version` reports the tag (`v7.4.7`) and the protocol of the release line
   (`fdb00b074000000` for 7.4, `fdb00b073000000` for 7.3).
2. The export set of `fdb_c.dll` (from `dumpbin /exports`) equals `reference\exports-<line>.txt`: 111
   names, all `fdb_*`, nothing added, nothing removed. A new upstream API adds names; when that is the
   intent, update the reference file in the same change.
3. Each `.sha256` file matches its artifact.
4. Smoke test: with Docker running, the script starts `foundationdb/foundationdb:<tag>` on a local port,
   runs `configure new single memory`, `status minimal` (must report the database available) and a
   set/get round trip through the new `fdbcli.exe`, then removes the container. Without Docker the gate
   is skipped with a message; run it on a host with Docker before publishing.

## 6. Publish

Publishing is a manual step by a maintainer with write access to this repository.

1. Create the GitHub release named and tagged `<tag>` (for example `7.4.7`) on this repository.
2. Upload the four Windows files from `artifacts\<tag>\`: `fdb_c.dll`, `fdb_c.dll.sha256`, `fdbcli.exe`,
   `fdbcli.exe.sha256`. The macOS files (`libfdb_c.dylib`, `fdbcli` and their `.sha256`) come from a
   separate macOS build and are uploaded to the same release.
3. Release body, the format of the existing releases:

   ```
   Windows and macOS Client Binaries for FoundationDB <tag>

   - Windows x86_64:
     - `fdb_c.dll`, SHA256 `<hash>`
     - `fdbcli.exe`, SHA256 `<hash>`

   - macOS arm64:
     - `libfdb_c.dylib`: SHA256 `<hash>`
     - `fdbcli`: SHA256 `<hash>`
   ```

4. Consumers download `https://github.com/SnowBankSDK/foundationdb-windows-build/releases/download/<tag>/<file>`.
   The `FoundationDB.Client.Native` NuGet package pins these URLs and checksums in its `manifest.json`;
   add the entry there after the release exists.

## 7. Known failures and what to do

- **`actorcompiler.exe` missing, or every `.actor.cpp` fails to compile.** The CMake target
  `actorcompiler_build` never runs `dotnet build` under MSBuild. `build-fdb.ps1` builds the actor
  compiler by hand into `build\` before the first target; when running steps by hand, do the same:
  `dotnet build flow\actorcompiler\actorcompiler.csproj -c Release -o build`.
- **CMake cannot find Boost, or links fail on `libboost_*-clangw<N>-...`.** The clang major of the
  staged Boost differs from the clang-cl of Visual Studio (a Visual Studio update changed the clang
  major). `check-prereqs.ps1` names the tags present. Rebuild Boost with `build-boost.ps1`, or pass a
  Boost root built with the right clang.
- **A patch hunk fails on a new tag** (`build-fdb.ps1` prints the failing hunk and stops). Port it by
  hand: in the source checkout run `git apply --reject <patch>`, fix each `.rej` in the file it names,
  keep the intent described in `patches\README.md`, then rerun the build with `-SkipClone`. When the
  build is green, save `git diff > patches\windows-<tag>.patch` and make `build-fdb.ps1` select it for
  the line. A hunk that fails only on the `VERSION x.y.z` context is already handled: the script rewrites
  the version before applying.
- **`expected ')'` at a knob declaration, with a note `expanded from macro '<NAME>'` in `winnt.h`.**
  An upstream knob took the name of a Windows macro (`STATUS_TIMEOUT` did in 7.4.7). Add
  `#ifdef _WIN32 / #undef <NAME> / #endif` in the knob header after its `#include` lines (the Windows
  headers come in through `flow/flow.h`, so an `#undef` above the includes does nothing). Keep the knob
  name; the knob's command-line name stays unchanged. `patches\extra\knob-status-timeout.patch` is the
  7.3 instance of this fix; on 7.4 tags the branch patch already carries it. Before building a new tag,
  `git grep -n -E '^\s+(double|int|int64_t|bool)\s+[A-Z_]+;' fdbclient/include/fdbclient/ClientKnobs.h`
  lists the client knobs; any name that also exists as a macro in the Windows SDK's `winnt.h` or
  `winbase.h` needs the same treatment.
- **vcpkg fails at configure** (manifest install of zlib or lz4). The Visual Studio vcpkg component is
  missing, or `VCPKG_ROOT` points elsewhere. `check-prereqs.ps1` shows the path in use. The manifest
  pins the vcpkg baseline `728711b66ff08483628a5f314ac65980930a52be`; a much older vcpkg may not know it.
- **Configure resolves Python to the Microsoft Store alias, or `Jinja2` is missing.** Both work: the
  Store Python is a real interpreter, and without `jinja2` the upstream CMake creates a venv and installs
  it. A failure inside that venv step means no `python.exe` on `PATH`.
- **`git` warns "LF will be replaced by CRLF".** Harmless; the patches are applied and diffed by git,
  which normalizes line endings.
- **`verify-fdb.ps1` skips the smoke test.** Docker Desktop is not running. Start it and rerun, or accept
  a verification without the live-cluster gate and say so when publishing.
- **The smoke test reports "available, but has issues"** on a fresh single-process memory database. That
  text is the cluster initializing data distribution, not a client fault; the gate checks for
  "available".

## 8. Repository layout

```
CLAUDE.md                      this checklist
README.md                      what the repository is, for readers of the GitHub page
scripts\check-prereqs.ps1      prerequisite table, exit 1 on any failure
scripts\build-boost.ps1        Boost 1.86.0 static libraries with clang-cl
scripts\build-fdb.ps1          clone, patch, configure, build, package one tag
scripts\verify-fdb.ps1         exports, version, checksums, live-cluster smoke test
patches\windows-7.3.52.patch   the 7.3 line patch set (8 files)
patches\windows-7.4.6.patch    the 7.4 patch set as built for 7.4.6 (15 files), kept for reference
patches\windows-7.4.7.patch    the 7.4 line patch set (16 files), the one build-fdb.ps1 applies
patches\extra\*.patch          fixes tried on every tag and applied when they fit
patches\vcpkg.json             the vcpkg manifest (zlib, lz4, pinned baseline)
patches\README.md              what each hunk group does and how to port the set to a new tag
reference\exports-7.3.txt      the 111 exported names of a 7.3 fdb_c.dll
reference\exports-7.4.txt      the 111 exported names of a 7.4 fdb_c.dll
.claude\skills\fdb-windows-build\SKILL.md   the skill a Claude session loads to run this kit
artifacts\                     build outputs (ignored by git)
```

## 9. Rules for changes to this repository

- This repository is public. No internal or customer names, no credentials, no absolute paths of one
  machine hard-coded in scripts (parameters with defaults are fine).
- Documents and comments: one idea per sentence, active voice, concrete numbers, no em dashes, no emoji.
- A change to a script gets a proof run on a real tag before it is committed. A change to a patch gets
  the proof run on the tag the patch targets and a fresh `git diff` saved as the patch.
- Commits are small and named by area: `Scripts: ...`, `Patches: ...`, `Docs: ...`, `Kit: ...`.
