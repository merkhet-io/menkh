#!/usr/bin/env python3
"""Exact optimized/reference mesh comparison plus independent transformed-cell oracle."""
import importlib.util, pathlib, json, math, subprocess
ROOT=pathlib.Path(__file__).resolve().parents[1]
def load(name):
    s=importlib.util.spec_from_file_location(name,ROOT/'scripts'/f'{name}.py');m=importlib.util.module_from_spec(s);s.loader.exec_module(m);return m
suite=load('benchmark-engine');check=load('finishing-inspect');out=ROOT/'out/finishing-import-tests';out.mkdir(parents=True,exist_ok=True)
cases={
 'cavity':{(x,y,z) for x in range(3) for y in range(3) for z in range(3)}-{(1,1,1)},
 'concave':{(x,y,z) for x in range(3) for y in range(3) for z in range(2) if x==0 or y==0},
 'disconnected':{(0,0,0),(3,3,2)},
 'thin':{(x,0,z) for x in range(3) for z in range(2)},
 'boundary':{(0,0,0)}}
results=[]
for name,cells in cases.items():
    for rotated in [False,True]:
        label=name+('-rotated' if rotated else '');path=out/(label+'.stl');suite.stl_fixture(path,cells,rotated)
        j=suite.job();j['export_mesh']=False;j['stock']={'stl':dict(path=str(path),unit_scale_mm=.125 if name=='thin' else 1)};j['voxel_mm']=.05 if name=='thin' else .25
        # Thin slab is 0.125 mm; same topology, physically small feature.
        jobfile=out/(label+'.json');jobfile.write_text(json.dumps(j))
        for ref in [False,True]:
            folder=out/(label+('-reference' if ref else '-fast'))
            with (out/'run.log').open('a') as log:subprocess.run([str(suite.EXE),'job',str(jobfile),'--out',str(folder)]+(['--reference'] if ref else []),check=True,stdout=log,stderr=log)
        fast=out/(label+'-fast/final.menkh');assert check.digest(fast)==check.digest(out/(label+'-reference/final.menkh'))
        s=check.accuracy.State(fast);scale=.125 if name=='thin' else 1;count=0
        # Restrict oracle to the fixture's enclosing region, including outside points.
        for z in range(min(s.n[2],math.ceil(4*scale/s.h)+1)):
            for y in range(min(s.n[1],math.ceil(6*scale/s.h)+1)):
                for x in range(min(s.n[0],math.ceil(6*scale/s.h)+1)):
                    px,py,pz=[(v+.5)*s.h/scale for v in (x,y,z)]
                    if rotated:
                        xx,yy=px-2,py-1;px=xx*math.cos(.37)+yy*math.sin(.37);py=-xx*math.sin(.37)+yy*math.cos(.37)
                    expected=any(cx<=px<=cx+1 and cy<=py<=cy+1 and cz<=pz<=cz+1 for cx,cy,cz in cells)
                    assert s.occupied(x,y,z)==expected,(label,x,y,z)
                    count+=1
        results.append(dict(case=label,voxel_exact=True,independent_center_queries=count))
(out/'results.json').write_text(json.dumps(results,indent=2));print('10 mesh fixtures passed optimized/scalar and independent cell oracle')
