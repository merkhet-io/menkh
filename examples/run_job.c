#include "menkh.h"
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <string.h>
#ifdef _WIN32
#include <windows.h>
#include <direct.h>
#define getcwd _getcwd
#else
#include <unistd.h>
#endif
typedef struct { uint64_t stop_after, previous, calls; } Progress;
static uint32_t progress(void *context,uint32_t phase,uint64_t completed,uint64_t total) {
    Progress *p=(Progress*)context;
    if(completed<p->previous || completed>total){fputs("Invalid progress contract\n",stderr);exit(1);}
    p->previous=completed;++p->calls;
    return phase!=5 && completed>=p->stop_after;
}
static int run(int argc,char **argv) {
    if(argc<4 || argc>5){fputs("run-job JOB_ABSOLUTE OUTPUT_ABSOLUTE WORKDIR_ABSOLUTE [CANCEL_AFTER_OPERATIONS]\n",stderr);return 1;}
    Progress p={UINT64_MAX,0,0};
    if(argc==5)p.stop_after=strtoull(argv[4],NULL,10);
    char before[32768],after[32768];
    if(!getcwd(before,sizeof(before)))return 1;
    menkh_status status=menkh_run_job_v1(argv[1],argv[2],argv[3],progress,&p);
    if(!getcwd(after,sizeof(after)) || strcmp(before,after)){fputs("Process working directory changed\n",stderr);return 1;}
    printf("status=%d completed=%llu callbacks=%llu\n",status,(unsigned long long)p.previous,(unsigned long long)p.calls);
    if(status==MENKH_CANCELLED)return 2;
    if(status!=MENKH_OK){fprintf(stderr,"%s\n",menkh_status_message(status));return 1;}
    return 0;
}

#ifdef _WIN32
int wmain(int argc,wchar_t **wide) {
    char **argv=calloc((size_t)argc,sizeof(*argv));
    if(!argv)return 1;
    int result=1;
    for(int i=0;i<argc;++i){
        int n=WideCharToMultiByte(CP_UTF8,WC_ERR_INVALID_CHARS,wide[i],-1,NULL,0,NULL,NULL);
        if(!n || !(argv[i]=malloc((size_t)n)))goto cleanup;
        if(!WideCharToMultiByte(CP_UTF8,WC_ERR_INVALID_CHARS,wide[i],-1,argv[i],n,NULL,NULL))goto cleanup;
    }
    result=run(argc,argv);
cleanup:
    for(int i=0;i<argc;++i)free(argv[i]);
    free(argv);return result;
}
#else
int main(int argc,char **argv){return run(argc,argv);}
#endif
