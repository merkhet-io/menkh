#!/usr/bin/env python3
"""Independent sampled height errors and exact represented-state comparison."""
import importlib.util, pathlib, json, math, hashlib, struct, argparse
ROOT=pathlib.Path(__file__).resolve().parents[1]
def module(name):
    spec=importlib.util.spec_from_file_location(name,ROOT/'scripts'/f'{name}.py');m=importlib.util.module_from_spec(spec);spec.loader.exec_module(m);return m
accuracy=module('finishing-accuracy');fixture=module('finishing-fixture')
def digest(path):
    s=accuracy.State(path);h=hashlib.sha256()
    for i in range(s.blocks):
        d=struct.unpack_from('<I',s.data,96+4*i)[0]
        if d==0xffffffff:bits=bytes(64)
        elif d==0xfffffffe:
            bx=i%s.nb[0];by=(i//s.nb[0])%s.nb[1];bz=i//(s.nb[0]*s.nb[1]);ex=[min(8,n-b*8) for n,b in zip(s.n,(bx,by,bz))]
            word=sum(((1<<ex[0])-1)<<(8*y) for y in range(ex[1]));bits=struct.pack('<8Q',*([word]*ex[2]+[0]*(8-ex[2])))
        else:bits=s.data[s.pool+d*64:s.pool+(d+1)*64]
        h.update(bits)
    return h.hexdigest()
def summary(values):return dict(samples=len(values),min_mm=min(values),max_mm=max(values),max_abs_mm=max(map(abs,values)),mean_mm=sum(values)/len(values))
def inspect(jobfile,statefile,out):
    j=json.loads(jobfile.read_text());s=accuracy.State(statefile);ops=[(x['line']['a']['position'],x['line']['b']['position']) for x in j['operations']]
    buckets={}
    for a,b in ops:
        for x in range(math.floor(min(a[0],b[0])-1),math.floor(max(a[0],b[0])+1)+1):
            for y in range(math.floor(min(a[1],b[1])-1),math.floor(max(a[1],b[1])+1)+1):buckets.setdefault((x,y),[]).append((a,b))
    input_error=[];path_error=[];simulation_error=[];thin=[]
    # Offset sampling avoids evaluating only input mesh vertices or voxel centers.
    for iy in range(64):
        for ix in range(96):
            x=.073+ix*.25;y=.087+iy*.25;wx=x+fixture.OFFSET[0];wy=y+fixture.OFFSET[1]
            target=fixture.height(x,y)+fixture.OFFSET[2]
            i=int(x/.125);k=int(y/.125);u=x/.125-i;v=y/.125-k
            z00=fixture.height(i*.125,k*.125);z11=fixture.height((i+1)*.125,(k+1)*.125)
            interp=((1-u)*z00+(u-v)*fixture.height((i+1)*.125,k*.125)+v*z11 if u>=v else (1-v)*z00+(v-u)*fixture.height(i*.125,(k+1)*.125)+u*z11)+fixture.OFFSET[2]
            input_error.append(interp-target)
            ideal=min(accuracy.lower(wx,wy,a,b) for a,b in buckets[(math.floor(wx),math.floor(wy))])
            actual=s.top(int((wx-s.origin[0])/s.h),int((wy-s.origin[1])/s.h))
            path_error.append(ideal-target);simulation_error.append(actual-ideal)
    for x in (4,8,12,16,20):
        y=8;wx=x+fixture.OFFSET[0];wy=y+fixture.OFFSET[1]
        actual=s.top(int((wx-s.origin[0])/s.h),int((wy-s.origin[1])/s.h));expected=fixture.height(x,y)+fixture.OFFSET[2]
        thin.append(dict(x_mm=wx,y_mm=wy,remaining_height_mm=actual,analytic_target_height_mm=expected,vertical_excess_mm=actual-expected))
    missing=[];missing_indices={}
    target_blocks=(statefile.parent/'target.blocks').read_bytes();target_pool=(statefile.parent/'target.pool').read_bytes()
    for index in range(s.blocks):
        sd=struct.unpack_from('<I',s.data,96+index*4)[0];td=struct.unpack_from('<I',target_blocks,index*4)[0]
        if sd==0xfffffffe or td==0xffffffff:continue
        sw=(0,)*8 if sd==0xffffffff else struct.unpack_from('<8Q',s.data,s.pool+sd*64)
        tw=(2**64-1,)*8 if td==0xfffffffe else struct.unpack_from('<8Q',target_pool,td*64)
        for z,(a,b) in enumerate(zip(sw,tw)):
            bits=b & ~a
            while bits:
                bit=(bits & -bits).bit_length()-1;bits &= bits-1
                ix=(index%s.nb[0])*8+bit%8;iy=((index//s.nb[0])%s.nb[1])*8+bit//8;iz=(index//(s.nb[0]*s.nb[1]))*8+z
                if ix>=s.n[0] or iy>=s.n[1] or iz>=s.n[2]:continue
                pos=[o+(i+.5)*s.h for o,i in zip(s.origin,(ix,iy,iz))]
                if len(missing)<100:
                    missing.append(dict(position_mm=pos,removed_by_operation=None));missing_indices.setdefault(index,[]).append((z,bit,missing[-1]))
    # Attribute missing samples to the first recorded operation that clears them.
    history=json.loads((statefile.parent/'voxel-animation.json').read_text())
    if missing_indices:
        for frame in history['frames']:
            data=(statefile.parent/frame['file']).read_bytes();at=0
            while at<len(data):
                index,before,after=struct.unpack_from('<III',data,at);at+=12
                bo=at
                if before<0xfffffffe:at+=64
                ao=at
                if after<0xfffffffe:at+=64
                if index not in missing_indices:continue
                for z,bit,record in missing_indices[index]:
                    bw=(2**64-1 if before==0xfffffffe else 0 if before==0xffffffff else struct.unpack_from('<Q',data,bo+z*8)[0])
                    aw=(2**64-1 if after==0xfffffffe else 0 if after==0xffffffff else struct.unpack_from('<Q',data,ao+z*8)[0])
                    if bw&(1<<bit) and not aw&(1<<bit):record['removed_by_operation']=frame['stage']
    result=dict(first_100_missing_target_centers_mm=missing,tessellation_vertical_samples=summary(input_error),designed_path_minus_analytic_target=summary(path_error),raster_height_minus_continuous_path=summary(simulation_error),thin_rib_samples=thin,occupancy_sha256=digest(statefile),note='6144 offset XY samples, vertical height differences, not shortest surface distances or Hausdorff bounds. Input error samples use exact procedural triangle interpolation; binary STL f32 quantization is additional. Thin rib sampled explicitly at five x positions; no global feature guarantee.')
    out.write_text(json.dumps(result,indent=2));return result
if __name__=='__main__':
    p=argparse.ArgumentParser();p.add_argument('job',type=pathlib.Path);p.add_argument('state',type=pathlib.Path);p.add_argument('out',type=pathlib.Path);a=p.parse_args();inspect(a.job,a.state,a.out)
