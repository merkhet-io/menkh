# Windows CLI and benchmark

The Zig engine, CLI, checkpoint inspection and CPU predicate benchmark have an
experimental Windows x86-64 build. The Swift/Metal viewer remains macOS-only.
MSVC does not compile the Zig sources; no Visual Studio version or C++ toolset is
required. This is not a C++ port or an MSVC SDK integration. Visual Studio can be
used as an editor and to launch the PowerShell commands.

From a PowerShell terminal in the repository:

```powershell
.\scripts\bootstrap-zig.ps1
.\zig.ps1 build -Doptimize=ReleaseFast
.\zig.ps1 build test --summary all
.\zig.ps1 build test -Doptimize=ReleaseFast --summary all
.\zig-out\bin\menkh.exe job examples/pocket-25um.json --out out/windows-pocket
.\zig-out\bin\menkh.exe inspect-state out/windows-pocket/final.menkh
.\zig.ps1 build kernel-bench -Doptimize=ReleaseFast > out/predicate-benchmark.json
```

The bootstrap downloads the pinned Zig 0.15.2 archive into `.tools`, verifies its
SHA-256 against the [official download index](https://ziglang.org/download/index.json),
and changes no global installation or PATH. The checked-in pocket job requires
no Python. It is the 325-segment 25 µm video job with mesh export disabled.

Native Windows builds use the host target/CPU. To make portable x86-64 binaries,
pass `-Dtarget=x86_64-windows -Dcpu=baseline`. For performance comparisons on Jens'
Ryzen, use a native build on that machine and record the emitted CPU model.
Do not assume a particular AVX-512 instruction sequence from `@Vector(8, f64)`:
the compiler selects instructions for the requested CPU.

Windows memory reports use peak working-set bytes via Zig's process memory API;
macOS uses peak RSS bytes. Those OS counters are related measurements, not an
identical cross-platform accounting contract. Query failures are errors, not zero
memory readings. Cutting and storage formats do not depend on the platform module.

Validation: the CLI and kernel benchmark were cross-compiled on macOS. The
`windows-cli` GitHub Actions job builds and executes Debug/ReleaseFast tests and
the 25 µm pocket plus exact remaining-material/surface-count checks. Consult its
run result before treating Windows runtime validation as complete. No Windows
viewer, Visual Studio project, MSVC-built library or C ABI is provided.
