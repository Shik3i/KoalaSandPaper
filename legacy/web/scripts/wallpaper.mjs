import {mkdir,copyFile} from 'node:fs/promises';
import {execFileSync} from 'node:child_process';
await mkdir('release',{recursive:true});
if(process.platform==='win32')execFileSync('powershell',['-NoProfile','-Command',"Compress-Archive -Path 'dist/*' -DestinationPath 'release/KoalaSandPaper-Lively.zip' -Force"],{stdio:'inherit'});
else execFileSync('zip',['-q','-r','../release/KoalaSandPaper-Lively.zip','.'],{cwd:'dist',stdio:'inherit'});
await copyFile('vendor/koalasand/LICENSE','release/KoalaSand-LICENSE.txt');
console.log('WALLPAPER_PACKAGE_PASS: release/KoalaSandPaper-Lively.zip');
