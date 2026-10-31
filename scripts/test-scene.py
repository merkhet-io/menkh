#!/usr/bin/env python3
"""Scene ownership/placement against independently specified ordinary jobs."""
import argparse, copy, json, os, struct, subprocess
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('--out',type=Path,default=Path('out/scene-test'));p.add_argument('--reader',type=Path);p.add_argument('--viewer',action='store_true');a=p.parse_args()
root=a.out.resolve();root.mkdir(parents=True,exist_ok=True)
exe=Path('zig-out/bin/menkh'+('.exe' if os.name=='nt' else '')).resolve()
scene=json.loads(Path('examples/two-workpieces.json').read_text())
def run_scene(name,config,ok=True):
 source=root/(name+'.json');source.write_text(json.dumps(config));dest=root/name
 result=subprocess.run([str(exe),'scene',str(source),'--out',str(dest)],capture_output=True)
 assert (result.returncode==0)==ok,result.stderr.decode()
 if not ok:assert not (dest/'scene.json').exists()
 return dest
out=run_scene('actual',scene);manifest=json.loads((out/'scene.json').read_text())
assert [r['object_id'] for r in manifest['results']]==['left','right']
assert manifest['results'][1]['translation_mm']==[10.25,-3.5,2.125]
bounds=dict(lo=[-1,-1,0],hi=[5,5,5]);stock=dict(primitives=[dict(box=dict(lo=[0,0,0],hi=[4,4,4]))])
fixture=dict(primitives=[dict(box=dict(lo=[-.75,1,0],hi=[-.25,3,3])),dict(box=dict(lo=[4.25,1,0],hi=[4.75,3,3]))])
for index,name in enumerate(['left','right']):
 operations=[dict(id=name+'-groove',tool=0,line=dict(a=dict(position=[.5,2,2]),b=dict(position=[3.5,2,2])))]
 if name=='left':operations.append(dict(id='left-hole',subtract=dict(sphere=dict(center=[1,1,3.5],radius=.5))))
 job=dict(version=1,units='mm',voxel_mm=.25,motion_tolerance_mm=.01,bounds=bounds,stock=stock,target=dict(primitives=[dict(box=dict(lo=[0,0,0],hi=[4,4,2.5]))]),fixtures=fixture,tools=[dict(cutter=dict(kind='ball',radius=.5,length=3))],operations=operations,export_mesh=False)
 if name=='right':job['target']['primitives'][0]['box']=dict(lo=[.125,0,0],hi=[4.125,4,2.5])
 source=root/(name+'.json');source.write_text(json.dumps(job));reference=root/(name+'-reference')
 result=subprocess.run([str(exe),'job',str(source),'--out',str(reference)],capture_output=True);assert result.returncode==0,result.stderr.decode()
 actual=out/f'workpiece-{index:04}'
 for file in ['final.menkh','target.blocks','target.pool','fixture.blocks','fixture.pool','surface-provenance.bin']:
  assert (actual/file).read_bytes()==(reference/file).read_bytes(),(name,file)
 report=json.loads((actual/'report.json').read_text());expected=json.loads((reference/'report.json').read_text())
 assert report['remaining_occupied']==expected['remaining_occupied']
 assert report['target_comparison']==expected['target_comparison']
 for x,y in zip(report['operations'],expected['operations']):
  for key in ['id','removed_voxels','shank_stock','holder_stock','shank_fixture','holder_fixture','cutter_fixture']:assert x[key]==y[key],(name,key)
 if a.reader:
  command=[str(a.reader.resolve()),str(out/'scene.json'),'--workpiece',name,'--verify-history','--warp','--color-operation','--snapshot',str(root/(name+'.ppm'))] if a.viewer else [str(a.reader.resolve()),'--scene',str(out/'scene.json'),name]
  subprocess.run(command,check=True)
assert (out/'workpiece-0000/final.menkh').read_bytes()!=(out/'workpiece-0001/final.menkh').read_bytes()
# Reordering objects changes output slot names but not stable IDs or owned state.
reordered=copy.deepcopy(scene);reordered['objects'].reverse();other=run_scene('reordered',reordered)
lookup={r['object_id']:other/r['state'] for r in json.loads((other/'scene.json').read_text())['results']}
for r in manifest['results']:assert (out/r['state']).read_bytes()==lookup[r['object_id']].read_bytes()
# Named STL geometry resolves relative to the original scene, not output jobs.
def write_box(path,hi):
 vertices=[(x,y,z) for z in [0,hi[2]] for y in [0,hi[1]] for x in [0,hi[0]]]
 faces=[(0,2,3,1),(4,5,7,6),(0,1,5,4),(2,6,7,3),(0,4,6,2),(1,3,7,5)]
 data=bytearray(80)+struct.pack('<I',12)
 for a,b,c,d in faces:
  for triangle in [(a,b,c),(a,c,d)]:data+=struct.pack('<12fH',0,0,0,*sum((vertices[i] for i in triangle),()),0)
 path.write_bytes(data)
write_box(root/'blank.stl',[4,4,4]);write_box(root/'target.stl',[4,4,2.5])
mesh=copy.deepcopy(scene)
mesh['geometries'][0]['source']=dict(stl=dict(path='blank.stl',unit_scale_mm=1))
mesh['geometries'][1]['source']=dict(stl=dict(path='target.stl',unit_scale_mm=1))
meshed=run_scene('mesh',mesh)
for r in manifest['results']:
 assert (out/r['state']).read_bytes()==(meshed/r['state']).read_bytes()
# Saved material remains workpiece-local; mutations of one instance do not affect another.
resume=copy.deepcopy(scene);resume['geometries'][0]['source']=dict(state_file=str(out/'workpiece-0001/final.menkh'))
resume['operations']=[resume['operations'][-1]]
resumed=run_scene('resumed',resume)
for r in manifest['results']:assert (out/r['state']).read_bytes()==(resumed/r['state']).read_bytes()
# A later input failure leaves earlier part results but no completed scene catalog.
partial=copy.deepcopy(scene);partial['geometries'].append(dict(id='bad-mesh',source=dict(stl=dict(path='missing.stl',unit_scale_mm=1))))
next(o for o in partial['objects'] if o['id']=='right')['geometry']='bad-mesh'
failed=run_scene('partial-failure',partial,False);assert (failed/'workpiece-0000/final.menkh').exists()
invalid=[]
def case(change):
 config=copy.deepcopy(scene);change(config);invalid.append(config)
case(lambda s:s['objects'].append(copy.deepcopy(s['objects'][0])))
case(lambda s:s['geometries'].append(copy.deepcopy(s['geometries'][0])))
case(lambda s:s['objects'][0].update(geometry='missing'))
case(lambda s:s['objects'][0].update(rotation=[0,0,0,1]))
case(lambda s:s['objects'][0].update(target='right'))
case(lambda s:s['objects'][0].update(fixtures=['left-clamp-a','left-clamp-a']))
case(lambda s:s['objects'][2].update(translation_mm=[-100,0,0]))
case(lambda s:s['operations'][0].update(workpiece='left-target'))
case(lambda s:s['operations'][0].update(tool='missing'))
case(lambda s:s['operations'][0].update(arc={}))
case(lambda s:s['operations'][0]['line']['b'].update(axis=[0,1,0]))
for i,config in enumerate(invalid):
 dest=run_scene('invalid-'+str(i),config,False);assert not dest.exists(),'Preflight must reject before output creation'
result=subprocess.run([str(exe),'scene',str(root/'actual.json'),'--out',str(out)],capture_output=True);assert result.returncode!=0
assert json.loads((out/'scene.json').read_text())==manifest
if a.reader:
 for i,history in enumerate(['../actual/workpiece-0000/voxel-animation.json','/tmp/absolute.json']):
  bad=copy.deepcopy(manifest);bad['results'][0]['history']=history;path=out/f'bad-{i}.json';path.write_text(json.dumps(bad))
  command=[str(a.reader.resolve()),str(path),'--workpiece','left','--verify-history','--warp'] if a.viewer else [str(a.reader.resolve()),'--scene',str(path),'left']
  result=subprocess.run(command,capture_output=True);assert result.returncode!=0
print('Scene: independent jobs match byte-exactly, ownership and stable IDs survive reordering, invalid inputs rejected')
