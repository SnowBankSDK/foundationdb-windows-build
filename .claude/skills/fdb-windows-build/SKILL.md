---
name: fdb-windows-build
description: Build, verify and hand off the FoundationDB Windows client binaries (fdb_c.dll, fdbcli.exe) for an upstream release tag with this repository's kit. Use when asked to build FoundationDB for Windows, produce fdb_c.dll or fdbcli.exe for a 7.3.x or 7.4.x tag, rebuild Boost for a new clang, port the Windows patch set to a new tag, verify built binaries, or prepare a release of this repository. Windows host with Visual Studio 2022 only, no Docker needed except for the optional smoke test.
---

# FoundationDB Windows build

The kit is four PowerShell scripts under `scripts\` plus the patch set under `patches\`. `CLAUDE.md`
at the repository root is the full checklist; this skill is the short form for a session that runs it.

## When to use

- A new upstream tag was released and the Windows binaries are needed.
- A Visual Studio update changed the clang major and Boost must be rebuilt.
- A patch hunk fails on a new tag and the set must be ported.
- Built binaries must be verified before a release.

## Command sequence

Run from the repository root, in Windows PowerShell 5.1 or PowerShell 7, one build at a time per host.

1. Prerequisites. Stop on any `FAIL` row and fix it (section 1 of `CLAUDE.md` says what each one needs).

   ```powershell
   .\scripts\check-prereqs.ps1
   ```

2. Boost, only when the check reports the "Boost stage" row as `FAIL` (missing libraries or a clang tag
   that differs from the installed clang-cl). Five to fifteen minutes.

   ```powershell
   .\scripts\build-boost.ps1
   ```

3. Build. Detached, so a lost session does not kill it; follow the log. About six minutes on a 32-thread
   host for the 7.4 line (configure 67 s, `fdb_c` about 4 min, `fdbcli` 68 s).

   ```powershell
   Start-Process powershell -ArgumentList '-NoProfile','-ExecutionPolicy','Bypass','-File','.\scripts\build-fdb.ps1','-Tag','7.4.7' -WindowStyle Hidden
   Get-Content C:\fdb-build\7.4.7\build-7.4.7.log -Wait
   ```

   During the `fdb_c` and `fdbcli` steps the compile output goes to `C:\fdb-build\7.4.7\build-fdb_c.log`
   and `build-fdbcli.log`; follow those to watch progress. The main log ends with `=== done in hh:mm:ss ===` and the artifacts are in `.\artifacts\7.4.7\`. A failure
   ends with `BUILD FAILED: <reason>`; section 7 of `CLAUDE.md` maps each reason to its fix.

4. Verify. All four gates must print `PASS`; the smoke test needs Docker Desktop running and is skipped
   with a message otherwise.

   ```powershell
   .\scripts\verify-fdb.ps1 -ArtifactDir .\artifacts\7.4.7
   ```

## Verification gates

1. `fdbcli --version` reports the tag and the protocol of its line (`fdb00b074000000` for 7.4,
   `fdb00b073000000` for 7.3).
2. The export set of `fdb_c.dll` equals `reference\exports-<line>.txt` (111 `fdb_*` names).
3. Every `.sha256` file matches its binary.
4. The new `fdbcli.exe` creates a database on a `foundationdb/foundationdb:<tag>` container, `status
   minimal` reports it available, and a set/get round trip commits.

## Release handoff

Section 6 of `CLAUDE.md` is the routine; the session's parts are:

1. `.\scripts\release-body.ps1 -ArtifactDir .\artifacts\<tag>` renders `release-body.md`; hand it to the
   maintainer with the artifact directory and the verification output.
2. The maintainer creates and publishes the GitHub release `<tag>` on this repository with the body and
   the four Windows files. Never create or edit a release from a session.
3. `.\scripts\release-manifest.ps1 -Tag <tag>` checks the published release (assets present, every
   downloaded asset equal to the local `.sha256`) and writes `manifest-win-x64.json`; every gate must
   print `PASS`. Hand the snippet to whoever edits `FoundationDB.Client.Native/manifest.json`.

## When a hunk fails

`build-fdb.ps1` stops with the failing hunk in the log. Port it by hand in the checkout
(`git apply --reject`, fix the `.rej`), rebuild with `-SkipClone`, verify, then save `git diff` as
`patches\windows-<tag>.patch` and select it in `build-fdb.ps1`. `patches\README.md` states the intent of
every hunk so the port keeps it. A knob name that collides with a Windows macro (`expected ')'` with a
`winnt.h` note) takes an `#undef` after the header's includes; see `patches\extra\`.
