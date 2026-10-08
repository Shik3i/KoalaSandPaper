import { SandWorld, hash2d } from './physics.js';

export const WIDTH = 768, HEIGHT = 432;
export const SHAPES = [ [[0,0],[1,0],[2,0],[1,1]], [[0,0],[0,1],[1,1],[2,1]], [[0,0],[1,0],[0,1],[1,1]], [[0,0],[1,0],[2,0],[3,0]], [[1,0],[2,0],[0,1],[1,1]] ];
export const PALETTES = {
  sorbet: ['#f6b17a','#ed7e9a','#bea5ee','#8dccbc','#f0d487','#8cbbe2'],
  aurora: ['#7ae4c4','#62b7cd','#8997ee','#ba8ae0','#ee91bf','#a9deb0'],
  ember: ['#ef8468','#f4ad69','#e6cd88','#d78297','#ae96c5','#c5b397']
};
export const SHREDDER_TEETH = Array.from({length: 2}, (_, row) =>
  Array.from({length: 5}, (_, column) => ({x: 551 + column * 20, y: 117 + row * 20, radius: 8}))
).flat();

export class Factory {
  constructor(seed = 2718, preset = 'ritual') {
    this.world = new SandWorld(WIDTH, HEIGHT, seed);
    this.seed = seed; this.preset = preset; this.bodies = []; this.serial = 0;
    this.injected = 0; this.collected = 0; this.cut = 0; this.shredded = 0;
    this.feed = true; this.mixer = true; this.cutter = true; this.bladePushes = 0;
    this.rotorAngle = 0; this.bladeCells = [];
    this.geometry();
    this.staticSolid = this.world.solid.slice();
    this.updateRotor(0);
    // A running composition on opening, still obtained through real ticks.
    for (let i = 0; i < 5; i++) this.spawn(65 + i * 100);
  }
  line(x1,y1,x2,y2, thickness = 2) {
    const n = Math.max(Math.abs(x2-x1), Math.abs(y2-y1));
    for (let s=0;s<=n;s++) for(let k=0;k<thickness;k++) this.world.wall(Math.round(x1+(x2-x1)*s/Math.max(1,n)), Math.round(y1+(y2-y1)*s/Math.max(1,n))+k);
  }
  disk(cx, cy, radius) {
    for (let y = cy - radius; y <= cy + radius; y++) for (let x = cx - radius; x <= cx + radius; x++) {
      const dx = x - cx, dy = y - cy;
      if (dx * dx + dy * dy <= radius * radius) this.world.wall(x, y);
    }
  }
  geometry() {
    // The collision mesh is deliberately defined in the same 768×432 space as the renderer.
    // The belt ends before the shredder throat: grains must fall into it, never teleport across it.
    this.line(48,108,537,108,5);
    this.line(537,108,537,144,3); this.line(646,108,646,144,3);
    // Stationary collision teeth leave deterministic gaps. They are the physical obstacle layer
    // behind the visibly rotating wheels, so each released grain hits, piles, and finds a gap.
    for (const tooth of SHREDDER_TEETH) this.disk(tooth.x, tooth.y, tooth.radius);
    // Hopper, neck, open-top mixer bowl, outlet and cascading collection tray.
    this.line(537,143,565,190,3); this.line(646,143,592,190,3);
    this.line(565,190,565,207,2); this.line(592,190,592,207,2);
    for(let y=213;y<=355;y++) for(let x=460;x<=640;x++) {
      const r=(x-550)**2+(y-274)**2;
      if(r>=78**2 && r<=81**2 && y>226 && !(x<489 && y>310 && y<335)) this.world.wall(x,y);
    }
    this.disk(550,274,22);
    this.line(478,334,338,374,3); this.line(476,350,338,390,3);
    this.line(76,404,650,404,4); this.line(76,375,76,404,3); this.line(650,375,650,404,3);
    // The lower tray's wide slot is an explicit drain, enabling an endless scene without overflow.
    for(let x=88;x<638;x++) this.world.solid[this.world.index(x,404)]=0;
  }
  spawn(x=50) {
    if(this.bodies.length>=12) return false;
    const id=this.serial++, shape=SHAPES[hash2d(this.seed,id,0)%SHAPES.length], pixels=[];
    for(const [bx,by] of shape) for(let y=0;y<13;y++) for(let xx=0;xx<13;xx++) pixels.push([bx*13+xx,by*13+y]);
    const height=Math.max(...shape.map(p=>p[1]))*13+13;
    this.bodies.push({x,y:108-height,id,color:id%6,pixels,offset:0});
    this.injected+=pixels.length; return true;
  }
  transport() {
    const w=this.world, t=w.tick;
    for(const body of this.bodies) {
      const bodyRight = body.x + Math.max(...body.pixels.map(([x]) => x));
      // A form is rigid only while it is on the belt. On reaching the actual throat it breaks
      // at its visible cell positions; every resulting grain then follows normal collision rules.
      if (bodyRight >= 537) {
        const remaining=[];
        for (const p of body.pixels) {
          const x=body.x+p[0], y=body.y+p[1];
          if (w.add(x,y,body.color*4+1+(hash2d(this.seed,x,y)&3),true)) this.shredded++;
          else remaining.push(p);
        }
        body.pixels=remaining;
        continue;
      }
      // Bound grains move as a slab on the belt, one cell every other tick.
      if(t%2===0) body.x++;
      const keep=[];
      for(const p of body.pixels) {
        const x=body.x+p[0], y=body.y+p[1];
        const laser=this.cutter && x===362 && p[1]%13===6;
        if(laser) { // Cut kerf is released as real grains; the rest proceeds to the rollers.
          if(w.add(x,y,body.color*4+1+(hash2d(this.seed,x,y)&3),true)) {this.cut++; continue;}
        }
        keep.push(p);
      }
      body.pixels=keep;
    }
    this.bodies=this.bodies.filter(b=>b.pixels.length);
    // Free grains from the laser move on the same physical belt and then fall into the throat.
    if(t%2===0) for(let x=537;x>=48;x--) {
      w.move(x,107,x+1,107);
    }
    if(this.feed && t%200===0 && !this.bodies.some(b=>b.x<115)) this.spawn();
  }
  stir() {
    if (this.mixer && this.world.tick % 2 === 0) this.updateRotor(Math.PI / 140);
  }
  updateRotor(delta) {
    const nextAngle=this.rotorAngle+delta, desired=this.rasterizeRotor(nextAngle);
    const desiredSet=new Set(desired), currentSet=new Set(this.bladeCells);
    // A blade advances only when every entering cell can evacuate its current grain.
    // Keeping the prior cells solid on failure makes a dense jam a real physical stall.
    for (const index of desired) {
      if (currentSet.has(index) || !this.world.cells[index]) continue;
      if (!this.pushFromBlade(index, desiredSet)) return false;
    }
    for (const index of this.bladeCells) if (!this.staticSolid[index]) this.world.solid[index]=0;
    for (const index of desired) this.world.solid[index]=1;
    this.bladeCells=desired; this.rotorAngle=nextAngle;
    return true;
  }
  rasterizeRotor(angle) {
    const cells=[];
    for(let y=204;y<=344;y++) for(let x=475;x<=625;x++) if (this.inBlade(x-550,y-274,angle)) cells.push(this.world.index(x,y));
    return cells;
  }
  pushFromBlade(index, forbidden) {
    const w=this.world,x=index%WIDTH,y=(index/WIDTH)|0,dx=x-550,dy=y-274;
    const tx=dy>0?-1:1,ty=dx>0?1:-1,rx=dx>0?1:-1,ry=dy>0?1:-1;
    for (const [mx,my] of [[tx,ty],[tx+rx,ty],[tx,ty+ry],[rx,ry],[-tx,-ty]]) {
      const nx=x+mx,ny=y+my,ni=w.inside(nx,ny)?w.index(nx,ny):-1;
      if (ni>=0 && !forbidden.has(ni) && w.empty(nx,ny) && w.move(x,y,nx,ny)) { this.bladePushes++; return true; }
    }
    return false;
  }
  inBlade(dx, dy, angle) {
    for (let blade = 0; blade < 3; blade++) {
      const a = angle + (blade + 1) * Math.PI * 2 / 3;
      const c=Math.cos(a), s=Math.sin(a), x=dx*c+dy*s, y=-dx*s+dy*c;
      // Exact local triangle winding for the blade polygon rendered in Renderer.draw().
      const points=[[8,-7],[58,-19],[69,-10],[22,5]];
      let sign=0, inside=true;
      for(let i=0;i<points.length;i++) {
        const p=points[i],q=points[(i+1)%points.length],cross=(q[0]-p[0])*(y-p[1])-(q[1]-p[1])*(x-p[0]);
        if(cross!==0){const next=Math.sign(cross);if(sign&&next!==sign){inside=false;break;}sign=next;}
      }
      if(inside) return true;
    }
    return false;
  }
  step() {
    const w=this.world;
    // Machinery before gravity ensures lifted grains cannot fall again this tick.
    this.stir(); this.transport(); w.gravity();
    for(let x=0;x<WIDTH;x++) {
      // Lower collection lane: slow drain after a visible pile has formed.
      if(w.tick%7===0) this.collected+=Number(Boolean(w.remove(x,403)));
      this.collected+=Number(Boolean(w.remove(x,HEIGHT-1)));
    }
    w.finishTick();
  }
  stats() {
    const bound=this.bodies.reduce((n,b)=>n+b.pixels.length,0);
    return {tick:this.world.tick,grains:this.world.count,bound,injected:this.injected,collected:this.collected,cut:this.cut,shredded:this.shredded,bladePushes:this.bladePushes,rotorAngle:this.rotorAngle,solidContacts:this.world.solidContacts,massError:this.injected-this.collected-bound-this.world.count,visited:this.world.visited};
  }
  frame(buffer) {
    const pixels=buffer?.byteLength===WIDTH*HEIGHT ? new Uint8Array(buffer) : new Uint8Array(WIDTH*HEIGHT);
    pixels.set(this.world.cells);
    for(const b of this.bodies) for(const [dx,dy] of b.pixels) {
      const x=b.x+dx,y=b.y+dy;
      if(this.world.inside(x,y)) pixels[y*WIDTH+x]=b.color*4+1+(hash2d(this.seed,dx,dy)&3);
    }
    return pixels.buffer;
  }
}
