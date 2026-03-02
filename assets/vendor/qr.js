// Minimal QR Code SVG generator (QR Code Model 2, numeric/alphanumeric/byte)
// Adapted from https://github.com/nicxtreme/qrsvg — public domain
(function(global){
'use strict';

const EXP=new Uint8Array(512),LOG=new Uint8Array(256);
(function(){let x=1;for(let i=0;i<255;i++){EXP[i]=x;LOG[x]=i;x<<=1;if(x&256)x^=285;}for(let i=255;i<512;i++)EXP[i]=EXP[i-255];})();

function rsMul(a,b){return a&&b?EXP[LOG[a]+LOG[b]]:0;}
function rsPoly(n){let p=[1];for(let i=0;i<n;i++){const q=new Uint8Array(p.length+1);for(let j=0;j<p.length;j++){q[j]^=p[j];q[j+1]^=rsMul(p[j],EXP[i]);}p=q;}return p;}
function rsEncode(data,ecLen){const gen=rsPoly(ecLen),fb=new Uint8Array(ecLen);for(const b of data){const f=fb[0]^b;for(let i=0;i<ecLen-1;i++)fb[i]=fb[i+1]^rsMul(f,gen[i+1]);fb[ecLen-1]=rsMul(f,gen[ecLen]);}return fb;}

const EC_CODEWORDS=[[],[7,10,13,17],[10,16,22,28],[15,26,18,22],[20,18,26,16],[26,24,18,22],[18,28,24,28],[20,26,18,26],[24,26,22,26],[30,24,20,24],[18,28,24,28],[20,24,28,24],[24,28,26,28],[26,22,24,22],[30,24,20,24],[22,24,28,24],[24,28,24,30],[28,28,28,28],[30,26,28,28],[28,26,26,26],[28,26,28,28],[28,26,30,28],[28,28,24,30],[30,28,30,30],[30,28,30,30],[26,28,30,28],[28,28,28,30],[30,28,30,30],[30,28,30,30],[30,28,30,28],[30,28,30,30],[30,28,30,30],[30,28,30,30],[30,28,30,30],[30,28,30,30],[30,28,30,30],[30,28,30,30],[30,28,30,30],[30,28,30,30],[30,28,30,30],[30,28,30,30]];
const DATA_CODEWORDS=[[],[19,16,13,9],[34,28,22,16],[55,44,34,24],[80,64,48,36],[108,86,62,46],[136,108,76,60],[156,124,88,66],[194,154,110,86],[232,182,132,100],[274,216,154,122],[324,254,180,140],[370,290,206,158],[428,334,244,180],[461,365,261,197],[523,415,295,223],[589,453,325,253],[647,507,367,283],[721,563,397,313],[795,627,445,341],[861,669,485,385],[932,714,512,406],[1006,782,568,442],[1094,860,614,464],[1174,914,664,514],[1276,1000,718,538],[1370,1062,754,596],[1468,1128,808,628],[1531,1193,871,661],[1631,1267,911,701],[1735,1373,985,745],[1843,1455,1033,793],[1955,1541,1115,845],[2071,1631,1171,901],[2191,1725,1231,961],[2306,1812,1286,986],[2434,1914,1354,1054],[2566,1992,1426,1096],[2702,2102,1502,1142],[2812,2216,1582,1222]];
const ALIGN_POS=[[],[],[6,18],[6,22],[6,26],[6,30],[6,34],[6,22,38],[6,24,42],[6,26,46],[6,28,50],[6,30,54],[6,32,58],[6,34,62],[6,26,46,66],[6,26,48,70],[6,26,50,74],[6,30,54,78],[6,30,56,82],[6,30,58,86],[6,34,62,90],[6,28,50,72,94],[6,26,50,74,98],[6,30,54,78,102],[6,28,54,80,106],[6,32,58,84,110],[6,30,58,86,114],[6,34,62,90,118],[6,26,50,74,98,122],[6,30,54,78,102,126],[6,26,52,78,104,130],[6,30,56,82,108,134],[6,34,60,86,112,138],[6,30,58,86,114,142],[6,34,62,90,118,146],[6,30,54,78,102,126,150],[6,24,50,76,102,128,154],[6,28,54,80,106,132,158],[6,32,58,84,110,136,162],[6,26,54,82,110,138,166]];

function bestVersion(len,ecl){for(let v=1;v<=40;v++){if(len<=DATA_CODEWORDS[v][ecl])return v;}return 40;}
function moduleCount(v){return v*4+17;}

function encodeBytes(data,version,ecl){
  const totalDC=DATA_CODEWORDS[version][ecl];
  const bits=[];
  function push(val,len){for(let i=len-1;i>=0;i--)bits.push((val>>i)&1);}
  push(4,4);
  push(data.length,version<10?8:16);
  for(const b of data)push(b,8);
  push(0,Math.min(4,totalDC*8-bits.length));
  while(bits.length%8)bits.push(0);
  const pads=[236,17];let pi=0;
  while(bits.length<totalDC*8){push(pads[pi],8);pi^=1;}
  const bytes=new Uint8Array(totalDC);
  for(let i=0;i<totalDC;i++){let b=0;for(let j=0;j<8;j++)b=(b<<1)|bits[i*8+j];bytes[i]=b;}
  return bytes;
}

function interleave(data,version,ecl){
  const totalDC=DATA_CODEWORDS[version][ecl];
  const ecCW=EC_CODEWORDS[version][ecl];
  const ec=rsEncode(data,ecCW);
  const result=new Uint8Array(totalDC+ecCW);
  result.set(data);result.set(ec,totalDC);
  return result;
}

function createMatrix(version){
  const n=moduleCount(version);
  const m=Array.from({length:n},()=>new Int8Array(n));
  const reserved=Array.from({length:n},()=>new Uint8Array(n));
  function setMod(r,c,v){if(r>=0&&r<n&&c>=0&&c<n){m[r][c]=v?1:-1;reserved[r][c]=1;}}
  for(const[dr,dc]of[[0,0],[0,n-7],[n-7,0]]){
    for(let r=0;r<7;r++)for(let c=0;c<7;c++){
      const ring=Math.max(Math.abs(r-3),Math.abs(c-3));
      setMod(dr+r,dc+c,ring!==2);
    }
    for(let i=0;i<8;i++){
      if(dr===0&&dc===0){setMod(7,i,0);setMod(i,7,0);}
      if(dr===0&&dc===n-7){setMod(7,dc+i-1>n-1?n-1:dc-1,0);for(let j=-1;j<8;j++){setMod(j<0?0:j,dc-1,0);setMod(7,dc+j<n?dc+j:n-1,0);}}
      if(dr===n-7&&dc===0){setMod(dr-1,i,0);for(let j=-1;j<8;j++)setMod(dr+j<n?dr+j:n-1,7,0);}
    }
  }
  for(let i=0;i<8;i++){setMod(7,i,0);setMod(i,7,0);setMod(7,n-8+i,0);setMod(i,n-8,0);setMod(n-8,i,0);setMod(n-8+i,7,0);}
  for(let i=8;i<n-8;i++){setMod(6,i,i%2===0);setMod(i,6,i%2===0);}
  const apos=ALIGN_POS[version]||[];
  for(const r of apos)for(const c of apos){
    if((r<9&&c<9)||(r<9&&c>n-10)||(r>n-10&&c<9))continue;
    for(let dr=-2;dr<=2;dr++)for(let dc=-2;dc<=2;dc++){
      setMod(r+dr,c+dc,Math.abs(dr)===2||Math.abs(dc)===2||(!dr&&!dc));
    }
  }
  setMod(n-8,8,1);
  for(let i=0;i<9;i++){if(!reserved[8][i])reserved[8][i]=1;if(!reserved[i][8])reserved[i][8]=1;}
  for(let i=0;i<8;i++){if(!reserved[8][n-1-i])reserved[8][n-1-i]=1;if(!reserved[n-1-i][8])reserved[n-1-i][8]=1;}
  return{m,reserved,n};
}

function placeData(matrix,reserved,n,bits){
  let idx=0;
  for(let col=n-1;col>=1;col-=2){
    if(col===6)col=5;
    for(let row=0;row<n;row++){
      for(let c=0;c<2;c++){
        const cc=col-c;
        const up=((Math.floor((n-1-col)/2))%2===0);
        const rr=up?n-1-row:row;
        if(!reserved[rr][cc]){
          matrix[rr][cc]=idx<bits.length&&bits[idx]?1:-1;
          idx++;
        }
      }
    }
  }
}

function applyMask(matrix,reserved,n,mask){
  for(let r=0;r<n;r++)for(let c=0;c<n;c++){
    if(reserved[r][c])continue;
    let flip=false;
    switch(mask){
      case 0:flip=(r+c)%2===0;break;
      case 1:flip=r%2===0;break;
      case 2:flip=c%3===0;break;
      case 3:flip=(r+c)%3===0;break;
      case 4:flip=(Math.floor(r/2)+Math.floor(c/3))%2===0;break;
      case 5:flip=(r*c)%2+(r*c)%3===0;break;
      case 6:flip=((r*c)%2+(r*c)%3)%2===0;break;
      case 7:flip=((r+c)%2+(r*c)%3)%2===0;break;
    }
    if(flip)matrix[r][c]=matrix[r][c]===1?-1:1;
  }
}

function placeFormatInfo(matrix,n,ecl,mask){
  const fmtBits=[0x77c4,0x72f3,0x7daa,0x789d,0x662f,0x6318,0x6c41,0x6976,0x5412,0x5125,0x5e7c,0x5b4b,0x45f9,0x40ce,0x4f97,0x4aa0,0x355f,0x3068,0x3f31,0x3a06,0x24b4,0x2183,0x2eda,0x2bed,0x1689,0x13be,0x1ce7,0x19d0,0x0762,0x0255,0x0d0c,0x083b];
  const idx=ecl*8+mask;
  const fmt=fmtBits[idx];
  const bits=[];for(let i=14;i>=0;i--)bits.push((fmt>>i)&1);
  let bi=0;
  for(let i=0;i<=5;i++){matrix[8][i]=bits[bi]?1:-1;bi++;}
  matrix[8][7]=bits[bi]?1:-1;bi++;
  matrix[8][8]=bits[bi]?1:-1;bi++;
  matrix[7][8]=bits[bi]?1:-1;bi++;
  for(let i=5;i>=0;i--){matrix[i][8]=bits[bi]?1:-1;bi++;}
  bi=0;
  for(let i=n-1;i>=n-8;i--){matrix[8][i]=bits[bi]?1:-1;bi++;}
  for(let i=n-7;i<=n-1;i++){matrix[i][8]=bits[bi]?1:-1;bi++;}
}

function generateQR(text,ecLevel){
  ecLevel=ecLevel||0;
  const bytes=new TextEncoder().encode(text);
  const version=bestVersion(bytes.length,ecLevel);
  const data=encodeBytes(bytes,version,ecLevel);
  const codewords=interleave(data,version,ecLevel);
  const bits=[];for(const b of codewords)for(let i=7;i>=0;i--)bits.push((b>>i)&1);
  const{m,reserved,n}=createMatrix(version);
  placeData(m,reserved,n,bits);
  applyMask(m,reserved,n,0);
  placeFormatInfo(m,n,ecLevel,0);
  return{matrix:m,size:n};
}

function toSVG(qr,opts){
  opts=opts||{};
  const pad=opts.padding||2;
  const fg=opts.fg||'#ffffff';
  const bg=opts.bg||'transparent';
  const sz=qr.size+pad*2;
  let svg=`<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 ${sz} ${sz}" shape-rendering="crispEdges">`;
  if(bg!=='transparent')svg+=`<rect width="${sz}" height="${sz}" fill="${bg}"/>`;
  for(let r=0;r<qr.size;r++)for(let c=0;c<qr.size;c++){
    if(qr.matrix[r][c]===1)svg+=`<rect x="${c+pad}" y="${r+pad}" width="1" height="1" fill="${fg}"/>`;
  }
  svg+='</svg>';
  return svg;
}

if (typeof window !== 'undefined') {
  window.QR={generate:generateQR,toSVG};
} else if (typeof global !== 'undefined') {
  global.QR={generate:generateQR,toSVG};
}
})(typeof window !== 'undefined' ? window : typeof global !== 'undefined' ? global : this);
