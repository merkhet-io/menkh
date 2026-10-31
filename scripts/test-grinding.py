#!/usr/bin/env python3
"""Job contract, reference equality, checkpoint resume and viewer-ready wheel history."""
import argparse,copy,json,os,struct,subprocess
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--out',type=Path,default=Path('out/grinding-test'));a=p.parse_args();a.out.mkdir(parents=True,exist_ok=True)
exe=Path('zig-out/bin/menkh'+('.exe' if os.name=='nt' else '')).resolve()
job=dict(version=1,units='mm',bounds=dict(lo=[-2,-2,-2],hi=[2,2,2]),voxel_mm=.25,stock=dict(primitives=[dict(box=dict(lo=[-2,-2,-2],hi=[2,2,2]))]),tools=[dict(cutter=dict(kind='flat',radius=1.2,length=.7))],motion_tolerance_mm=.04,export_mesh=False,export_provenance=True,operations=[])
for i in range(4):
 def pose(t):return dict(position=[-.2+.1*t,.1,0],a_deg=10+17*t,c_deg=-20+30*t)
 job['operations'].append(dict(id=f'rotary-{i}',tool=0,rotary=dict(a=pose(i),b=pose(i+1))))
def run(name,j,reference=False,valid=True):
 file=a.out/(name+'.json');file.write_text(json.dumps(j));out=a.out/name
 result=subprocess.run([str(exe),'job',str(file),'--out',str(out)]+(['--reference'] if reference else []),capture_output=True)
 (a.out/(name+'.log')).write_bytes(result.stdout+result.stderr)
 assert (result.returncode==0)==valid,(name,result.stderr.decode())
 return out
def cells(path):
 b=path.read_bytes();count,slots=struct.unpack_from('<QQ',b,64);ds=struct.unpack_from('<'+'I'*count,b,96);pool=b[96+count*4:]
 assert len(pool)==slots*64
 return [bytes(64) if d==0xffffffff else bytes([255])*64 if d==0xfffffffe else pool[d*64:(d+1)*64] for d in ds]
full=run('full',job);ref=run('reference',job,True)
assert cells(full/'final.menkh')==cells(ref/'final.menkh')
first=copy.deepcopy(job);first['operations']=first['operations'][:2];one=run('first',first)
second=copy.deepcopy(job);second['operations']=second['operations'][2:];second['stock']=dict(state_file=str((one/'final.menkh').resolve()));two=run('resume',second)
assert cells(full/'final.menkh')==cells(two/'final.menkh')
for kind in ['ball','feed','assembly','ambiguous','bad-angle','bad-tolerance']:
 bad=copy.deepcopy(job)
 if kind=='ball':bad['tools'][0]['cutter']=dict(kind='ball',radius=1,length=2)
 elif kind=='feed':bad['operations'][0]['feed_mm_min']=20
 elif kind=='assembly':bad['tools'][0]['holder']=dict(radius=2,length=1,offset=1)
 elif kind=='ambiguous':bad['operations'][0]['line']=dict(a=dict(position=[0,0,0]),b=dict(position=[1,0,0]))
 elif kind=='bad-angle':bad['operations'][0]['rotary']['a']['a_deg']=1000001
 else:bad['motion_tolerance_mm']=0
 run(kind,bad,valid=False)
report=json.loads((full/'report.json').read_text());assert all(o['motion_over_removal_bound_mm']<=job['motion_tolerance_mm']+1e-12 for o in report['operations'])
history=json.loads((full/'voxel-animation.json').read_text());assert all(f['cutter']['radius']==1.2 and len(f['axis'])==3 for f in history['frames'])
print('Rotary job: scalar equality, checkpoint/resume equality, six rejected contracts, bounds and viewer poses passed')

for label,points in [('crowned',[(0,.8),(.35,1.2),(.7,.8)]),('waisted',[(0,1.2),(.35,.4),(.7,1.2)])]:
 profile=copy.deepcopy(job);profile['tools'][0]['cutter'].update(kind='profile',profile=[dict(z=z,radius=r) for z,r in points])
 result=run(label,profile);reference=run(label+'-reference',profile,True)
 assert cells(result/'final.menkh')==cells(reference/'final.menkh')
 first=copy.deepcopy(profile);first['operations']=first['operations'][:2];checkpoint=run(label+'-first',first)
 resumed=copy.deepcopy(profile);resumed['operations']=resumed['operations'][2:];resumed['stock']=dict(state_file=str((checkpoint/'final.menkh').resolve()))
 final=run(label+'-resume',resumed);assert cells(result/'final.menkh')==cells(final/'final.menkh')
 report=json.loads((result/'report.json').read_text());assert all(o['motion_over_removal_bound_mm']<=profile['motion_tolerance_mm']+1e-12 for o in report['operations'])
 history=json.loads((result/'voxel-animation.json').read_text());assert all(f['cutter']['profile']==profile['tools'][0]['cutter']['profile'] for f in history['frames'])
 repeat=copy.deepcopy(profile);repeat['operations'] += [dict(op,id=op['id']+'-again') for op in profile['operations']]
 repeated=run(label+'-repeat',repeat);assert cells(result/'final.menkh')==cells(repeated/'final.menkh')
 bad=copy.deepcopy(profile);bad['tools'][0]['cutter']['profile'][1]['z']=0;run(label+'-invalid',bad,valid=False)
print('Crowned/waisted profiles: reference equality, resume, idempotence, declared bounds, history metadata and invalid input passed')

# Stationary, tiny, axial and diagonal translations with fixed orientation.
for name,end in [('stationary',[0,0,0]),('tiny',[1e-12,0,0]),('axial',[0,0,.5]),('diagonal',[.3,-.2,.4])]:
 fixed=copy.deepcopy(profile);fixed['operations']=[dict(id=name,tool=0,rotary=dict(a=dict(position=[0,0,0],a_deg=0,c_deg=0),b=dict(position=end,a_deg=0,c_deg=0)))]
 result=run(name,fixed);reference=run(name+'-reference',fixed,True)
 assert cells(result/'final.menkh')==cells(reference/'final.menkh')
 reverse=copy.deepcopy(fixed);r=reverse['operations'][0]['rotary'];r['a'],r['b']=r['b'],r['a'];rev=run(name+'-reverse',reverse)
 assert cells(result/'final.menkh')==cells(rev/'final.menkh')
print('Profile stationary, tiny, axial, diagonal and reversed motion passed')
