#!/usr/bin/env python3
"""Independent C11 hosts against shared and static libraries, jobs and history."""
import copy,json,os,shutil,subprocess,tempfile
from pathlib import Path
out=Path('out/sdk');out.mkdir(parents=True,exist_ok=True)
env=os.environ.copy()
if os.name=='nt':
    compiler=[str(Path('.tools/zig-x86_64-windows-0.15.2/zig.exe')),'cc'];suffix='.exe'
    env['PATH']=str(Path('zig-out/bin').resolve())+os.pathsep+str(Path('zig-out/lib').resolve())+os.pathsep+env.get('PATH','');extra=[]
else:
    compiler=['xcrun','clang'];suffix='';extra=['-Wl,-rpath,'+str(Path('zig-out/lib').resolve())]
def build(source,name,static=False):
    exe=out/(name+suffix)
    subprocess.run(compiler+['-std=c11','-Wall','-Wextra','-Werror',source,'-Izig-out/include','-Lzig-out/lib','-lmenkh-static' if static else '-lmenkh',*extra,'-o',str(exe)],check=True)
    return exe.resolve()
for static in [False,True]:
    exe=build('examples/embed.c','embed-static' if static else 'embed',static)
    subprocess.run([str(exe),str(out/('static.menkh' if static else 'final.menkh'))],env=env,check=True)
assert (out/'static.menkh').read_bytes()==(out/'final.menkh').read_bytes()
host=build('examples/run_job.c','run-job');engine=Path('zig-out/bin/menkh'+suffix).resolve()
subprocess.run([str(engine),'inspect-state',str(out/'final.menkh')],check=True)
root=Path(tempfile.mkdtemp(prefix='jobs-',dir=out.resolve()));source=root/'input café';source.mkdir()
shutil.copyfile(out/'final.menkh',source/'stock.menkh')
job={'version':1,'units':'mm','bounds':{'lo':[0,0,0],'hi':[4,3,1]},'voxel_mm':.1,'stock':{'state_file':'stock.menkh'},'export_mesh':False,'tools':[{'cutter':{'kind':'flat','radius':.2,'length':1}}], 'operations':[{'id':f'cut-{i}','tool':0,'line':{'a':{'position':[.5+i*.1,1,.2]},'b':{'position':[2+i*.1,1,.2]}}} for i in range(4)]}
file=source/'job.json';file.write_text(json.dumps(job))
def run(dest,cancel=None,code=0,path=file):
    result=subprocess.run([str(host),str(path),str(root/dest),str(source)]+([] if cancel is None else [str(cancel)]),env=env,capture_output=True,text=True)
    assert result.returncode==code,(result.stdout,result.stderr)
    return root/dest
complete=run('complete')
before=(complete/'final.menkh').read_bytes();run('complete',code=1);assert (complete/'final.menkh').read_bytes()==before
subprocess.run([str(engine),'job',str(file),'--out',str(root/'cli')],cwd=source,check=True,stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL)
assert (complete/'final.menkh').read_bytes()==(root/'cli/final.menkh').read_bytes()
for cancel in [0,1,3]:
    partial=run(f'cancel-{cancel}',cancel,2);assert not (partial/'voxel-animation.json').exists()
    if cancel:assert len(list(partial.glob('step-*.delta')))==cancel
bad=copy.deepcopy(job);bad['version']=99;invalid=source/'invalid.json';invalid.write_text(json.dumps(bad));failed=run('invalid',code=1,path=invalid);assert 'UnsupportedJobVersion' in (failed/'simulation.log').read_text()
# Separate calls use their supplied working directory without changing process cwd.
assert Path.cwd()==Path(__file__).resolve().parents[1]
print('Shared/static ABI, copied history, whole-job CLI equality, relative paths and cancellation boundaries passed')
