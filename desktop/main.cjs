const {app,BrowserWindow,Menu,session}=require('electron');
const path=require('node:path');
app.setPath('userData',path.join(app.getPath('appData'),'KoalaSandPaper'));
function openStudio(){
 const win=new BrowserWindow({width:1440,height:980,minWidth:430,minHeight:620,backgroundColor:'#f4f2ed',title:'KoalaSandPaper',webPreferences:{nodeIntegration:false,contextIsolation:true,sandbox:true,webSecurity:true}});
 win.webContents.setWindowOpenHandler(()=>({action:'deny'}));
 win.webContents.on('will-navigate',e=>e.preventDefault());
 win.loadFile(path.join(__dirname,'../dist/index.html'));
}
app.whenReady().then(()=>{session.defaultSession.setPermissionRequestHandler((_w,_p,callback)=>callback(false));Menu.setApplicationMenu(Menu.buildFromTemplate([{role:'appMenu'},{role:'editMenu'},{role:'viewMenu'},{role:'windowMenu'}]));openStudio();app.on('activate',()=>{if(!BrowserWindow.getAllWindows().length)openStudio();});});
app.on('window-all-closed',()=>{if(process.platform!=='darwin')app.quit();});
