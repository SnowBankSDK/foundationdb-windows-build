# FoundationDB Windows build

Windows client binaries for [FoundationDB](https://github.com/apple/foundationdb): `fdb_c.dll` (the
client library every binding loads) and `fdbcli.exe`, built from the upstream release tags. Upstream
publishes Linux and macOS binaries only; this repository fills the Windows gap for the 7.3 and 7.4
lines, and its releases also carry the macOS clients (arm64 and x86_64), taken unmodified from the
upstream macOS packages.

## Releases

Each [release](https://github.com/SnowBankSDK/foundationdb-windows-build/releases) is named after the
upstream tag it was built from and carries `fdb_c.dll`, `fdbcli.exe`, `libfdb_c.arm64.dylib`,
`fdbcli.arm64`, `libfdb_c.x86_64.dylib`, `fdbcli.x86_64`, and a `.sha256` file per binary (releases up to
7.4.4 carry the macOS arm64 files without the architecture suffix). The `FoundationDB.Client.Native`
NuGet package downloads these files by URL and verifies the checksums.

The Windows `fdb_c.dll` is built without TLS support (the TLS initialization is stubbed out) and
without AVX instructions; it runs on any x64 Windows host. It speaks the wire protocol of its release
line (`fdb00b074000000` for 7.4), so a 7.4.x client talks to any 7.4.x cluster.

## Building

The kit in this repository builds and verifies the binaries on any Windows machine with Visual Studio
2022; no Docker, no Linux. `CLAUDE.md` is the complete checklist: prerequisites with versions, the
scripts in order, what "verified" means, how to publish, and what to do on each known failure.

```powershell
.\scripts\check-prereqs.ps1               # every prerequisite, pass/fail table
.\scripts\build-boost.ps1                 # Boost 1.86.0 static libraries with clang-cl, once per clang major
.\scripts\build-fdb.ps1 -Tag 7.4.7        # clone, patch, configure, build, package
.\scripts\verify-fdb.ps1 -ArtifactDir .\artifacts\7.4.7   # exports, version, checksums, live-cluster smoke test
.\scripts\fetch-macos-client.ps1 -Tag 7.4.7               # the macOS clients out of the upstream packages, for a release
```

`patches\README.md` explains every change the build makes to the upstream sources and how to port
the set to a new tag.

## History

Until 2025 this repository held GitHub Actions workflows that built FoundationDB inside a Windows
Docker image on self-hosted runners. That pipeline is gone; the files are in the history at commit
`bb909bd`.
