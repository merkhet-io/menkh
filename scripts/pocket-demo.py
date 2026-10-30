#!/usr/bin/env python3
"""Build a presentation job from exact flat-cylinder line segments, not interpolated meshes."""
import json, math, pathlib
root=pathlib.Path(__file__).resolve().parents[1]
out=root/'out/pocket-demo';out.mkdir(parents=True,exist_ok=True)
job=dict(version=1,units='mm',bounds=dict(lo=[-15,-12,0],hi=[15,12,16]),voxel_mm=.1,
 stock=dict(primitives=[{'box':dict(lo=[-12,-9,0],hi=[12,9,8])}]),
 tools=[dict(cutter=dict(kind='flat',radius=2,length=5),shank=dict(radius=1.8,length=3,offset=5),holder=dict(radius=3,length=3,offset=8))],
 operations=[],export_mesh=True)
position=[-10,-3,10]
for layer,z in enumerate([6,4,3],1):
    points=[[-6,-3,z],[6,-3,z],[6,-1,z],[-6,-1,z],[-6,1,z],[6,1,z],[6,3,z],[-6,3,z],[-6,-3,z]]
    for destination in points:
        n=max(1,math.ceil(math.dist(position,destination)/.65))
        start=position.copy()
        for i in range(n):
            end=[start[k]+(destination[k]-start[k])*(i+1)/n for k in range(3)]
            job['operations'].append(dict(id=f'Layer {layer} / {len(job["operations"])+1:03}',tool=0,line=dict(a=dict(position=position),b=dict(position=end))))
            position=end
# Retract through the already cleared pocket, maintaining a visible tool and honest state.
start=position.copy()
for i in range(16):
    end=[start[0],start[1],start[2]+(9-start[2])*(i+1)/16]
    job['operations'].append(dict(id=f'Retract / {i+1:02}',tool=0,line=dict(a=dict(position=position),b=dict(position=end))))
    position=end
(out/'job.json').write_text(json.dumps(job,indent=2)+'\n')
print(f'Pocket demo: {len(job["operations"])} actual cutting states at 0.1 mm spacing')
