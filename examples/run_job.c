#include "menkh.h"
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
typedef struct { uint64_t stop_after, previous, calls; } Progress;
static uint32_t progress(void *context,uint32_t phase,uint64_t completed,uint64_t total) {
    Progress *p=(Progress*)context;
    if(completed<p->previous || completed>total){fputs("Invalid progress contract\n",stderr);exit(1);}
    p->previous=completed;++p->calls;
    return phase!=5 && completed>=p->stop_after;
}
int main(int argc,char **argv) {
    if(argc<4 || argc>5){fputs("run-job JOB_ABSOLUTE OUTPUT_ABSOLUTE WORKDIR_ABSOLUTE [CANCEL_AFTER_OPERATIONS]\n",stderr);return 1;}
    Progress p={UINT64_MAX,0,0};
    if(argc==5)p.stop_after=strtoull(argv[4],NULL,10);
    menkh_status status=menkh_run_job_v1(argv[1],argv[2],argv[3],progress,&p);
    printf("status=%d completed=%llu callbacks=%llu\n",status,(unsigned long long)p.previous,(unsigned long long)p.calls);
    if(status==MENKH_CANCELLED)return 2;
    if(status!=MENKH_OK){fprintf(stderr,"%s\n",menkh_status_message(status));return 1;}
    return 0;
}
