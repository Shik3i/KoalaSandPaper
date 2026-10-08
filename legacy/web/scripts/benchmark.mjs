import {Factory} from '../src/factory.js';
import {SandWorld,hash2d} from '../src/physics.js';
import os from 'node:os';
const report={date:new Date().toISOString(),host:os.type()+' '+os.arch(),cpu:os.cpus()[0]?.model,node:process.version,scenarios:[]};
function measure(name,step,stats,n=1200){const times=[];for(let i=0;i<120;i++)step();for(let i=0;i<n;i++){const start=performance.now();step();times.push(performance.now()-start);}times.sort((a,b)=>a-b);return {name,ticks:n,meanMs:times.reduce((a,b)=>a+b,0)/n,p95Ms:times[Math.floor(n*.95)],maxMs:times.at(-1),...stats()};}
const f=new Factory();report.scenarios.push(measure('factory / 768x432',()=>f.step(),()=>f.stats()));
const dense=new SandWorld();for(let y=0;y<180;y++)for(let x=1;x<767;x++)if(hash2d(1,x,y)%3)dense.add(x,y,1);
report.scenarios.push(measure('dense falling pile / 768x432',()=>dense.step(),()=>({grains:dense.count,hash:dense.stateHash()}),300));
for(let i=0;i<900;i++)dense.step();report.scenarios.push(measure('settled pile / sleeping chunks',()=>dense.step(),()=>({grains:dense.count,visited:dense.visited}),300));
console.log(JSON.stringify(report,null,2));
