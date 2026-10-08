import { Factory } from './factory.js';
function createFactory(seed=2718) {
  const f=new Factory(seed);
  // Deterministic pre-roll: start with sand already flowing through every stage.
  for(let i=0;i<2400;i++) f.step();
  return f;
}
let factory = createFactory();
self.onmessage = ({data}) => {
  try {
    if(data.type==='reset') factory=createFactory(data.seed);
    if(data.type==='settings') {
      for(const name of ['feed','mixer','cutter']) if(typeof data[name]==='boolean') factory[name]=data[name];
      return;
    }
    const start=performance.now();
    const steps=Math.max(0,Math.min(8,Number(data.steps)||0));
    for(let i=0;i<steps;i++) factory.step();
    const buffer=factory.frame(data.buffer);
    const solid = factory.world.solid.slice().buffer;
    self.postMessage({buffer,solid,stats:factory.stats(),ms:performance.now()-start,steps},[buffer,solid]);
  } catch(error) { self.postMessage({error:String(error.stack||error)}); }
};
