#!/usr/bin/env python3
"""Independent cell-chronology and comparison oracle for leased live windows."""
import argparse, atexit, hashlib, json, os, random, shutil, struct, subprocess, time
from pathlib import Path
if os.name == 'nt':
    import msvcrt
    def acquire(f): msvcrt.locking(f.fileno(), msvcrt.LK_NBRLCK, 1)
else:
    import fcntl
    def acquire(f): fcntl.flock(f, fcntl.LOCK_SH | fcntl.LOCK_NB)
p = argparse.ArgumentParser(description=__doc__)
p.add_argument('--out', type=Path, default=Path('out/live-overlays'))
p.add_argument('--reader', type=Path)
p.add_argument('--viewer', action='store_true')
p.add_argument('--render', action='store_true')
a = p.parse_args()
root = a.out.resolve(); root.mkdir(parents=True, exist_ok=False)
exe = Path('zig-out/bin/menkh' + ('.exe' if os.name == 'nt' else '')).resolve()
bounds = dict(lo=[-.83, -.94, -.62], hi=[.84, .93, .65])
job = dict(version=1, units='mm', bounds=bounds, voxel_mm=.1,
    stock=dict(primitives=[dict(box=bounds)]),
    target=dict(primitives=[dict(sphere=dict(center=[.03, -.02, .01], radius=.68))]),
    fixtures=dict(primitives=[dict(box=dict(lo=[.6, .5, -.62], hi=[.84, .93, .3]))]),
    tools=[dict(cutter=dict(kind='flat', radius=.19, length=1), shank=dict(radius=.2, length=.3, offset=1)),
           dict(cutter=dict(kind='flat', radius=.27, length=1))],
    export_mesh=False, export_provenance=True, provenance_scope='all_frames', operations=[])
job['operations'] += [dict(id='enclosed cavity', subtract=dict(sphere=dict(center=[.13, .04, .01], radius=.23))),
    dict(id='disconnect', subtract=dict(box=dict(lo=[-.05, -.94, -.62], hi=[.06, .93, .65])))]
rng = random.Random(246)
for i in range(60):
    if i % 3:
        x=rng.uniform(-.8,.8); y=rng.uniform(-.8,.8); z=rng.uniform(-.1,.5)
        job['operations'].append(dict(id=f'cut-{i}', tool=i%2, line=dict(a=dict(position=[x,y,z]), b=dict(position=[x+.12,y+.04,z]))))
    else:
        job['operations'].append(dict(id=f'void-{i}', subtract=dict(sphere=dict(center=[rng.uniform(-.8,.8),rng.uniform(-.8,.8),rng.uniform(-.5,.6)],radius=.14))))
for i in range(538):
    op=dict(job['operations'][2+i%60]);op['id']=f'idempotent-{i}';job['operations'].append(op)
opts=dict(history_operations=8, publish_every_operations=1, min_publish_ms=0, start_paused=True,
          max_snapshot_bytes=1024*1024,max_provenance_bytes=128*1024,max_asset_bytes=128*1024)
children=[]
@atexit.register
def cleanup():
    for child in children:
        if child.poll() is None: child.kill();child.wait()
def read(path):
    try:return json.loads(path.read_text())
    except (FileNotFoundError,PermissionError,json.JSONDecodeError):return {}
def launch(name, config):
    file=root/(name+'.json');file.write_text(json.dumps(config));out=root/name
    with (root/(name+'.log')).open('w') as log:
        child=subprocess.Popen([str(exe),'job',str(file),'--out',str(out)],stdout=log,stderr=log)
    children.append(child);return child,out
def wait(predicate,child=None):
    until=time.monotonic()+60
    while time.monotonic()<until:
        value=predicate()
        if value:return value
        if child and child.poll() is not None:raise AssertionError((child.returncode,'early exit'))
        time.sleep(.001)
    raise AssertionError('timeout')
def lease(out):
    pointer=read(out/'live/latest.json')
    if not pointer:return
    f=(out/f"live/slot-{pointer['slot']}.lock").open('rb')
    try:acquire(f)
    except OSError:f.close();return
    slot=out/f"live/slot-{pointer['slot']}";meta=read(slot/'voxel-animation.json')
    if meta.get('live_sequence')!=pointer['sequence']:f.close();return
    return f,slot,meta
child,baseline=launch('baseline',job);assert child.wait(timeout=60)==0
h=read(baseline/'voxel-animation.json');n=h['grid'];nb=h['block_grid'];cells=n[0]*n[1]*n[2];FULL=0xfffffffe;EMPTY=0xffffffff
def coords(b,bit):return (b%nb[0]*8+bit%8,b//nb[0]%nb[1]*8+bit//8%8,b//(nb[0]*nb[1])*8+bit//64)
def key(p):return (p[2]*n[1]+p[1])*n[0]+p[0]
def inside(p):return all(0<=p[i]<n[i] for i in range(3))
valid=[sum(1<<bit for bit in range(512) if inside(coords(b,bit))) for b in range(nb[0]*nb[1]*nb[2])]
def material(folder,prefix='initial'):
    raw=(folder/(prefix+'.blocks')).read_bytes();pool=(folder/(prefix+'.pool')).read_bytes();state=[]
    for b,(d,) in enumerate(struct.iter_unpack('<I',raw)):
        state.append(0 if d==EMPTY else valid[b] if d==FULL else int.from_bytes(pool[d*64:(d+1)*64],'little'))
    return state
def occupied(state):
    result=set()
    for b,bits in enumerate(state):
        while bits:
            bit=(bits&-bits).bit_length()-1;bits&=bits-1;result.add(key(coords(b,bit)))
    return result
def replay(state,raw):
    result=state.copy();off=0
    while off<len(raw):
        b,old,new=struct.unpack_from('<III',raw,off);off+=12;words=[]
        for d in [old,new]:
            words.append(0 if d==EMPTY else valid[b] if d==FULL else int.from_bytes(raw[off:off+64],'little'));off+=64 if d<FULL else 0
        assert words[0]==result[b];assert not words[1]&~words[0];result[b]=words[1]
    return result
states=[material(baseline)];when={};tools={};occupancies=[occupied(states[0])]
for index,step in enumerate(h['frames'],1):
    state=replay(states[-1],(baseline/step['file']).read_bytes());current=occupied(state)
    for k in occupancies[-1]-current:
        when[k]=index;tools[k]=job['operations'][index-1].get('tool',-1)+1
    states.append(state);occupancies.append(current)
target=occupied(material(baseline,'target'));fixture=occupied(material(baseline,'fixture'))
samples=[]
def validate(slot,meta,save=True):
    start=meta['first_operation'];end=meta['completed_operations'];header=read(slot/'surface-provenance.json')
    assert header['format']=='menkh-live-provenance-v1' and header['first_operation']==start and header['completed_operations']==end
    entries=list(struct.iter_unpack('<QII',(slot/'surface-provenance.bin').read_bytes()))
    assert [x[0] for x in entries]==sorted(set(x[0] for x in entries))
    labels={k:(op,t) for k,op,t in entries}
    for k,op,t in entries:assert (op,t)==(when[k],tools[k]) and op<=end
    state=material(slot);oracle=[]
    for local in range(end-start+1):
        global_frame=start+local;assert state==states[global_frame];stock=occupancies[global_frame];neighbors=set()
        for k in stock:
            p=[k%n[0],k//n[0]%n[1],k//(n[0]*n[1])]
            for axis in range(3):
                for side in [-1,1]:
                    q=p.copy();q[axis]+=side
                    if inside(q) and key(q) not in stock:neighbors.add(key(q))
        expected=[]
        for k in neighbors:
            actual=labels.get(k,(0,0));actual=actual if actual[0]<=global_frame else (0,0)
            wanted=(when[k],tools[k]) if k in when and when[k]<=global_frame else (0,0)
            assert actual==wanted,(start,global_frame,k,actual,wanted)
            expected.append([k,*wanted])
        # Query future removals too: none may leak into an earlier frame.
        for k,op,t in entries:
            if op>global_frame:expected.append([k,0,0])
        oracle.append(dict(frame=local,neighbors=expected,excess_voxels=len(stock-target),missing_voxels=len(target-stock)))
        if local<len(meta['frames']):state=replay(state,(slot/meta['frames'][local]['file']).read_bytes())
    if save:
        dest=root/'samples'/f"window-{meta['live_sequence']}"
        if not dest.exists():shutil.copytree(slot,dest)
        # Captured samples are no longer live. Copy the immutable assets once
        # to the fixed sibling path expected by both native readers.
        assets=root/'samples/assets'
        if not assets.exists():shutil.copytree(slot.parent/'assets',assets)
        (dest/'oracle.json').write_text(json.dumps(oracle))
        if a.reader:
            command=[str(a.reader.resolve()),str(dest/'voxel-animation.json')]
            if a.viewer:command+=['--verify-provenance-oracle']
            command+=[str(dest/'oracle.json')]
            result=subprocess.run(command,capture_output=True,timeout=60);assert result.returncode==0,result.stderr.decode(errors='replace')
        samples.append(dict(sequence=meta['live_sequence'],first=start,last=end,entries=len(entries),frames_checked=len(oracle)))
child,out=launch('stream',dict(job,live_inspection=opts));wait(lambda:read(out/'live/status.json').get('state')=='paused',child)
held=wait(lambda:lease(out),child);held_path=held[1];held_hash={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in held[1].iterdir()}
asset_hash={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in (out/'live/assets').iterdir()}
(out/'live/pause').unlink();seen=set();captured=[]
shutil.copytree(out/'live/assets',root/'samples/assets')
while child.poll() is None:
    current=lease(out)
    if current:
        f,slot,meta=current
        if meta['live_sequence'] not in seen and len(seen)<64:
            dest=root/'samples'/f"window-{meta['live_sequence']}";shutil.copytree(slot,dest);captured.append((dest,meta));seen.add(meta['live_sequence'])
        f.close()
    if len(seen)>=5 and held is not None:
        assert held_hash=={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in held_path.iterdir()};held[0].close();held=None
    time.sleep(.001)
assert child.returncode==0,(root/'stream.log').read_text()[-3000:]
if held is not None:
    assert held_hash=={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in held_path.iterdir()};held[0].close()
for slot,meta in captured:validate(slot,meta)
current=wait(lambda:lease(out));assert current[2]['completed_operations']<=len(job['operations'])
if current[2]['live_sequence'] not in seen:validate(current[1],current[2])
current[0].close()
assert any(s['first']>0 for s in samples)
assert asset_hash=={p.name:hashlib.sha256(p.read_bytes()).hexdigest() for p in (out/'live/assets').iterdir()}
assert (out/'final.menkh').read_bytes()==(baseline/'final.menkh').read_bytes()
for name,extra in [('provenance-limit',dict(max_provenance_bytes=16)),('asset-limit',dict(max_asset_bytes=16)),('payload-limit',dict(max_snapshot_bytes=4096))]:
    child,bad=launch(name,dict(job,live_inspection=dict(opts,**extra,start_paused=False)))
    assert child.wait(timeout=60)!=0 and not (bad/'voxel-animation.json').exists()
if a.render:
    assert os.name=='nt' and a.viewer and a.reader
    chosen=next(s for s in samples if s['first']>0 and s['last']>s['first'])
    sample=root/'samples'/f"window-{chosen['sequence']}";images=root/'images';images.mkdir()
    for name,flags in [('material',[]),('operation',['--color-operation']),('tool',['--color-tool']),('comparison',['--compare-target']),('section',['--compare-target','--section','.55']),('fixtures',['--hide-stock'])]:
        image=images/(name+'.ppm');report=images/(name+'.json')
        command=[str(a.reader.resolve()),str(sample/'voxel-animation.json'),'--warp','--debug','--frame',str(chosen['last']-chosen['first']),'--hide-tool','--snapshot',str(image),'--inspection-report',str(report)]
        if name!='fixtures':command+=['--hide-fixtures']
        command+=flags
        result=subprocess.run(command,capture_output=True,timeout=90);assert result.returncode==0,result.stderr.decode(errors='replace')
        assert b'D3D12: ' not in result.stderr,result.stderr.decode(errors='replace')
        report=read(report);stock=occupancies[chosen['last']]
        assert report['comparison']['excess_voxels']==len(stock-target) and report['comparison']['missing_voxels']==len(target-stock)
    material=(images/'material.ppm').read_bytes()
    for name in ['operation','tool','comparison','section','fixtures']:assert (images/(name+'.ppm')).read_bytes()!=material,name
    assert (images/'operation.ppm').read_bytes()!=(images/'tool.ppm').read_bytes()
summary=dict(samples=samples,independent_face_chronology=True,immutable_assets=True,held_window=True,final_exact=True,limits_fail_explicitly=True,live=read(out/'report.json')['live_publication'])
(root/'validation.json').write_text(json.dumps(summary,indent=2));print(json.dumps(dict(windows=len(samples),frames=sum(s['frames_checked'] for s in samples),**{k:v for k,v in summary.items() if k!='samples'}),indent=2))
