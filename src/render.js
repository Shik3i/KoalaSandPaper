import { WIDTH, HEIGHT, PALETTES, SHREDDER_TEETH } from './factory.js';

export class Renderer {
  constructor(canvas) {
    this.canvas=canvas; this.ctx=canvas.getContext('2d',{alpha:false});
    this.layer=document.createElement('canvas'); this.layer.width=WIDTH; this.layer.height=HEIGHT;
    this.lc=this.layer.getContext('2d'); this.image=this.lc.createImageData(WIDTH,HEIGHT);
    this.wallLayer=document.createElement('canvas'); this.wallLayer.width=WIDTH; this.wallLayer.height=HEIGHT;
    this.wc=this.wallLayer.getContext('2d'); this.wallImage=this.wc.createImageData(WIDTH,HEIGHT);
    this.palette='sorbet'; this.setPalette(this.palette);
    this.grains=null; this.tick=0; this.rotorAngle=0; this.mixer=true; this.cutter=true;
  }
  setSolid(solid) {
    if (!solid || solid.length !== WIDTH * HEIGHT) return;
    const data=this.wallImage.data;
    for(let i=0;i<solid.length;i++) {
      const j=i*4;
      if(solid[i]) { data[j]=111;data[j+1]=137;data[j+2]=137;data[j+3]=255; }
      else data[j+3]=0;
    }
    this.wc.putImageData(this.wallImage,0,0);
  }
  setPalette(name) {
    this.palette=PALETTES[name]?name:'sorbet'; this.colors=new Uint8Array(25*3);
    PALETTES[this.palette].forEach((hex,c)=>{
      const n=parseInt(hex.slice(1),16), rgb=[n>>16,(n>>8)&255,n&255];
      for(let v=0;v<4;v++) for(let k=0;k<3;k++) this.colors[(c*4+v+1)*3+k]=Math.min(255,Math.round(rgb[k]*(.79+v*.09)));
    });
  }
  line(points,color='#526269',width=3) {
    const c=this.ctx; c.beginPath(); points.forEach(([x,y],i)=>i?c.lineTo(x,y):c.moveTo(x,y)); c.strokeStyle=color;c.lineWidth=width;c.stroke();
  }
  circle(x,y,r,fill,stroke) {
    const c=this.ctx;c.beginPath();c.arc(x,y,r,0,Math.PI*2);c.fillStyle=fill;c.fill();if(stroke){c.strokeStyle=stroke;c.lineWidth=1;c.stroke();}
  }
  label(text,x,y) {const c=this.ctx;c.font='7px ui-monospace, monospace';c.fillStyle='#7c9195';c.fillText(text,x,y);}
  gear(x,y,r,angle) {
    const c=this.ctx;c.save();c.translate(x,y);c.rotate(angle);c.beginPath();
    for(let i=0;i<64;i++){const a=i*Math.PI/32,rr=(i%4<2?r:r-4); i?c.lineTo(Math.cos(a)*rr,Math.sin(a)*rr):c.moveTo(Math.cos(a)*rr,Math.sin(a)*rr);}
    c.closePath();c.fillStyle='#55676d';c.fill();c.strokeStyle='#94a3a5';c.lineWidth=.7;c.stroke();
    this.circle(0,0,r-7,'#29363d','#66777b');this.circle(0,0,3,'#a5b3b2');
    for(let i=0;i<3;i++){const a=i*Math.PI*2/3;this.circle(Math.cos(a)*(r-11),Math.sin(a)*(r-11),2,'#101c25');}c.restore();
  }
  draw(grains=this.grains,tick=this.tick) {
    this.grains=grains;this.tick=tick; const c=this.ctx;
    c.setTransform(this.canvas.width/WIDTH,0,0,this.canvas.height/HEIGHT,0,0);
    c.fillStyle='#111e28';c.fillRect(0,0,WIDTH,HEIGHT);
    const glow=c.createRadialGradient(540,245,10,470,235,380);glow.addColorStop(0,'#1c3038');glow.addColorStop(1,'#111e28');c.fillStyle=glow;c.fillRect(0,0,WIDTH,HEIGHT);
    // Quiet drafting marks, structural rails and machine housings.
    c.fillStyle='#34444b'; for(let y=22;y<HEIGHT;y+=24) for(let x=24;x<WIDTH;x+=24) c.fillRect(x,y,.65,.65);
    this.label('01 / FORMEN',48,38);this.label('02 / SCHNITT',323,38);this.label('03 / MAHLWERK',546,38);
    this.label('04 / MISCHEN',652,251);this.label('05 / SAMMELN',80,362);
    c.fillStyle='#0b141c';c.beginPath();c.roundRect(38,108,515,28,14);c.fill();c.strokeStyle='#4d6167';c.lineWidth=1;c.stroke();
    for(let x=52;x<542;x+=16) {const xx=x+(tick/2%16); this.line([[xx,110],[xx-8,132]],'#354750',1);}
    for(const x of [52,537]) this.gear(x,122,10,tick/32);
    this.line([[49,107],[541,107]],'#a2b7b6',2);
    this.line([[85,137],[85,150],[496,150],[496,137]],'#354952',3);
    // Laser gantry, narrow beam, pulsing contact glow.
    this.line([[335,108],[335,51],[390,51],[390,108]],'#485d65',3);
    c.fillStyle='#677a7d';c.fillRect(353,51,18,10);c.fillStyle='#182c35';c.fillRect(357,61,10,7);
    if(this.cutter){c.shadowColor='#ef9989';c.shadowBlur=12;this.line([[362,68],[362,107]],'#ffb7a2',.8);this.circle(362,107,1.5,'#ffe6cb');c.shadowBlur=0;}
    this.line([[541,142],[565,190],[565,207]],'#65777a',3);
    this.line([[646,142],[592,190],[592,207]],'#65777a',3);
    // Mixer shell: the open outlet is also open in the collision geometry.
    c.beginPath();c.arc(550,274,81,-.63,2.29);c.strokeStyle='#839693';c.lineWidth=4;c.stroke();
    c.beginPath();c.arc(550,274,81,2.69,3.77);c.stroke();
    this.line([[478,334],[338,374]],'#718781',3);
    this.line([[76,375],[76,404],[650,404],[650,375]],'#597170',3);
    // Every visible grain comes from the simulation or a bound form.
    if(grains){const data=this.image.data;for(let i=0;i<grains.length;i++){const v=grains[i],j=i*4;data[j]=this.colors[v*3];data[j+1]=this.colors[v*3+1];data[j+2]=this.colors[v*3+2];data[j+3]=v?255:0;}
      this.lc.putImageData(this.image,0,0);c.imageSmoothingEnabled=false;c.drawImage(this.layer,0,0);}
    // Exact collision overlay: a grain never appears in front of a cell that blocks it.
    c.drawImage(this.wallLayer,0,0);
    // Counter-rotating teeth sit over the granular intake.
    for(const tooth of SHREDDER_TEETH) this.gear(tooth.x,tooth.y,12,((tooth.x/20|0)%2?-1:1)*tick/24+tooth.y);
    c.save();c.translate(550,274);c.rotate(this.rotorAngle);
    for(let i=0;i<3;i++) {c.rotate(Math.PI*2/3);c.beginPath();c.moveTo(8,-7);c.lineTo(58,-19);c.lineTo(69,-10);c.lineTo(22,5);c.closePath();c.fillStyle='#a8b8aa';c.fill();c.strokeStyle='#d3d9be';c.lineWidth=.5;c.stroke();}
    c.restore();this.circle(550,274,22,'#20323b','#82978c');this.circle(550,274,15,'#182a34','#4b6466');
    this.label('K / S',540,277);
    c.fillStyle='#50666a';c.fillRect(67,414,594,1);
    this.label('KOALASANDPAPER  /  KINETIC STUDY 001',48,424);
    this.label('SEED '+String(this.seed??2718).padStart(4,'0'),663,424);
  }
}
