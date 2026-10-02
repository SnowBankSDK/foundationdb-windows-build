# The Windows patch set

A stock `apple/foundationdb` checkout does not configure or compile on Windows. The patches here make
CMake target Windows without Swift, replace POSIX-only code, and fix Windows-only bugs. For 7.3 and 7.4
they also build the C# actor compiler out of band and stub TLS. `scripts\build-fdb.ps1` applies one branch
patch by release line, then its `-common` companion when the branch has one, then every patch under
`extra\` that still fits.

From 8.0 on, a branch has two patch files:

- `windows-<tag>.patch`: every hunk leaves the code that Linux and macOS compile unchanged (it edits
  `#ifdef _WIN32` branches, `if(WIN32)` CMake blocks, or Windows-only files). These hunks are candidates
  for upstream.
- `windows-<tag>-common.patch`: hunks that must change code shared by every platform. Local only.

| File | Applies to | Files touched |
|---|---|---|
| `windows-8.0.0.patch` | 8.0 tags | 27 |
| `windows-8.0.0-common.patch` | 8.0 tags, after `windows-8.0.0.patch` | 2 |
| `windows-7.4.8.patch` | 7.4.8 and later 7.4 tags | 16 |
| `windows-7.4.7.patch` | 7.4 tags up to 7.4.7 (the script rewrites the `VERSION` context to the tag) | 16 |
| `windows-7.4.6.patch` | 7.4.6 as built; kept for reference, not applied by the script | 15 |
| `windows-7.3.52.patch` | every 7.3 tag | 8 |
| `extra\knob-status-timeout-header.patch` | tags whose `ClientKnobs.h` still lacks the `#undef` (7.3.78 and later 7.3 tags) | 1 |
| `extra\knob-status-timeout-source.patch` | tags where `windows.h` is included after the knob header in the two client sources that use the knob (7.3.78 and later 7.3 tags; harmless on 7.4) | 2 |
| `vcpkg.json` | copied to the source root of every tag | manifest |

## The 8.0 patches

8.0 removed the actor compiler (Flow actors are C++20 coroutines), made Swift opt-in, and renamed most
`.actor.cpp` files. The 8.0 build needs clang-cl 22.1.7 or later and runs the LLVM IR verifier on every
translation unit (`/clang:-fverify-intermediate-code`, set by `build-fdb.ps1`).

Build system:

- `CMakeLists.txt`: the `WIN32` block (Boost at `C:/boost_1_89_0` in config mode, Swift off, the components
  the client does not need off), `include(CTest)`, `enable_testing()` and `add_subdirectory(tests)` behind
  `NOT WIN32`, no `packaging/msi`. The block also adds a version resource (`cmake/WindowsVersionInfo.rc.in`,
  a new file) to `fdb_c.dll` and `fdbcli.exe`: FileVersion, ProductVersion with the source commit,
  ProductName. The call is deferred to the end of the file, when both targets exist.
- `cmake/ConfigureCompiler.cmake` and `flow/config.h.cmake`: `_WIN32_WINNT=0x0A00`, `WINVER` and
  `BOOST_ALL_NO_LIB` on the command line (Windows 10 / Server 2016 minimum). The `config.h` block that set
  Windows Server 2003 was live only in files that included a Windows or Boost.Asio header first.
- `fdbclient/CMakeLists.txt`: `folly_memcpy` (Linux assembly) stays off Windows.

Compile fixes:

- `Platform.h`: no `strtoull` to `_strtoui64` macro (Boost 1.89 Asio calls `std::strtoull`).
- `Platform.cpp`: `PdhOpenQuery(nullptr, 0, ...)` (the parameter is a `DWORD_PTR`); a Windows
  `getCachedImageInfo()` for the shared `format_backtrace()`.
- `UnitTestRunner.cpp`: `<direct.h>` and `<process.h>` for `chdir` and `getpid`.
- `Hash3.c`, `VFSAsync.cpp`: `WIN32` to `_WIN32`. `Trace.cpp`: `<chrono>`. `flat_buffers.h`: `<stdexcept>`
  under `_WIN32`. `Knobs.h`: `#undef STATUS_TIMEOUT` after the includes. `swift.h`: no `_tid()` on Windows
  (no caller, and `GetCurrentThreadId` pulled `<windows.h>` into every file).

Bug fixes (Windows code paths that upstream never ran):

- `singleton.h`: the Windows lock created a new kernel mutex per use, so it excluded nothing and leaked a
  handle each time. Every platform now uses `std::mutex`.
- `Tracing.cpp`: `network_lossy` deleted the tracer without creating a new one on Windows (use after free).
  It now falls back to the no-op tracer with a `NetworkLossyTracerUnsupported` warning.
- `Platform.cpp` `startThread`/`waitThread`: `_beginthreadex` and `CloseHandle` (the C runtime closes a
  `_beginthread` handle at thread exit, so the join could wait on a recycled handle); thread names through
  `SetThreadDescription`; an escaped exception is reported as on Linux.
- `FileTraceLogWriter.cpp`: trace files opened with `_O_BINARY | _O_NOINHERIT` (LF line endings, exact roll
  size, no handle inherited by child processes).
- `Platform.cpp` `getMachineRAMInfo`: `AvailableMemory` is `ullAvailPhys` instead of total RAM minus the
  commit charge, which under-reported and could go negative.
- `SpecialKeySpace.cpp`: the actor-lineage time parser always failed on Windows (`std::get_time` has no `%F`
  or `%z` there) and never set its result.
- `AsyncFileWinASIO.h`: the atomic-write rename uses `MoveFileExA` with `MOVEFILE_REPLACE_EXISTING` and
  reports a failure instead of ignoring it.
- `Platform.h`: 32-bit `clz`/`ctz` returned 63-based values and 64 for zero.
- `Platform.cpp`: wall clock from `GetSystemTimePreciseAsFileTime` (1 to 15.6 ms steps before).

Robustness and cleanup:

- `Net2.cpp`, `FastAlloc.cpp`, `AsyncFileWinASIO.h`, `Tracing.cpp`, `DatabaseContext.cpp`, `NativeAPI.cpp`:
  `WIN32` to `_WIN32`. Without `/DWIN32`, `WIN32` exists only after the SDK's `minwindef.h` or Boost.Asio
  was included, so these tests depended on include order (`Net2`'s `timeBeginPeriod(1)` among them).
- Removed: `_set_FMA3_enable(0)` (a VS 2013 workaround that turned off the FMA3 math paths of the C runtime
  for the whole process), the VS 2010 version guard, the MSVC branch of `DISABLE_ZERO_DIVISION_FLAG`, and
  the `_vscprintf` size fallback in `flow.cpp` (the C runtime's `vsnprintf` has returned the size since VS 2015).

clang-cl workaround: clang-cl up to at least 23.1.2 builds invalid exception-handling code for some
coroutines at `/O1` and above (LLVM issue 226735: a catch funclet with two unwind destinations, or a value
used before its definition). At run time the unwinder runs the cleanup of a scope that was never entered:
every failed connection crashed the client in `connectionKeeper`. The patch turns optimization off, on
Windows clang only, around the affected code: `connectionKeeper` (`FlowTransport.cpp`), the `UDPSocket`
class (`Net2.cpp`), the range-read coroutines from `getExactRange` to `getRangeStreamImpl` (`NativeAPI.cpp`),
`BackupRangeTaskFunc` (`FileBackupAgent.cpp`) and `copyDownFile` (`S3Client.cpp`). A range-read benchmark
shows no difference with and without these regions. The IR verifier in the build names any new function
in this state; wrap it the same way.

TLS: the 7.3 and 7.4 TLS stub is gone. The 8.0 Windows client connects to TLS clusters with the usual
`TLS_CERT_PATH`, `TLS_KEY_PATH` and `TLS_CA_PATH` options; a missing or untrusted certificate times out
like on Linux.

Common patch: `RandomKeyValueUtils.h` (`uint` to `unsigned int`) and `S3Client_cli.cpp` (`#import` to
`#include`). Neither file is part of `fdb_c.dll` or `fdbcli.exe`.

Saving the 8.0 patches from a patched checkout (the first patch adds a file, hence `git add -N`):

```
git add -N cmake/WindowsVersionInfo.rc.in
git diff -- fdbclient/include/fdbclient/RandomKeyValueUtils.h fdbclient/S3Client_cli.cpp > windows-8.0.0-common.patch
git diff -- . ":(exclude)fdbclient/include/fdbclient/RandomKeyValueUtils.h" ":(exclude)fdbclient/S3Client_cli.cpp" > windows-8.0.0.patch
```

## The 7.4.8 port

Upstream 7.4.8 changed two things the 7.4.7 patch relied on, and `windows-7.4.8.patch` follows them:

- `project(...)` no longer declares Swift; upstream enables it only under `if(WITH_SWIFT)`. The patch
  keeps the upstream `project(...)` call and inserts the `WIN32` block before that test, so
  `WITH_SWIFT OFF` is set before it is read. The patch has no `VERSION` line anymore.
- `cmake/CompileBoost.cmake` finds Boost in config mode on Windows. The `WIN32` block adds
  `${BOOST_ROOT}/stage` to `CMAKE_PREFIX_PATH`, where `b2 stage` writes `lib/cmake/Boost-1.86.0`.

The other 15 files carry the 7.4.7 hunks unchanged. The description below covers both patches.

## The 7.4 patch, hunk by hunk

Build system, all essential:

- `CMakeLists.txt`. Splits `project(...)` so Windows declares `LANGUAGES C CXX ASM` without Swift (7.4
  added Swift as a project language and there is no Swift toolchain on Windows). A `WIN32` block points
  Boost at `C:/boost_1_86_0` (`BOOST_ROOT`, `BOOST_LIBRARYDIR`, static, multithreaded, static runtime),
  forces `BUILD_C_BINDING ON`, sets `cmake_policy(CMP0167 OLD)` for module-mode FindBoost (up to
  7.4.7; from 7.4.8 upstream uses config mode and the block adds the stage to `CMAKE_PREFIX_PATH`), disables Swift (`WITH_SWIFT OFF`, an empty
  `CMAKE_Swift_COMPILER`, `FOUNDATIONDB_CROSS_COMPILING OFF`), sets `OPEN_FOR_IDE OFF`, and turns off the
  components the Windows client does not need: documentation, AWS backup, gRPC, Valgrind, RocksDB, ACAC,
  the Python, Java, Go and Ruby bindings, the multi-region tests. It guards `include(CTest)`,
  `enable_testing()` and `add_subdirectory(tests)` behind `NOT WIN32` and comments out the documentation
  and `packaging/msi` subdirectories.
- `cmake/CompileActorCompiler.cmake`. Replaces the in-tree C# `add_executable(actorcompiler ...)` with a
  custom command that runs `dotnet build flow/actorcompiler/actorcompiler.csproj` and imports the result
  as an `IMPORTED` target. The custom target this creates never fires under MSBuild, which is why the
  build script runs `dotnet build` itself; the imported target is still needed so the actor-compile rules
  resolve `build\actorcompiler.exe`.
- `flow/actorcompiler/Properties/AssemblyInfo.cs`. Comments out every `[assembly: ...]` attribute: the
  SDK-style `dotnet build` generates them and the duplicates are a CS0579 error.
- `flow/CMakeLists.txt`. On Windows, appends the generated `TLSConfig.actor.g.cpp` to `FLOW_SRCS` and
  adds `add_dependencies(flow actorcompiler_build)`. A `message(STATUS ...)` loop that dumps `FLOW_SRCS`
  is debug residue and can go.
- `fdbclient/CMakeLists.txt`. `if(UNIX AND NOT APPLE AND NOT WIN32)` around `folly_memcpy`, a Linux
  assembly target that does not exist on Windows.

Portability fixes (POSIX assumptions that break under clang-cl):

- `flow/Hash3.c`, `fdbserver/VFSAsync.cpp`: `WIN32` to `_WIN32`. clang-cl always defines `_WIN32`;
  `WIN32` needs `/DWIN32`, which the C++ flags used here drop.
- `fdbclient/include/fdbclient/RandomKeyValueUtils.h`: `uint` to `unsigned int` (`uint` is a POSIX typedef).
- `fdbclient/S3Client_cli.actor.cpp`: `#import` to `#include` (`#import` is an MSVC type-library directive).
- `flow/include/flow/flat_buffers.h`: adds `#include <stdexcept>`.
- `flow/Trace.cpp`: adds `#include <chrono>` inside the `_WIN32` block.
- `flow/include/flow/flow.h`: `#include <windows.h>` on `_WIN32` instead of `pthread.h`.
- `flow/include/flow/swift.h`: `_tid()` returns `GetCurrentThreadId()` on `_WIN32`.

Code fixes and stubs:

- `flow/Net2.actor.cpp`. Wraps the `reloadCertificatesOnChange` actor and the body of `Net2::initTLS`
  in `#if _WIN32 ... #else`, so `initTLS` returns immediately on Windows. Consequence: the Windows
  `fdb_c.dll` does not do TLS.
- `fdbrpc/ActorFuzzUnitTest.cpp`: `#if !_WIN32` around `TEST_CASE("/actorFuzz")`.
- `fdbclient/include/fdbclient/ClientKnobs.h` (new in 7.4.7): `#undef STATUS_TIMEOUT` under `_WIN32`
  after the includes. Upstream added a client knob with that name and `winnt.h` defines it as a macro.

## The 7.3 patch

Most 7.4 hacks address Swift, which 7.3 does not have, so the 7.3 set is smaller:

| 7.4 hunks | 7.3 |
|---|---|
| CompileActorCompiler.cmake, VFSAsync.cpp, Hash3.c, Net2.actor.cpp, Trace.cpp, AssemblyInfo.cs, flat_buffers.h | apply unchanged (7 files) |
| swift.h, S3Client_cli.actor.cpp, ActorFuzzUnitTest.cpp | files absent in 7.3, dropped |
| fdbclient/CMakeLists.txt, RandomKeyValueUtils.h, flow.h | patched constructs absent in 7.3, dropped |
| CMakeLists.txt | no Swift split; the `WIN32` block sets the Boost hints, the component trims and `WITH_DOCUMENTATION OFF`; guards `enable_testing` and `tests`; comments `packaging/msi` |

Two 7.3-only needs, both handled by `build-fdb.ps1`:

1. 7.3 gates Windows code with bare `WIN32` in many `.cpp` files, so the configure adds
   `/DWIN32 /D_WINDOWS` to `CMAKE_CXX_FLAGS`. Without it `flow/FastAlloc.cpp` fails with
   `unknown type name 'CRITICAL_SECTION'`.
2. `WITH_DOCUMENTATION OFF`, set by the patch; left on, configure fails in `documentation/CMakeLists.txt`
   looking for a `python3.exe` for a Sphinx venv.

Boost: 7.3 asks for `Boost 1.78` as a minimum on Windows, so the same Boost 1.86 stage serves both lines.

## `extra\`

`build-fdb.ps1` runs `git apply --check` on every patch in `extra\` after the branch patch, applies the
ones that fit, and reports the others as skipped. A patch here is a fix that some tags need and others
already contain. The two `knob-status-timeout-*.patch` files are the `STATUS_TIMEOUT` `#undef`, which
7.3 tags need from 7.3.78 on because upstream back-ported the knob there:

- `-header.patch` puts the `#undef` in `ClientKnobs.h` after its includes. The 7.4.7 branch patch already
  carries that hunk, so the check fails on 7.4 and the patch is skipped.
- `-source.patch` puts the same `#undef` in `ClientKnobs.cpp` and `StatusClient.actor.cpp` after their
  includes. In 7.3 those files include `flow/flow.h` after the knob header, and there `flow.h` pulls in
  `windows.h` through `Platform.h`, so the macro comes back after the header's `#undef` and the
  `init( STATUS_TIMEOUT, 30.0 )` line fails with "no matching member function for call to 'initKnob'"
  (a `DWORD` cannot bind to `double &`). On 7.4 the hunks apply too and change nothing.

## Porting the set to a new tag

1. Run `scripts\build-fdb.ps1 -Tag <new>`. Hunks that fail on the `VERSION x.y.z` context are handled by
   the script; any other failing hunk stops the run with the hunk text in the log.
2. In the checkout, `git apply --reject patches\windows-<line>.patch`, then fix each `.rej` by hand so the
   result does what the hunk description above says.
3. Build with `-SkipClone` until green, then `verify-fdb.ps1`.
4. Save `git diff > patches\windows-<new>.patch` (git ignores `vcpkg.json`, which is untracked), point
   `build-fdb.ps1` at it for the line, and describe the changed hunks in this file.
5. When upstream fixes something a hunk patched, drop the hunk and say so here.
