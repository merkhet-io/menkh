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
        archive.writestr('open-demo.bat', '@echo off\r\n"%~dp0menkh-viewer.exe" "%~dp0demo\\voxel-animation.json"\r\nif errorlevel 1 pause\r\n')
        if args.job:
            archive.writestr('calculate-demo.bat', '@echo off\r\n"%~dp0menkh-viewer.exe" "%~dp0demo\\job.json"\r\nif errorlevel 1 pause\r\n')
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
an operation boundary. Only completed results are loaded; live inspection is not implemented.
''')
        archive.writestr('README.txt', '''Menkh Windows D3D12 viewer
Extract the entire ZIP, then double-click open-demo.bat.
Requires Windows x64 and a D3D12 graphics adapter. No Zig or Visual Studio needed.

Left drag: orbit. Right drag: pan. Wheel: zoom. R: reset.
Space: play/pause. Slider: scrub. Left/Right: step. Home/End: first/last.
B: background. T: tool visibility. A: antialiasing. [ / ]: Z section.
Playback is recorded geometry, not physical machining time.
If CALCULATION.txt is included, this package also runs jobs from the viewer.

Software rendering for troubleshooting (slower):
menkh-viewer.exe demo\\voxel-animation.json --warp

Source, build instructions, dependencies and limits:
https://github.com/merkhet-io/menkh/tree/main/viewer/windows
''')
        archive.write(Path(__file__).resolve().parent.parent / 'viewer/windows/vendor/LICENSE.json', 'LICENSE.json.txt')
    print(f'{args.out}: {args.out.stat().st_size:,} bytes, {len(history["frames"])} recorded operations')


if __name__ == '__main__':
    main()
