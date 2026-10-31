/* Independent C host; no Zig headers or renderer. Build/run: scripts/test-sdk.py. */
#include "menkh.h"
#include <math.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#define CHECK(x) do { if (!(x)) {fprintf(stderr,"check failed at line %d: %s\n",__LINE__,#x);exit(1);} } while(0)
#define OK(x) do {menkh_status s=(x);if(s!=MENKH_OK){fprintf(stderr,"line %d: %s\n",__LINE__,menkh_status_message(s));exit(1);}} while(0)
static unsigned char *snapshot(menkh_handle *h,size_t *size) {
    CHECK(menkh_state_write_v1(h,NULL,0,size)==MENKH_BUFFER_TOO_SMALL);
    unsigned char *bytes=(unsigned char*)malloc(*size);CHECK(bytes);
    OK(menkh_state_write_v1(h,bytes,*size,size));return bytes;
}
int main(int argc,char **argv) {
    CHECK(menkh_abi_version()==1);
    menkh_box box={{0,0,0},{4,3,1},.1};menkh_handle *h=NULL,*resumed=NULL;
    OK(menkh_create_box_v1(&box,&h));CHECK(h);
    uint64_t count=0;OK(menkh_count_v1(h,&count));CHECK(count==12000);
    menkh_tool tool={0,.3,1};menkh_pose from={{1,1.5,.6},{0,0,1}},to={{3,1.5,.6},{0,0,1}};
    menkh_cut_report report={0};OK(menkh_cut_line_v1(h,&tool,&from,&to,.01,&report));
    CHECK(report.removed_voxels>0 && report.remaining_voxels+report.removed_voxels==12000);
    CHECK(report.motion_over_removal_bound_mm==0 && report.sweep_pieces==1);
    uint64_t oracle_count=0;
    for(int z=0;z<10;++z)for(int y=0;y<30;++y)for(int x=0;x<40;++x) {
        double p[3]={(x+.5)*.1,(y+.5)*.1,(z+.5)*.1};uint32_t occupied;
        double dx=p[0]<1 ? p[0]-1 : (p[0]>3 ? p[0]-3 : 0),dy=p[1]-1.5;
        int cut=dx*dx+dy*dy<=.3*.3 && p[2]>=.6 && p[2]<=1.6;
        OK(menkh_query_v1(h,p,&occupied));CHECK(occupied==(uint32_t)!cut);oracle_count+=occupied;
    }
    CHECK(oracle_count==report.remaining_voxels);
    size_t delta_size=0;
    CHECK(menkh_history_write_v1(h,NULL,0,&delta_size)==MENKH_BUFFER_TOO_SMALL);
    unsigned char *delta=(unsigned char*)malloc(delta_size);CHECK(delta);
    OK(menkh_history_write_v1(h,delta,delta_size,&delta_size));
    OK(menkh_history_apply_v1(h,delta,delta_size,0));OK(menkh_count_v1(h,&count));CHECK(count==12000);
    OK(menkh_history_apply_v1(h,delta,delta_size,1));OK(menkh_count_v1(h,&count));CHECK(count==oracle_count);
    delta[0]=255;delta[1]=255;delta[2]=255;delta[3]=255;
    CHECK(menkh_history_apply_v1(h,delta,delta_size,0)==MENKH_INVALID_STATE);
    OK(menkh_count_v1(h,&count));CHECK(count==oracle_count);free(delta);
    OK(menkh_cut_line_v1(h,&tool,&from,&to,.01,&report));CHECK(report.removed_voxels==0);
    to.axis[0]=1;to.axis[2]=0;CHECK(menkh_cut_line_v1(h,&tool,&from,&to,.01,&report)==MENKH_UNSUPPORTED);
    OK(menkh_count_v1(h,&count));CHECK(count==oracle_count);
    double invalid[3]={NAN,0,0};uint32_t occupied=42;
    CHECK(menkh_query_v1(h,invalid,&occupied)==MENKH_INVALID_ARGUMENT && occupied==42);
    size_t size;unsigned char *bytes=snapshot(h,&size);
    unsigned char guard=123;size_t required=0;
    CHECK(menkh_state_write_v1(h,&guard,1,&required)==MENKH_BUFFER_TOO_SMALL && guard==123 && required==size);
    OK(menkh_state_read_v1(bytes,size,&resumed));CHECK(resumed);
    menkh_handle *bad=NULL;bytes[size-1]^=1;
    CHECK(menkh_state_read_v1(bytes,size,&bad)==MENKH_INVALID_STATE && bad==NULL);bytes[size-1]^=1;
    menkh_xyzac a={{2,1.5,.5},20,-10},b={{2.1,1.6,.55},40,30};
    tool.radius_mm=.5;tool.length_mm=.3;
    OK(menkh_cut_xyzac_v1(h,&tool,&a,&b,.02,&report));CHECK(report.motion_over_removal_bound_mm<=.02);
    OK(menkh_cut_xyzac_v1(resumed,&tool,&a,&b,.02,&report));
    size_t n1,n2;unsigned char *one=snapshot(h,&n1),*two=snapshot(resumed,&n2);
    CHECK(n1==n2 && memcmp(one,two,n1)==0);
    if(argc==2){FILE *f=fopen(argv[1],"wb");CHECK(f);CHECK(fwrite(one,1,n1,f)==n1);CHECK(fclose(f)==0);}
    free(one);free(two);free(bytes);menkh_destroy_v1(resumed);menkh_destroy_v1(h);menkh_destroy_v1(NULL);
    CHECK(menkh_create_box_v1(NULL,&bad)==MENKH_INVALID_ARGUMENT && bad==NULL);
    menkh_box oversized={{0,0,0},{655.36,655.36,655.36},.01};
    CHECK(menkh_create_box_v1(&oversized,&bad)==MENKH_RESOURCE_LIMIT && bad==NULL);
    puts("C ABI: 12000 independent occupancy queries, idempotence, invalid inputs, buffer bounds, checkpoint integrity and resumed rotary equality passed");
    return 0;
}
