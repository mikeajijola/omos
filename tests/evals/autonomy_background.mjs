// Drive the same coordinator and background host used by the installed UI.
import {NativeClient} from '../e2e/workspace-ui-client.mjs';
import {spawn} from 'node:child_process';
import {readFileSync,writeFileSync,appendFileSync} from 'node:fs';
const [binary,project,root,model]=process.argv.slice(2);
const task=JSON.parse(readFileSync(`${root}/task.json`));
const client=new NativeClient({binary,project});
const worker=spawn(binary,['ui-host','--background-serve'],{cwd:project,env:process.env,stdio:['ignore','ignore','pipe']});
worker.stderr.on('data',data=>appendFileSync(`${root}/background-stderr.log`,data));
client.on('event',event=>appendFileSync(`${root}/foreground-events.ndjson`,JSON.stringify({at:Date.now(),...event})+'\n'));
const pause=()=>new Promise(resolve=>setTimeout(resolve,1000));
let code=1;
try {
 await client.request('coordinate',{text:task.prompt,model},{id:'live-background-evaluation'});
 let record;
 let previous;
 while(true){
  const listing=await client.request('background');
  record=listing.workers?.[0]?.record;
  if(record){
   const transition=JSON.stringify({state:record.state,generation:record.generation,recoveries:record.recoveries,worker_session:record.worker_session,reason:record.reason});
   if(transition!==previous){appendFileSync(`${root}/background-transitions.ndjson`,JSON.stringify({at:Date.now(),...JSON.parse(transition)})+'\n');previous=transition;}
   const status=await client.request('background',{action:'show',task:record.task});
   writeFileSync(`${root}/background-status.json`,JSON.stringify(status,null,2));
   if(record.state==='completed'){code=0;break;}
   if(['cancelled','superseded'].includes(record.state))break;
   // Waiting can be a transient state before bounded recovery. Keep observing.
  }
  await pause();
 }
 console.log(JSON.stringify({exit_code:code,session_id:record?.worker_session,background:record}));
} finally {
 await client.request('background',{action:'stop'}).catch(()=>{});
 await client.close();
 worker.kill('SIGTERM');
}
process.exitCode=code;
