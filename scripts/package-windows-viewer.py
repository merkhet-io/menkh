#!/usr/bin/env python3
"""Bundle a built viewer and one existing voxel history; no build or simulation."""
import argparse
import json
from pathlib import Path
from zipfile import ZIP_DEFLATED, ZipFile


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--binary-dir', type=Path, required=True)
    parser.add_argument('--history', type=Path, required=True)
    parser.add_argument('--out', type=Path, required=True)
    args = parser.parse_args()
    history = json.loads(args.history.read_text())
    if history.get('format') != 'menkh-voxel-history-v1':
        parser.error('Expected menkh-voxel-history-v1')
    files = [(args.binary_dir / name, name) for name in ('menkh-viewer.exe', 'Voxel.hlsl')]
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
        archive.writestr('README.txt', '''Menkh Windows D3D12 viewer
Extract the entire ZIP, then double-click open-demo.bat.
Requires Windows x64 and a D3D12 graphics adapter. No Zig or Visual Studio needed.

Left drag: orbit. Right drag: pan. Wheel: zoom. R: reset.
Space: play/pause. Slider: scrub. Left/Right: step. Home/End: first/last.
B: background. T: tool visibility. A: antialiasing. [ / ]: Z section.
Playback is recorded geometry, not live simulation or physical machining time.

Software rendering for troubleshooting (slower):
menkh-viewer.exe demo\\voxel-animation.json --warp

Source, build instructions, dependencies and limits:
https://github.com/merkhet-io/menkh/tree/codex/windows-d3d12-viewer/viewer/windows
''')
        archive.write(Path(__file__).resolve().parent.parent / 'viewer/windows/vendor/LICENSE.json', 'LICENSE.json.txt')
    print(f'{args.out}: {args.out.stat().st_size:,} bytes, {len(history["frames"])} recorded operations')


if __name__ == '__main__':
    main()
