import test from 'node:test';
import assert from 'node:assert/strict';
import {SandWorld,hash2d} from '../src/physics.js';
import {Factory} from '../src/factory.js';

// Independent BigInt oracle of the original GDScript integer arithmetic.
function oracleHash(seed,x,y,t=0){const mask=0x7fffffffn;let v=(BigInt(seed)^BigInt(t)^0x45d9f3bn)&mask;v=((v^BigInt(x))*0x119de1f3n)&mask;v=((v^BigInt(y))*0x1b873593n)&mask;v=(v^(v>>16n))&mask;v=(v*0x45d9f3bn)&mask;return Number((v^(v>>16n))&mask);}
test('hash is bit-identical to upstream arithmetic including negative coordinates',()=>{for(const seed of [0,2718,2147483647,-1])for(let n=-100;n<100;n++)assert.equal(hash2d(seed,n,n*17,n+100),oracleHash(seed,n,n*17,n+100));});
test('optimized chunk traversal matches independent full-grid reference for every tick',()=>{
 const w=new SandWorld(70,75,42);for(let x=0;x<70;x++)w.wall(x,74);
 for(let y=3;y<26;y++)for(let x=12;x<57;x++)if(hash2d(3,x,y)%3)w.add(x,y,1+hash2d(8,x,y)%24);
 for(let x=9;x<62;x++)if(x!==35)w.wall(x,45);
 const cells=w.cells.slice(),solid=w.solid;
 for(let t=0;t<150;t++){
   const empty=(x,y)=>x>=0&&x<70&&y>=0&&y<75&&!cells[y*70+x]&&!solid[y*70+x];
   for(let y=73;y>=0;y--)for(let k=0;k<70;k++){const x=(t&1)?69-k:k,i=y*70+x;if(!cells[i])continue;const d=(oracleHash(42,x,y,t)&1)?1:-1;for(const xx of [x,x+d,x-d])if(empty(xx,y+1)){cells[(y+1)*70+xx]=cells[i];cells[i]=0;break;}}
   w.step();assert.deepEqual(w.cells,cells,'tick '+t);
 }
});
test('a grain crosses chunk boundaries only once per tick',()=>{const w=new SandWorld(66,66);w.add(32,31,7);w.step();assert.equal(w.cells[32*66+32],7);assert.equal(w.count,1);});
test('settled chunks sleep and erased support wakes dependent grains',()=>{
 const w=new SandWorld(64,64);for(let x=0;x<64;x++)w.wall(x,32);w.add(31,31,1);
 for(let i=0;i<30;i++)w.step();assert.equal(w.active.reduce((a,b)=>a+b,0),0);
 w.wall(31,32,0);w.step();assert.equal(w.cells[32*64+31],1);
});
test('grid rejects invalid input, blocked placement and solid overwrite',()=>{assert.throws(()=>new SandWorld(100000,100000),RangeError);const w=new SandWorld(10,10);assert.equal(w.add(-1,0,1),false);assert.equal(w.add(1.5,1,2),false);assert.equal(w.add(1,1,99),false);w.add(1,1,1);assert.equal(w.wall(1,1),false);assert.equal(w.add(1,1,2),false);assert.equal(w.count,1);});
test('machinery shares moved flags with gravity',()=>{const w=new SandWorld(12,12);w.add(5,5,3);assert.equal(w.move(5,5,6,5),true);w.gravity();assert.equal(w.cells[5*12+6],3);w.finishTick();w.step();assert.equal(w.cells[6*12+6],3);});
test('factory conserves every grain and collides with the physical shredder and drain',()=>{
 const f=new Factory(2718);let maxGrains=0;
 for(let i=0;i<2400;i++){f.step();const s=f.stats();maxGrains=Math.max(maxGrains,s.grains);assert.equal(s.massError,0,'tick '+i);if(i%100===0)assert.equal(f.world.cells.reduce((n,v)=>n+Number(v>0),0),s.grains);}
 const s=f.stats();assert.ok(s.cut>0);assert.ok(s.shredded>1000);assert.ok(s.solidContacts>1000);assert.ok(s.bladePushes>100);assert.ok(s.collected>0);assert.ok(maxGrains>1000);for(const index of f.bladeCells){assert.equal(f.world.solid[index],1);assert.equal(f.world.cells[index],0);}console.log('FACTORY_FLOW',JSON.stringify(s));
});
test('seed replay and controls remain deterministic and conserved',()=>{
 const a=new Factory(92),b=new Factory(92);
 for(let i=0;i<450;i++){if(i===50){a.feed=b.feed=false;a.cutter=b.cutter=false;}if(i===200)a.mixer=b.mixer=false;a.step();b.step();}
 assert.deepEqual(a.stats(),b.stats());assert.equal(a.world.stateHash(),b.world.stateHash());assert.deepEqual(a.bodies,b.bodies);assert.equal(a.stats().massError,0);
});
