#include "CSafeArchive.h"
#include <stdio.h>
#include <stdlib.h>
#include <string.h>

static unsigned rng=7189;
static unsigned next_random(void) { rng^=rng<<13; rng^=rng>>17; rng^=rng<<5; return rng; }
static void exercise(const uint8_t *data,size_t size) {
    ms_zip zip; ms_zip_entry entry; uint8_t output[65536];
    ms_zip_limits limits={128,65536,262144,500};
    if(ms_zip_open(data,size,limits,&zip)==MS_OK) {
        for(unsigned i=0;i<128 && ms_zip_next(&zip,&entry)==MS_OK;i++)
            (void)ms_zip_extract(&zip,&entry,output,sizeof(output));
    }
    size_t offset=0; ms_pb_field field;
    for(unsigned i=0;i<256 && ms_pb_next(data,size,&offset,&field)==MS_OK;i++) {}
    size_t written=0;
    (void)ms_gzip_decode(data,size,output,sizeof(output),&written);
}
int main(int argc,char **argv) {
    uint8_t bytes[4096],seed[4096]; size_t seed_size=0;
    if(argc==2) {
        FILE *file=fopen(argv[1],"rb"); if(!file) return 2;
        seed_size=fread(seed,1,sizeof(seed),file); fclose(file); exercise(seed,seed_size);
    }
    for(unsigned i=0;i<30000;i++) {
        size_t size=next_random()%sizeof(bytes);
        for(size_t j=0;j<size;j++) bytes[j]=(uint8_t)next_random();
        exercise(bytes,size);
        if(seed_size) {
            memcpy(bytes,seed,seed_size);
            for(unsigned j=0;j<4;j++) bytes[next_random()%seed_size]=(uint8_t)next_random();
            exercise(bytes,seed_size);
        }
    }
    puts("ASan/UBSan: 30000 random inputs and 30000 seeded mutations completed.");
    return 0;
}
