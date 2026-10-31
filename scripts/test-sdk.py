#!/usr/bin/env python3
"""Build an independent C11 host against the installed shared library."""
import os,subprocess
from pathlib import Path
out=Path('out/sdk');out.mkdir(parents=True,exist_ok=True)
if os.name=='nt':
    zig=Path('.tools/zig-x86_64-windows-0.15.2/zig.exe')
    # bootstrap location is selected by the repository wrapper; find the local compiler.
    choices=list(Path('.tools').glob('**/zig.exe'))
    if not zig.exists():
        assert choices,'Run the repository bootstrap first';zig=choices[0]
    exe=out/'embed.exe'
    subprocess.run([str(zig),'cc','-std=c11','examples/embed.c','-Izig-out/include','-Lzig-out/lib','-lmenkh','-o',str(exe)],check=True)
    env=os.environ.copy();env['PATH']=str(Path('zig-out/bin').resolve())+os.pathsep+str(Path('zig-out/lib').resolve())+os.pathsep+env.get('PATH','')
else:
    exe=out/'embed';env=os.environ.copy()
    subprocess.run(['xcrun','clang','-std=c11','-Wall','-Wextra','-Werror','examples/embed.c','-Izig-out/include','-Lzig-out/lib','-lmenkh','-Wl,-rpath,'+str(Path('zig-out/lib').resolve()),'-o',str(exe)],check=True)
subprocess.run([str(exe),str(out/'final.menkh')],env=env,check=True)
engine=Path('zig-out/bin/menkh'+('.exe' if os.name=='nt' else ''))
subprocess.run([str(engine),'inspect-state',str(out/'final.menkh')],check=True)
