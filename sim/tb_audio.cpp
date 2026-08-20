// Sound-board liveness and level check: boot the whole machine, run to a frame
// window, and record what comes out at the SN76489As' own rate.
//
//   tb_audio <tp84.rom> <first_frame> <last_frame> <out.wav>
#include "Vtp84_core.h"
#include "verilated.h"
#include <cstdio>
#include <cstdlib>
#include <cmath>
#include <vector>
static Vtp84_core *dut; static vluint64_t t=0; double sc_time_stamp(){return t;}
static inline void tick(){ dut->clk=0; dut->eval(); dut->clk=1; dut->eval(); t++; }
static const int FRAME_SKEW = 2;
static void set_inputs(int f){
    unsigned sys=0xff, p1=0xff;
    if(f>=600 && f<604) sys &= ~0x01u;
    if(f>=660 && f<664) sys &= ~0x08u;
    if(f>700){ p1 &= ~0x10u; if((f/30)%4==0) p1 &= ~0x20u;
               if((f/60)%2==0) p1 &= ~0x02u; else p1 &= ~0x01u; }
    dut->in_system=sys; dut->in_p1=p1;
}
static void put32(FILE*f,unsigned v){for(int i=0;i<4;i++)fputc((v>>(8*i))&255,f);} 
static void put16(FILE*f,unsigned v){for(int i=0;i<2;i++)fputc((v>>(8*i))&255,f);} 
int main(int argc,char**argv){
    Verilated::commandArgs(argc,argv);
    if(argc<5){fprintf(stderr,"usage: tb_audio <rom> <f0> <f1> <out.wav>\n");return 2;}
    int f0=atoi(argv[2]), f1=atoi(argv[3]);
    FILE*rf=fopen(argv[1],"rb"); fseek(rf,0,SEEK_END); long n=ftell(rf); fseek(rf,0,SEEK_SET);
    std::vector<unsigned char> rom(n); if(fread(rom.data(),1,n,rf)!=(size_t)n) return 1; fclose(rf);
    dut=new Vtp84_core; dut->reset=1; dut->pause=0;
    dut->in_system=dut->in_p1=dut->in_p2=0xff; dut->dsw1=0xff; dut->dsw2=0x32; dut->dl_we=0;
    for(int i=0;i<64;i++) tick();
    for(size_t a=0;a<rom.size();a++){dut->dl_addr=a;dut->dl_data=rom[a];dut->dl_we=1;tick();}
    dut->dl_we=0; for(int i=0;i<64*32;i++) tick();
    dut->reset=0;
    std::vector<short> pcm; int vbl=0, peak=0; long clipped=0;
    set_inputs(-FRAME_SKEW);
    while(vbl-FRAME_SKEW < f1){
        tick();
        if(dut->vblank_rise){ vbl++; set_inputs(vbl-FRAME_SKEW); }
        if(dut->audio_ce && (vbl-FRAME_SKEW)>=f0){
            short v=(short)dut->audio; pcm.push_back(v);
            int a=v<0?-v:v; if(a>peak) peak=a;
            if(v==32767 || v==-32768) clipped++;
        }
    }
    int rate=(int)(1789773.0/2.0+0.5);
    FILE*o=fopen(argv[4],"wb"); unsigned bytes=(unsigned)pcm.size()*2;
    fwrite("RIFF",1,4,o); put32(o,36+bytes); fwrite("WAVE",1,4,o);
    fwrite("fmt ",1,4,o); put32(o,16); put16(o,1); put16(o,1);
    put32(o,rate); put32(o,rate*2); put16(o,2); put16(o,16);
    fwrite("data",1,4,o); put32(o,bytes);
    for(short v:pcm) put16(o,(unsigned short)v);
    fclose(o);
    double sum=0,sq=0; for(short v:pcm){sum+=v;sq+=(double)v*v;}
    double dc=pcm.empty()?0:sum/pcm.size(); double ac=0;
    for(short v:pcm) ac+=(v-dc)*(v-dc);
    ac=pcm.empty()?0:sqrt(ac/pcm.size());
    printf("%s: %zu samples @ %d Hz  peak=%d dc=%.1f ac_rms=%.1f\n",
           argv[4], pcm.size(), rate, peak, dc, ac);
    printf("  clipped samples: %ld (%.4f%%)\n", clipped,
           pcm.empty()?0.0:100.0*clipped/pcm.size());
    printf("  sound board: sn_writes=%u irqs=%u timer=%x filter=%04x\n",
           dut->dbg_sn_writes, dut->dbg_snd_irqs, dut->dbg_snd_timer, dut->dbg_snd_filter);
    return 0;
}
