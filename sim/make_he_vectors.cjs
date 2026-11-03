const fs=require('fs');
const W=16,H=16,N=W*H;
const sat=n=>Math.max(0,Math.min(255,n));
function yuv(c){let r=c>>>16,g=(c>>>8)&255,b=c&255;return [sat(Math.floor((77*r+150*g+29*b+128)/256)),sat(Math.floor((-43*r-85*g+128*b+32896)/256)),sat(Math.floor((128*r-107*g-21*b+32896)/256))];}
function back(y,u,v){u-=128;v-=128;return (sat(Math.floor((256*y+359*v+128)/256))*65536+sat(Math.floor((256*y-88*u-183*v+128)/256))*256+sat(Math.floor((256*y+454*u+128)/256)));}
let lines=[],expected=[],map=null,previous=null,mode=false,key=1,reset=0;
const hex=(n,w)=>n.toString(16).padStart(w,'0');
function tick(v,h,e,rgb,shown){lines.push(hex((BigInt(reset)<<28n)|(BigInt(key)<<27n)|(BigInt(v)<<26n)|(BigInt(h)<<25n)|(BigInt(e)<<24n)|BigInt(rgb),8));expected.push(hex((v*4+h*2+e)*16777216+(e?shown:0),7));}
function blank(n,v=0){for(let i=0;i<n;i++)tick(v,0,0,0,0);}
function frame(colors,request=null,holes=false,blankSize=9500,midClick=false){
 if(previous && previous.length===N){
  let histogram=Array(256).fill(0);for(const c of previous)histogram[yuv(c)[0]]++;
  const occupied=histogram.map((n,i)=>n?i:-1).filter(i=>i>=0);
  const limit=Math.ceil(N/128), excess=histogram.reduce((s,n)=>s+Math.max(0,n-limit),0);
  let sum=0;map=histogram.map((n,i)=>{
   sum+=Math.min(n,limit)+Math.floor(excess/256)+(i<excess%256?1:0);
   return occupied.at(-1)-occupied[0]<=8?i:Math.floor((3*i+Math.floor(255*sum/N))/4);
  });
 }
 if(request!==null)mode=request;
 blank(3,1);blank(blankSize);
 for(let i=0;i<colors.length;i++){
  const c=colors[i], [y,u,v]=yuv(c);let shown=mode&&map?back(map[y],u,v):c;
  tick(0,1,1,c,shown);
  if(midClick && i===63)press();
  if(holes&&i%7===0)blank(1);
  if(i%W===W-1)blank(2);
 }
 previous=colors;blank(16);
}
const gray=Array.from({length:N},(_,i)=>i*65793);
let seed=1234567;function rand(){seed=(Math.imul(seed,1664525)+1013904223)>>>0;return seed&0xffffff;}
function press(){key=0;blank(2);key=1;blank(10);key=0;blank(24);key=1;blank(12);}
blank(5);reset=1;blank(300);
frame(gray,false,true);press();frame(gray,true);
frame(Array(N).fill(0),null,true);frame(Array(N).fill(0xffffff));
frame(Array.from({length:N},(_,i)=>i%2?0xff0000:0x0000ff));
frame(Array.from({length:N},()=>rand()),null,true);
// Stable black/gray and narrow dark noise must retain original luma.
for(const colors of [Array(N).fill(0),Array(N).fill(0x808080),Array.from({length:N},(_,i)=>(48+i%5)*65793)]){
 frame(colors);frame(colors);
}
// Incomplete frame must retain the last valid mapping.
frame(gray.slice(0,255));frame(gray);
press();frame(Array.from({length:N},()=>rand()),false,true);
press();frame(Array(N).fill(0x808080),true);
frame(Array.from({length:N},()=>rand()),null,true,9500,true);
frame(gray,false);press();frame(gray,true);
// Reset with nonzero state: both histogram and map-valid must recover.
reset=0;blank(5);reset=1;map=null;previous=null;mode=false;key=1;blank(300);
frame(gray,false);press();frame(gray,true);frame(Array.from({length:N},()=>rand()),null,true);
blank(20);
fs.writeFileSync('sim/he_input.hex',lines.join('\n')+'\n');fs.writeFileSync('sim/he_expected.hex',expected.join('\n')+'\n');
fs.writeFileSync('sim/he_vector_count.vh','localparam integer VECTOR_COUNT='+lines.length+';\n');
console.log('HE independent vectors: '+lines.length+' cycles');
