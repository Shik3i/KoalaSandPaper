import workerSource from './worker.js';
import { Renderer } from './render.js';

const $=id=>document.getElementById(id), canvas=$('scene'), renderer=new Renderer(canvas);
const query=new URLSearchParams(location.search), wallpaper=query.get('wallpaper')==='1'||location.pathname.endsWith('/wallpaper.html');
const workerUrl=URL.createObjectURL(new Blob([workerSource],{type:'text/javascript'}));
const worker=new Worker(workerUrl); URL.revokeObjectURL(workerUrl);
let paused=false, busy=false, elapsed=0, last=performance.now(), speed=1, seed=2718, resetPending=false;
let frames=0, fpsStart=last, fps=0, lastStats=null, recorder=null, recordingTimer=null, recordingStart=0;
let mixer=true,cutter=true,feed=true, frameBuffer=null, toastTimer, latestMs=0;
function toast(text){$('toast').textContent=text;$('toast').classList.add('visible');clearTimeout(toastTimer);toastTimer=setTimeout(()=>$('toast').classList.remove('visible'),5000);}
function settings(){worker.postMessage({type:'settings',mixer,cutter,feed});renderer.mixer=mixer;renderer.cutter=cutter;}
function setPaused(value){paused=Boolean(value);$('pause').textContent=paused?'▶':'Ⅱ';$('pause').setAttribute('aria-label',paused?'Simulation fortsetzen':'Simulation pausieren');$('live-label').textContent=paused?'PAUSIERT':'LIVE SIMULATION';elapsed=0;}
function setSpeed(value){const n=Number(value);speed=Number.isFinite(n)?Math.min(2,Math.max(.25,n)):1;$('speed').value=speed;$('speed-value').value=speed+'×';}
function setPalette(value){renderer.setPalette(value);document.querySelectorAll('[data-palette]').forEach(b=>b.setAttribute('aria-pressed',String(b.dataset.palette===renderer.palette)));$('palette-name').textContent={sorbet:'Sorbet',aurora:'Aurora',ember:'Abendglut'}[renderer.palette];renderer.draw();}
function reset(){
  if(recorder?.state==='recording'){toast('Bitte die Aufnahme vor dem Neustart beenden.');return;}
  const n=Number($('seed').value);if(!Number.isInteger(n)||n<0||n>2147483647){toast('Seed: eine ganze Zahl von 0 bis 2147483647.');return;}
  seed=n;renderer.seed=seed;resetPending=true;elapsed=0;
}
function resetWorker(){busy=true;resetPending=false;worker.postMessage({type:'reset',seed,steps:0,buffer:frameBuffer},frameBuffer?[frameBuffer]:[]);frameBuffer=null;settings();}
worker.onmessage=({data})=>{
  busy=false;
  if(data.error){setPaused(true);toast('Simulation gestoppt: '+data.error);console.error(data.error);return;}
  frameBuffer=data.buffer;lastStats=data.stats;latestMs=data.steps?data.ms/data.steps:data.ms;
  renderer.rotorAngle=data.stats.rotorAngle;
  if(data.solid) renderer.setSolid(new Uint8Array(data.solid));
  renderer.draw(new Uint8Array(frameBuffer),data.stats.tick);
  const s=Math.floor(Math.max(0,data.stats.tick-2400)/60);$('time').textContent=String(Math.floor(s/60)).padStart(2,'0')+':'+String(s%60).padStart(2,'0');
  $('stats').textContent=data.stats.grains.toLocaleString('de-DE')+' Körner · '+data.stats.solidContacts.toLocaleString('de-DE')+' Kontakte · '+data.stats.bladePushes.toLocaleString('de-DE')+' Rotorstöße · '+latestMs.toFixed(1)+' ms/Tick';
  if(data.stats.massError!==0){setPaused(true);toast('Materialbilanz verletzt. Bitte neu starten.');}
};
worker.onerror=event=>{busy=false;setPaused(true);toast('Der Simulations-Worker konnte nicht geladen werden. Bitte neu laden.');console.error(event.message);};
function animate(now){
  const delta=Math.min(.1,(now-last)/1000);last=now;
  if(!document.hidden && !paused) elapsed=Math.min(.133,elapsed+delta*speed);
  if(!busy && resetPending) resetWorker();
  else if(!busy && !document.hidden && !paused){const steps=Math.min(8,Math.floor(elapsed*60));if(steps){elapsed-=steps/60;busy=true;renderer.grains=null;worker.postMessage({type:'step',steps,buffer:frameBuffer},frameBuffer?[frameBuffer]:[]);frameBuffer=null;}}
  frames++;if(now-fpsStart>=1000){fps=Math.round(frames*1000/(now-fpsStart));frames=0;fpsStart=now;$('fps').textContent=(paused?'PAUSE':fps+' FPS')+' / 60 HZ';}
  if(recorder?.state==='recording') $('capture-note').textContent=Math.floor((now-recordingStart)/1000)+' / 30 Sekunden · Aufnahme läuft';
  requestAnimationFrame(animate);
}
$('pause').onclick=()=>setPaused(!paused);$('reset').onclick=reset;$('reseed').onclick=reset;
$('speed').oninput=e=>setSpeed(e.target.value);
document.querySelectorAll('[data-palette]').forEach(b=>b.onclick=()=>setPalette(b.dataset.palette));
document.querySelectorAll('[data-preset]').forEach(b=>b.onclick=()=>{
  document.querySelectorAll('[data-preset]').forEach(p=>p.setAttribute('aria-pressed',String(p===b)));
  const preset={ritual:[1,'sorbet'],flow:[.5,'aurora'],energy:[2,'ember']}[b.dataset.preset];setSpeed(preset[0]);setPalette(preset[1]);
});
for(const id of ['mixer','cutter','feed']) $(id).onchange=()=>{mixer=$('mixer').checked;cutter=$('cutter').checked;feed=$('feed').checked;settings();};
function zen(){document.body.classList.toggle('zen');}
$('zen').onclick=zen;$('exit-zen').onclick=zen;
$('fullscreen').onclick=async()=>{try{if(document.fullscreenElement) await document.exitFullscreen();else await $('scene').requestFullscreen();}catch{toast('Vollbild ist in diesem Fenster nicht verfügbar. Nutze den Zen-Modus.');}};
document.addEventListener('keydown',e=>{
  if(['INPUT','SELECT','TEXTAREA','BUTTON'].includes(e.target.tagName)||$('wallpaper-dialog').open) return;
  if(e.code==='Space'){e.preventDefault();setPaused(!paused);}
  if(e.key.toLowerCase()==='z') zen();
  if(e.key==='Escape'&&!wallpaper) document.body.classList.remove('zen');
});
$('wallpaper').onclick=()=>$('wallpaper-dialog').showModal();$('close-dialog').onclick=()=>$('wallpaper-dialog').close();
$('preview-wallpaper').onclick=()=>{$('wallpaper-dialog').close();document.body.classList.add('zen');};
function download(blob,name){const url=URL.createObjectURL(blob),a=document.createElement('a');a.href=url;a.download=name;a.click();setTimeout(()=>URL.revokeObjectURL(url),60000);}
function stopRecording(){if(recorder?.state==='recording')recorder.stop();}
$('record').onclick=()=>{
  if(recorder?.state==='recording'){stopRecording();return;}
  if(!canvas.captureStream||!window.MediaRecorder){toast('Dieser Browser unterstützt keine Canvas-Videoaufnahme. Nutze die Desktop-App oder Chromium.');return;}
  const mime=['video/webm;codecs=vp9','video/webm;codecs=vp8','video/webm','video/mp4'].find(t=>MediaRecorder.isTypeSupported(t));
  if(!mime){toast('Kein unterstützter Video-Encoder gefunden.');return;}
  let stream;
  try{
    stream=canvas.captureStream(30);recorder=new MediaRecorder(stream,{mimeType:mime,videoBitsPerSecond:10000000});const chunks=[];let size=0;
    recorder.ondataavailable=e=>{if(e.data.size){chunks.push(e.data);size+=e.data.size;if(size>128*1024*1024)stopRecording();}};
    recorder.onstop=()=>{clearTimeout(recordingTimer);stream.getTracks().forEach(t=>t.stop());$('record').dataset.recording='false';$('record').innerHTML='<span>◉</span> Video aufnehmen <span>↗</span>';$('capture-note').textContent='30 Sekunden · 1536 × 864 · ohne Ton';if(chunks.length){download(new Blob(chunks,{type:mime}),'KoalaSandPaper-'+seed+'-'+Date.now()+'.'+(mime.includes('mp4')?'mp4':'webm'));toast('Video gespeichert.');}recorder=null;};
    recorder.onerror=()=>{toast('Die Videoaufnahme ist fehlgeschlagen.');stopRecording();};
    setPaused(false);recorder.start(1000);recordingStart=performance.now();$('record').dataset.recording='true';$('record').textContent='■ Aufnahme beenden';recordingTimer=setTimeout(stopRecording,30000);
  }catch(error){stream?.getTracks().forEach(t=>t.stop());recorder=null;toast('Aufnahme nicht verfügbar: '+error.message);}
};
document.addEventListener('visibilitychange',()=>{last=performance.now();elapsed=0;if(document.hidden)stopRecording();});
window.addEventListener('pagehide',()=>{stopRecording();worker.terminate();});
window.livelyPropertyListener=(name,value)=>{if(name==='speed')setSpeed(value);if(name==='palette')setPalette(['sorbet','aurora','ember'][Number(value)]);if(name==='paused')setPaused(value);};
if(wallpaper)document.body.classList.add('zen','wallpaper');
renderer.draw();settings();requestAnimationFrame(animate);
// Read-only diagnostics for reproducible acceptance, no command bridge.
Object.defineProperty(window,'sandpaperDiagnostics',{get:()=>({stats:lastStats,fps,msPerTick:latestMs,paused,seed,palette:renderer.palette,recording:recorder?.state==='recording',worker:true})});
