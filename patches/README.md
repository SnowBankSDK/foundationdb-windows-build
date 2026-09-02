# The Windows patch set

A stock `apple/foundationdb` checkout does not configure or compile on Windows. The patches here make
CMake target Windows without Swift, build the C# actor compiler out of band, replace POSIX-only code,
and stub TLS. `scripts\build-fdb.ps1` applies one branch patch by release line, then every patch under
`extra\` that still fits.

| File | Applies to | Files touched |
|---|---|---|
| `windows-7.4.7.patch` | every 7.4 tag (the script rewrites the `VERSION` context to the tag) | 16 |
| `windows-7.4.6.patch` | 7.4.6 as built; kept for reference, not applied by the script | 15 |
| `windows-7.3.52.patch` | every 7.3 tag | 8 |
| `extra\knob-status-timeout-header.patch` | tags whose `ClientKnobs.h` still lacks the `#undef` (7.3.78 and later 7.3 tags) | 1 |
| `extra\knob-status-timeout-source.patch` | tags where `windows.h` is included after the knob header in the two client sources that use the knob (7.3.78 and later 7.3 tags; harmless on 7.4) | 2 |
| `vcpkg.json` | copied to the source root of every tag | manifest |

## The 7.4 patch, hunk by hunk

Build system, all essential:

- `CMakeLists.txt`. Splits `project(...)` so Windows declares `LANGUAGES C CXX ASM` without Swift (7.4
  added Swift as a project language and there is no Swift toolchain on Windows). A `WIN32` block points
  Boost at `C:/boost_1_86_0` (`BOOST_ROOT`, `BOOST_LIBRARYDIR`, static, multithreaded, static runtime),
  forces `BUILD_C_BINDING ON`, sets `cmake_policy(CMP0167 OLD)` for module-mode FindBoost (the
  hand-built Boost has no CMake config package), disables Swift (`WITH_SWIFT OFF`, an empty
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
