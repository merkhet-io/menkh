#!/usr/bin/env python3
"""Bundle a viewer/history and optionally the engine plus a self-contained job."""
import argparse
import json
from pathlib import Path
from zipfile import ZIP_DEFLATED, ZipFile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary-dir', type=Path, required=True)
    parser.add_argument('--history', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    parser.add_argument('--engine', type=Path, help='Bundle menkh.exe for viewer-owned calculation')
    parser.add_argument('--job', type=Path, help='Bundle a self-contained primitive job and calculate-demo.bat')
    args = parser.parse_args()
    history = json.loads(args.history.read_text())
    if history.get('format') != 'menkh-voxel-history-v1':
        parser.error('Expected menkh-voxel-history-v1')
    files = [(args.binary_dir / name, name) for name in ('menkh-viewer.exe', 'Voxel.hlsl')]
    if args.job and not args.engine:
        parser.error('--job requires --engine')
    if (args.binary_dir / "menkh.dll").is_file():
        files.append((args.binary_dir / "menkh.dll", "menkh.dll"))
    if args.engine:
        files.append((args.engine, 'menkh.exe'))
    if args.job:
        job = json.loads(args.job.read_text())
        if job.get('version') != 1:
            parser.error('Expected a version-1 job')
        if any(source and ('stl' in source or 'state_file' in source) for source in (job.get('stock'), job.get('target'), job.get('fixtures'))):
            parser.error('Bundled job must be self-contained; external STL/state assets are not packaged automatically')
        files.append((args.job, 'demo/job.json'))
    files.append((args.history, 'demo/voxel-animation.json'))
    names = {'initial.blocks', 'initial.pool'}
    provenance_names = {'surface-provenance.json', 'surface-provenance.bin'}
    present = {name for name in provenance_names if (args.history.parent / name).is_file()}
    if present and present != provenance_names:
        parser.error('Incomplete color data: both surface-provenance.json and .bin are required')
    colors = bool(present)
    names.update(present)
    for kind in ('target', 'fixture'):
        pair = {kind + '.blocks', kind + '.pool'}
        available = {name for name in pair if (args.history.parent / name).is_file()}
        if available and available != pair:
            parser.error(f'Incomplete {kind} grid: both .blocks and .pool are required')
        names.update(available)
    names.update(name for name in ('report.json', 'defects.json') if (args.history.parent / name).is_file())
    names.update(frame['file'] for frame in history['frames'])
    for name in sorted(names):
        if not isinstance(name, str) or '/' in name or '\\' in name or ':' in name or name in ('.', '..'):
            parser.error('History must use plain relative filenames')
        files.append((args.history.parent / name, 'demo/' + name))
    for source, _ in files:
        if not source.is_file():
            parser.error(f'Missing input: {source}')
    args.out.parent.mkdir(parents=True, exist_ok=True)
    with ZipFile(args.out, 'w', ZIP_DEFLATED) as archive:
        for source, destination in files:
            archive.write(source, destination)
        color_args = ' --color-operation --frame 0' if colors else ''
        archive.writestr('open-demo.bat', '@echo off\r\n"%~dp0menkh-viewer.exe" "%~dp0demo\\voxel-animation.json"' + color_args + '\r\nif errorlevel 1 pause\r\n')
        if colors:
            archive.writestr('open-colors.bat', '@echo off\r\n"%~dp0menkh-viewer.exe" "%~dp0demo\\voxel-animation.json" --color-operation\r\nif errorlevel 1 pause\r\n')
        if args.job:
            job_colors = ' --color-operation' if job.get('export_provenance') else ''
            archive.writestr('calculate-demo.bat', '@echo off\r\n"%~dp0menkh-viewer.exe" "%~dp0demo\\job.json"' + job_colors + '\r\nif errorlevel 1 pause\r\n')
        if args.engine:
            archive.writestr('CALCULATION.txt', '''The engine is bundled as menkh.exe. No Zig/compiler installation is needed.
Double-click menkh-viewer.exe and select a job JSON to calculate and inspect it.
If included, calculate-demo.bat opens the bundled job directly.
Progress and Cancel are shown during calculation; successful results open at the final frame.
Results/logs are retained in %LOCALAPPDATA%\\Menkh\\runs. Existing output is never overwritten.
Relative STL/state paths are resolved from the job directory; --working-dir overrides this.
When menkh.dll is included beside the viewer, calculation runs in process on a worker
thread. Otherwise the viewer runs the bundled CLI as a supervised background process.
Use --library PATH or --engine PATH to select explicitly. DLL cancellation waits for
an operation boundary. Add --live to inspect consistent material during calculation.
Live windows carry exposure colors when export_provenance is enabled in the job.
Target/fixture grids and retained-operation findings are also available during calculation.
''')
        archive.writestr('README.txt', '''Menkh Windows D3D12 viewer
Extract the entire ZIP, then double-click open-demo.bat.
Requires Windows x64 and a D3D12 graphics adapter. No Zig or Visual Studio needed.

Left drag: orbit. Right drag: pan. Wheel: zoom. R: reset.
Space: play/pause. Slider: scrub. Left/Right: step. Home/End: first/last.
B: background. T: tool visibility. A: antialiasing. X/Y/Z: section axis, [ / ]: section position.
G: target comparison. F: fixtures. V: target. S: stock.
Ctrl + left click: pick material. N: cycle retained contact findings.
C: cycle material / exposing operation / exposing tool colors when data is included.
open-colors.bat (when included) opens the colored final result directly.
Initial stock faces stay neutral. Colors mark cut faces, not all material.
One tool gives one tool color; operation colors distinguish individual cuts.
Playback is recorded geometry, not physical machining time.
If CALCULATION.txt is included, this package also runs jobs from the viewer.

Software rendering for troubleshooting (slower):
menkh-viewer.exe demo\\voxel-animation.json --warp

Source, build instructions, dependencies and limits:
https://github.com/merkhet-io/menkh/tree/main/viewer/windows
''')
        archive.write(Path(__file__).resolve().parent.parent / 'LICENSE', 'LICENSE.txt')
        archive.write(Path(__file__).resolve().parent.parent / 'viewer/windows/vendor/LICENSE.json', 'LICENSE.json.txt')
    print(f'{args.out}: {args.out.stat().st_size:,} bytes, {len(history["frames"])} recorded operations')


if __name__ == '__main__':
    main()
