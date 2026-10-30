#!/usr/bin/env python3
"""Frozen imported finishing workflow: generation, repeats, resume, accuracy, Metal evidence."""
import argparse, copy, hashlib, json, pathlib, platform, statistics, subprocess, time, shutil
from importlib.util import spec_from_file_location,module_from_spec
ROOT=pathlib.Path(__file__).resolve().parents[1]
def load(name):
    spec=spec_from_file_location(name,ROOT/'scripts'/f'{name}.py');m=module_from_spec(spec);spec.loader.exec_module(m);return m
fixture=load('finishing-fixture');inspection=load('finishing-inspect')
def write(path,value):path.parent.mkdir(parents=True,exist_ok=True);path.write_text(json.dumps(value,indent=2)+'\n')
def execute(exe,job,dest,reference=False,profile=False):
    dest.mkdir(parents=True,exist_ok=True);jobfile=dest/'job.json';write(jobfile,job);start=time.perf_counter()
    with (dest/'run.log').open('w') as log:
        try:
            p=subprocess.Popen([str(exe),'job',str(jobfile),'--out',str(dest)]+(['--reference'] if reference else []),stdout=log,stderr=log)
            sampled=False
            while p.poll() is None:
                if time.perf_counter()-start>900:
                    p.kill();p.wait();raise subprocess.TimeoutExpired(p.args,900)
                if profile and not sampled and (dest/'run.log').stat().st_size>0 and shutil.which('sample'):
                    subprocess.run(['sample',str(p.pid),'1','-file',str(dest/'cpu-sample.txt')],stdout=subprocess.DEVNULL,stderr=subprocess.DEVNULL);sampled=True
                time.sleep(.05)
        except subprocess.TimeoutExpired:
            write(dest/'failure.json',dict(reason='900 second timeout',wall_s=time.perf_counter()-start));raise
    if p.returncode:raise RuntimeError(f'Job failed; see {dest}/run.log')
    report=json.loads((dest/'report.json').read_text());report['wall_s']=time.perf_counter()-start
    if report['process_peak_rss_bytes']>16*1024**3:raise RuntimeError('Protocol 16 GiB RSS limit exceeded')
    return report

def main():
    p=argparse.ArgumentParser(description=__doc__);p.add_argument('--smoke',action='store_true');p.add_argument('--no-viewer',action='store_true');p.add_argument('--out',type=pathlib.Path,default=ROOT/'out/finishing-workflow');p.add_argument('--repeats',type=int,default=2);p.add_argument('--skip-build',action='store_true');args=p.parse_args()
    if args.repeats<2:p.error('At least two measured repetitions required')
    out=args.out.resolve();out.mkdir(parents=True,exist_ok=True);exe=ROOT/'zig-out/bin/menkh'
    if not args.skip_build:subprocess.run([str(ROOT/'zig'),'build','-Doptimize=ReleaseFast'],cwd=ROOT,check=True)
    fixture.generate(out/'fixture',.25 if args.smoke else .025);job=json.loads((out/'fixture/job.json').read_text())
    metadata=dict(protocol='v1',source_identity_note='Commit plus working-tree file hashes; hashes identify uncommitted implementation precisely',source_commit=subprocess.check_output(['git','rev-parse','HEAD'],cwd=ROOT,text=True).strip(),source_sha256={str(f.relative_to(ROOT)):hashlib.sha256(f.read_bytes()).hexdigest() for f in sorted((ROOT/'src').glob('*.zig'))},binary_sha256=hashlib.sha256(exe.read_bytes()).hexdigest(),job_sha256=hashlib.sha256((out/'fixture/job.json').read_bytes()).hexdigest(),fixture_sha256={f.name:hashlib.sha256(f.read_bytes()).hexdigest() for f in (out/'fixture').glob('*.stl')},platform=platform.platform(),zig=subprocess.check_output([str(ROOT/'zig'),'version'],text=True).strip(),mode='ReleaseFast',workers=1)
    write(out/'identifiers.json',metadata)
    runs=[];expected=None
    for i in range(args.repeats+1):
        dest=out/f'run-{i}';r=execute(exe,job,dest,profile=i==0);digest=inspection.digest(dest/'final.menkh');expected=expected or digest;assert expected==digest
        runs.append(dict(warmup=i==0,report=r,occupancy_sha256=digest));write(out/'raw.json',runs);print(f'Run {i}: {r["wall_s"]:.3f} seconds',flush=True)
    mid=len(job['operations'])//2;first=copy.deepcopy(job);first['operations']=first['operations'][:mid]
    resume_records={'first':execute(exe,first,out/'checkpoint')}
    rest=copy.deepcopy(job);rest['operations']=rest['operations'][mid:];rest['stock']={'state_file':str(out/'checkpoint/final.menkh')}
    resume_records['resumed']=execute(exe,rest,out/'resumed');assert inspection.digest(out/'resumed/final.menkh')==expected
    subprocess.run([str(exe),'compact-state',str(out/'checkpoint/final.menkh'),str(out/'compact.menkh')],check=True)
    rest['stock']={'state_file':str(out/'compact.menkh')};resume_records['compacted_resumed']=execute(exe,rest,out/'compacted-resumed');assert inspection.digest(out/'compacted-resumed/final.menkh')==expected
    write(out/'resume.json',dict(occupancy_sha256=expected,exact=True,checkpoint_bytes=(out/'checkpoint/final.menkh').stat().st_size,compacted_bytes=(out/'compact.menkh').stat().st_size,reports=resume_records))
    inspection.inspect(out/'fixture/job.json',out/'run-0/final.menkh',out/'geometry.json')
    if not args.smoke:
        matrix=[]
        for h in [.25,.1,.05]:
            j=copy.deepcopy(job);j['voxel_mm']=h;matrix.append(execute(exe,j,out/f'grid-{h}'))
        write(out/'resolution-matrix.json',matrix)
        tighter=copy.deepcopy(job);tighter['motion_tolerance_mm']=.001
        sensitivity=execute(exe,tighter,out/'tolerance-0.001');write(out/'tolerance-sensitivity.json',sensitivity)
        inspection.accuracy.run(exe,out/'analytic')
    if not args.no_viewer:
        subprocess.run([str(ROOT/'scripts/build-viewer.sh')],cwd=ROOT,check=True)
        viewer=ROOT/'zig-out/bin/menkh-viewer';write(out/'viewer-identifiers.json',dict(binary_sha256=hashlib.sha256(viewer.read_bytes()).hexdigest(),shader_sha256=hashlib.sha256((viewer.parent/'Voxel.metal').read_bytes()).hexdigest()));history=out/'run-0/voxel-animation.json';common=[str(viewer),str(history),'--frame',str(len(job['operations'])),'--target-z','4']
        for name,extra in [('final',[]),('comparison',['--compare-target']),('rib-section',['--compare-target','--section-axis','y','--section','.5','--yaw','.8']),('pocket-section',['--compare-target','--section-axis','x','--section','.34'])]:
            subprocess.run(common+['--hide-tool','--snapshot',str(out/(name+'.png'))]+extra,check=True,timeout=120)
        subprocess.run([str(viewer),str(history),'--frame',str(len(job['operations'])),'--target-z','6','--distance','45','--snapshot',str(out/'assembly.png'),'--pick-center'],check=True,timeout=120)
        subprocess.run(common+['--verify-history',str(out/'replay.json')],check=True,timeout=120)
        subprocess.run(common+['--render-bench',str(out/'render.json'),'--compare-target'],check=True,timeout=120)
    measured=[x['report'] for x in runs[1:]]
    def stat(v):return dict(min=min(v),median=statistics.median(v),max=max(v))
    summary=dict(warmups=1,repeats=args.repeats,wall_seconds=stat([r['wall_s'] for r in measured]),cut_seconds=stat([sum(o['cut_ns'] for o in r['operations'])/1e9 for r in measured]),peak_rss_bytes=max(r['process_peak_rss_bytes'] for r in measured),remaining_voxels=measured[0]['remaining_occupied'],target_comparison=measured[0]['target_comparison'],resume_exact=True,occupancy_sha256=expected)
    write(out/'summary.json',summary);print(json.dumps(summary,indent=2))
    size=sum(f.stat().st_size for f in out.rglob('*') if f.is_file());assert size<=8*1024**3,'Protocol output budget exceeded'
if __name__=='__main__':main()
