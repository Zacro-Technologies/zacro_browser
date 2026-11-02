const fs=require('node:fs');
const os=require('node:os');
const path=require('node:path');
const {randomBytes}=require('node:crypto');
const {spawn}=require('node:child_process');
const {createSyncService}=require(path.resolve(__dirname,'../../../services/sync/server.cjs'));
(async()=>{
 const root=process.argv[3] || fs.mkdtempSync(path.join(os.tmpdir(),'zacro-live-native-sync-'));
 fs.mkdirSync(root,{recursive:true,mode:0o700});
 const key=randomBytes(32); let service, child;
 try {
  service=await createSyncService({directory:path.join(root,'server'),masterKey:key,allowInsecureLoopback:true});
  const executable=process.argv[2];
  const code=await new Promise((resolve,reject)=>{
   child=spawn(executable,[service.url,path.join(root,'clients')],{stdio:['ignore','inherit','inherit']});
   const timer=setTimeout(()=>{child.kill('SIGKILL');reject(new Error('Probe timed out'));},90000);
   child.once('error',error=>{clearTimeout(timer);reject(error)});
   child.once('exit',code=>{clearTimeout(timer);resolve(code??1)});
  });
  if(code!==0)throw new Error('Native probe returned '+code);
  console.log('PASS complete native/Node transport integration');
 } finally {
  if(child&&child.exitCode===null)child.kill('SIGKILL');
  if(service)await service.close(); key.fill(0); fs.rmSync(root,{recursive:true,force:true});
  console.log('Temporary server and account data removed');
 }
})().catch(error=>{console.error(error.message);process.exitCode=1});
