#!/usr/bin/env python3
"""Independent sampled invariants for protocol v1; not a surface-error certificate."""
import argparse, json, math, struct
from pathlib import Path
p=argparse.ArgumentParser();p.add_argument('state',type=Path);a=p.parse_args()
b=a.state.read_bytes();assert b[:8]==b'MENKHST1'
origin=struct.unpack_from('<3d',b,8);size=struct.unpack_from('<3d',b,32);h,=struct.unpack_from('<d',b,56)
assert h <= .5
n=[round(v/h) for v in size];bn=[(v+7)//8 for v in n]
blocks,slots=struct.unpack_from('<2Q',b,64);assert blocks==math.prod(bn) and len(b)==96+4*blocks+64*slots
pool=96+blocks*4

def cell(p):
    q=[math.floor((v-o)/h) for v,o in zip(p,origin)]
    assert all(0<=v<nn for v,nn in zip(q,n))
    center=[o+(v+.5)*h for v,o in zip(q,origin)]
    block=(q[2]//8*bn[1]+q[1]//8)*bn[0]+q[0]//8
    d,=struct.unpack_from('<I',b,96+block*4)
    if d==0xffffffff: occupied=False
    elif d==0xfffffffe: occupied=True
    else:
        assert d<slots
        word,=struct.unpack_from('<Q',b,pool+d*64+(q[2]%8)*8)
        occupied=bool(word & (1<<((q[1]%8)*8+q[0]%8)))
    return center,occupied

angle=math.atan(8/(10*math.pi));core_bound=12*math.cos(math.pi/16)-8-math.sin(angle)-.08
# Deliberately use the coarsest allowed protocol here: 16 steps/turn and .08 mm
# motion budget. Tighter default settings retain this conservative central core.
counts=dict(core=0,end_caps=0,inside_wheel_at_path_endpoints=0)
for iz in range(81):
    for it in range(32):
        t=it*2*math.pi/32
        center,on=cell([3*math.cos(t),3*math.sin(t),.3+39.4*iz/80])
        if math.hypot(center[0],center[1]) < core_bound:
            assert on, ('lost core',center)
            counts['core']+=1
for z in [.25,39.75]:
    for it in range(128):
        t=it*2*math.pi/128
        center,on=cell([5.5*math.cos(t),5.5*math.sin(t),z])
        # Guaranteed untouched caps even at the smoke tolerance.
        assert on, ('lost cap',center)
        counts['end_caps']+=1
for start in range(2):
    for i in range(65):
        t=i/64;theta=8*math.pi*t+start*math.pi
        center,on=cell([4.5*math.cos(theta),4.5*math.sin(theta),4+32*t])
        # Independent inverse Euler transform from wheel CENTER coordinates.
        x=center[0]-12*math.cos(theta);y=center[1]-12*math.sin(theta);z=center[2]-(4+32*t)
        xx=math.cos(theta)*x+math.sin(theta)*y
        yy=-math.sin(theta)*x+math.cos(theta)*y
        axial=-math.sin(angle)*yy+math.cos(angle)*z+1
        radial=math.hypot(xx, math.cos(angle)*yy+math.sin(angle)*z)
        radius=7+axial/0.8 if axial<.8 else 8 if axial<=1.2 else 8-(axial-1.2)/.8
        if 0<axial<2 and radial<radius-1e-8:
            assert not on, ('missed engagement',center)
            counts['inside_wheel_at_path_endpoints']+=1
assert counts['core']>1000 and counts['inside_wheel_at_path_endpoints']>100
print(json.dumps(dict(state=str(a.state),voxel_mm=h,samples=counts,note='Sampled independent retained-core/cap and cutter-interior invariants. Not a local surface deviation or Hausdorff bound.'),indent=2))
