import fs from 'node:fs';
import path from 'node:path';
import {fileURLToPath} from 'node:url';
const root=path.resolve(path.dirname(fileURLToPath(import.meta.url)),'..');
const small=process.argv.includes('--small');
const capture=process.argv.includes('--capture');
const W=small?32:1920,H=small?24:1080;
const out=path.join(root,small?(capture?'sim/vectors_capture':'sim/vectors_small'):'rom');fs.mkdirSync(out,{recursive:true});
const source=fs.readFileSync(path.join(root,'../rec_picture.m'),'utf8');
const param=n=>Number(source.match(new RegExp(`^${n}\\s*=\\s*([-\\d.]+)`,'m'))[1]);
const fx=param('fx')*W/1920,fy=param('fy')*H/1080;
const cx=(param('cx')-1)*W/1920+1,cy=(param('cy')-1)*H/1080+1;
const d0=param('d0'),d1=param('d1');
const gx=[],gy=[];
for(let x=0;x<W;x+=16)gx.push(x);if(gx.at(-1)!==W-1)gx.push(W-1);
for(let y=0;y<H;y+=16)gy.push(y);if(gy.at(-1)!==H-1)gy.push(H-1);
const grid=[];
for(const y of gy)for(const x of gx){
  const xn=(x+1-cx)/fx,yn=(y+1-cy)/fy,r=xn*xn+yn*yn,k=1+d0*r+d1*r*r;
  grid.push([Math.round(Math.max(0,Math.min(W-2,fx*xn*k+cx-1))*4096),
             Math.round(Math.max(0,Math.min(H-2,fy*yn*k+cy-1))*4096)]);
}
fs.writeFileSync(path.join(out,'map.hex'),grid.map(([u,v])=>v.toString(16).padStart(6,'0')+u.toString(16).padStart(6,'0')).join('\n')+'\n');
if(!small){
  const hardwareRom=path.join(root,'source/undistort/rom');fs.mkdirSync(hardwareRom,{recursive:true});
  fs.copyFileSync(path.join(out,'map.hex'),path.join(hardwareRom,'map.hex'));
}
const src=Buffer.alloc(W*H),dst=Buffer.alloc(W*H);
for(let y=0;y<H;y++)for(let x=0;x<W;x++){
  const raw=((x*3+y*5)^((x>>4)&1?127:0)^((y>>4)&1?63:0))&255;
  const rb=((raw>>3)<<3)|(raw>>5),g=((raw>>2)<<2)|(raw>>6);
  src[y*W+x]=capture?(106*rb+150*g)>>8:raw;
}
const bigGrid=grid.map(p=>p.map(BigInt));
let maxWidth=0,maxHeight=0,traffic=0,maxError=0,sumError=0;
for(let by=0;by<H;by+=16)for(let bx=0;bx<W;bx+=16){
  const ix=bx>>4,iy=by>>4,ids=[iy*gx.length+ix,iy*gx.length+ix+1,(iy+1)*gx.length+ix,(iy+1)*gx.length+ix+1];
  const us=ids.map(i=>grid[i][0]/4096),vs=ids.map(i=>grid[i][1]/4096);
  const left=Math.floor(Math.min(...us)),right=Math.floor(Math.max(...us))+1;
  const top=Math.floor(Math.min(...vs)),bottom=Math.floor(Math.max(...vs))+1;
  maxWidth=Math.max(maxWidth,right-left+1);maxHeight=Math.max(maxHeight,bottom-top+1);
  const span=(Math.floor(right/32)-Math.floor(left/32)+1)*32;
  if(span>64 || bottom-top+1>32)throw Error('Source tile exceeds 64x32 cache');
  traffic+=span*(bottom-top+1);
  for(let y=by;y<Math.min(by+16,H);y++)for(let x=bx;x<bx+16;x++){
    const tx=Math.round((x-bx)*65536/(gx[ix+1]-gx[ix])),ty=Math.round((y-by)*65536/(gy[iy+1]-gy[iy]));
    const w=[BigInt(65536-tx)*BigInt(65536-ty),BigInt(tx)*BigInt(65536-ty),BigInt(65536-tx)*BigInt(ty),BigInt(tx)*BigInt(ty)];
    const c=[0,1].map(axis=>Number((ids.reduce((s,id,k)=>s+bigGrid[id][axis]*w[k],0n)+2147483648n)>>32n));
    const x0=c[0]>>12,y0=c[1]>>12,du=c[0]&4095,dv=c[1]&4095;
    const p=[src[y0*W+x0],src[y0*W+x0+1],src[(y0+1)*W+x0],src[(y0+1)*W+x0+1]];
    const value=Math.floor((p[0]*(4096-du)*(4096-dv)+p[1]*du*(4096-dv)+p[2]*(4096-du)*dv+p[3]*du*dv+8388608)/16777216);
    dst[y*W+x]=value;
    const floatValue=p[0]*(1-du/4096)*(1-dv/4096)+p[1]*(du/4096)*(1-dv/4096)+p[2]*(1-du/4096)*(dv/4096)+p[3]*(du/4096)*(dv/4096);
    const e=Math.abs(value-floatValue);maxError=Math.max(maxError,e);sumError+=e;
  }
}
for(const [name,data] of [['source',src],['expected',dst]]){
  fs.writeFileSync(path.join(out,name+'.hex'),Array.from(data,v=>v.toString(16).padStart(2,'0')).join('\n')+'\n');
  fs.writeFileSync(path.join(out,name+'.pgm'),Buffer.concat([Buffer.from(`P5\n${W} ${H}\n255\n`),data]));
}
const report={width:W,height:H,grid:[gx.length,gy.length],maxWidth,maxHeight,prefetchBytes:traffic,
  estimatedMBps:(traffic+3*W*H)*60/1e6,roundingMax:maxError,roundingMean:sumError/(W*H)};
fs.writeFileSync(path.join(out,'report.json'),JSON.stringify(report,null,2)+'\n');console.log(report);
