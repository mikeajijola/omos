import {afterEach,expect,test} from 'bun:test';
import {resolve,join} from 'node:path';
import {existsSync,mkdirSync,readFileSync,writeFileSync,readdirSync,unlinkSync} from 'node:fs';
import {execFileSync} from 'node:child_process';
import {createHash} from 'node:crypto';
import {NativeClient} from './workspace-ui-client.mjs';
import {cleanupFixtures,fixture,model} from './fossil-workspace-helpers';
const clients:NativeClient[]=[];
const services:ReturnType<typeof Bun.spawn>[]=[];
const classifiers:ReturnType<typeof Bun.serve>[]=[];
afterEach(async()=>{for(const client of clients.splice(0))await client.close();for(const service of services.splice(0)){service.kill();await service.exited}for(const server of classifiers.splice(0))server.stop(true);cleanupFixtures()});
function host(f:ReturnType<typeof fixture>,extra:Record<string,string>={}){const native=new NativeClient({binary:resolve(import.meta.dir,'../../zig-out/bin/fx'),project:f.cwd,env:{...process.env,...f.env,...extra}});clients.push(native);return native}
function routingClassifier(route:(message:string)=>string){
 const server=Bun.serve({hostname:'127.0.0.1',port:0,async fetch(request){
  const body=await request.json() as any;const choice=route(body.state.latest_message);
  return Response.json({model:'fixture-classifier',answers:{route:{type:'choice',choice,confidence:0.99,probabilities:Object.fromEntries(['conversation','retrieval','work','unresolved'].map(label=>[label,label===choice?0.99:0.01/3]))}}});
 }});classifiers.push(server);
 return {OMOS_CLASSIFIER_URL:`http://127.0.0.1:${server.port}`,OMOS_CLASSIFIER_MODEL:'fixture-classifier'};
}
async function terminal(native:NativeClient,turn:string){return await new Promise<any>((resolve,reject)=>{const timer=setTimeout(()=>{native.off('event',listener);reject(Error('UI invocation did not stop'))},90000);const listener=(event:any)=>{if(event.turn===turn&&event.data.type==='turn_end'){clearTimeout(timer);native.off('event',listener);resolve(event)}};native.on('event',listener)})}
test('native UI host saves governed turns and replays public events without repeating actions',async()=>{
 const f=fixture();const fixtureModel=model(f,()=>({content:'Hello from the governed native agent.'}));expect((await f.run(['fossil','init','--json'])).code).toBe(0);
 const native=host({...f,env:{...f.env,FX_CONTRACT_REVIEW:"0"}});expect((await native.request('initialize')).version).toBe('omos.ui-host/v1');
 const seen:any[]=[];native.on('event',(event:any)=>seen.push(event));const ending=terminal(native,'ui-runtime-one');await native.request('prompt',{text:'Say hello from this workspace.'},{id:'ui-runtime-one'});const ended=await ending;if(ended.data.exit_code)console.error(JSON.stringify(seen),native.stderr);expect(ended.data.exit_code).toBe(0);
 const session=seen.find(e=>e.data.type==='session')?.data.session_id;expect(session).toBeString();
 const saved=await native.request('snapshot',{action:'session',id:session});expect(saved.history.some((h:any)=>h.assistant?.includes('governed native agent'))).toBe(true);
 const state=await native.request('snapshot',{action:'fossil.status'});expect(state.tasks[0].state).toBe('accepted');
 const count=fixtureModel.counts().actors;const duplicate=await native.request('prompt',{text:'Say hello from this workspace.'},{id:'ui-runtime-one'});expect(duplicate.already_accepted).toBe(true);expect(fixtureModel.counts().actors).toBe(count);
 await expect(native.request('prompt',{text:'Different action'},{id:'ui-runtime-one'})).rejects.toThrow('TurnIdConflict');
 const replay=await native.request('session.events',{session});expect(replay.events.some((e:any)=>e.data.type==='session')).toBe(true);expect(replay.active).toBe(false);
 await expect(native.request('snapshot',{action:'shell'})).rejects.toThrow('UnsupportedSnapshot');
 await expect(native.request('ui.read',{revision:'trunk',path:'ui/manifest.json'})).rejects.toThrow('ImmutableRevisionRequired');
 expect(native.stderr).toBe('');
},90000);

test('native UI writes require a task fence and compilation evidence before publication',async()=>{
 const f=fixture();let wrote=false;model(f,()=>wrote?{content:'Updated the workspace interface.'}:(wrote=true,{tool_calls:[{index:0,id:'write-ui',type:'function',function:{name:'fossil_workspace',arguments:JSON.stringify({action:'write',path:'ui/manifest.json',content:JSON.stringify({version:'omos.ui-source/v1',bridge:'omos.ui-bridge/v1',renderer:'omos.react/v1',toolchain:'a'.repeat(64),entry:'src/main.tsx',stylesheet:'src/style.css'})})}}]}));expect((await f.run(['fossil','init','--json'])).code).toBe(0);
 const native=new NativeClient({binary:resolve(import.meta.dir,'../../zig-out/bin/fx'),project:f.cwd,env:{...process.env,...f.env,FX_MAX_AGENT_STEPS:'12'}});clients.push(native);const observed:any[]=[];let validation:any;native.on('event',(event:any)=>{observed.push(event);if(event.data.type==='validate_ui'){validation=event;void native.request('validation',{turn:event.turn,request_id:event.data.request_id,receipt:{version:'omos.ui-validation/v1',status:'failed',error:'Missing entry source'}})}});
 const end=terminal(native,'invalid-ui-source');await native.request('prompt',{text:'Update the interface, preserving its governed source.'},{id:'invalid-ui-source'});await end;if(!validation)console.error(JSON.stringify(observed),native.stderr);expect(validation).toBeDefined();
 const state=await native.request('snapshot',{action:'fossil.status'});expect(state.tasks[0].state).not.toBe('accepted');expect(state.files.includes('ui/manifest.json')).toBe(false);
 await expect(native.request('validation',{turn:'invalid-ui-source',request_id:validation.data.request_id,receipt:{status:'passed'}})).rejects.toThrow();
},90000);

test('UI inspection preserves revision-bound binary and duplicate contents across batches',async()=>{
 const f=fixture();expect((await f.run(['fossil','init','--json'])).code).toBe(0);
 const native=host(f);const before=await native.request('snapshot',{action:'fossil.status'});
 await expect(native.request('ui.inspect',{revision:before.trunk_revision})).rejects.toThrow('UiNotInstalled');
 const source=new Map<string,Buffer>();
 source.set('ui/manifest.json',Buffer.from(JSON.stringify({version:'omos.ui-source/v1',bridge:'omos.ui-bridge/v1',renderer:'omos.react/v1',toolchain:'a'.repeat(64)})));
 for(let i=0;i<35;i++)source.set(`ui/src/file-${i}.txt`,Buffer.from(i%2?'shared source':`source ${i}`));
 source.set('ui/src/large.bin',Buffer.from(Array.from({length:65537},(_,i)=>i%256)));
 const files=[...source].map(([path,bytes])=>({path,content:bytes.toString('base64'),encoding:'base64',sha256:createHash('sha256').update(bytes).digest('hex')}));
 const installed=await native.request('ui.install',{revision:before.trunk_revision,files});
 for(const revision of [installed.revision,installed.revision.slice(0,40)]){
  const inspected=await native.request('ui.inspect',{revision});
  expect(inspected.files.length).toBe(source.size);
  for(const file of inspected.files){const bytes=source.get(file.path)!;expect(file.bytes).toBe(bytes.length);expect(file.sha256).toBe(createHash('sha256').update(bytes).digest('hex'));}
 }
 const page=await native.request('ui.read',{revision:installed.revision,path:'ui/src/large.bin',offset:65536});
 expect(Buffer.from(page.content,'base64')).toEqual(source.get('ui/src/large.bin')!.subarray(65536));
 expect(page.next_offset).toBeNull();
 await expect(native.request('ui.inspect',{revision:'trunk'})).rejects.toThrow('ImmutableRevisionRequired');
 expect(native.stderr).toBe('');
},90000);

test('legacy interface history is retained once on an unpublished branch',async()=>{
 const f=fixture();expect((await f.run(['fossil','init','--json'])).code).toBe(0);const native=host(f);const before=await native.request('snapshot',{action:'fossil.status'});
 const content=JSON.stringify({version:'omos.ui-legacy-input/v1',status:'unpublished_input',files:[{path:'.revisions/old.json',content:'Retained local appearance input'}]});const retained=await native.request('ui.import_legacy',{content});expect(retained.retained).toBe(true);expect(retained.publication).toBe('unpublished');expect(retained.artifact).toStartWith('artifacts/');
 const again=await native.request('ui.import_legacy',{content});expect(again.task).toBe(retained.task);const after=await native.request('snapshot',{action:'fossil.status'});expect(after.trunk_revision).toBe(before.trunk_revision);expect(after.tasks.length).toBe(1);expect(after.tasks[0].state).toBe('paused');
},90000);


test('a live UI host cannot silently retarget a changed workspace binding',async()=>{
 const f=fixture();expect((await f.run(['fossil','init','--json'])).code).toBe(0);const native=host(f);const initial=await native.request('initialize');expect(initial.workspace).toBeString();
 const other=join(f.home,'other-project');mkdirSync(other);execFileSync(resolve(import.meta.dir,'../../zig-out/bin/fx'),['fossil','init','--json'],{cwd:other,env:{...process.env,...f.env},encoding:'utf8'});
 await expect(native.request('snapshot',{action:'fossil.status'})).rejects.toThrow('WorkspaceBindingChanged');
 await expect(native.request('prompt',{text:'This request must not run in another repository.'},{id:'changed-binding-request'})).rejects.toThrow('WorkspaceBindingChanged');
},90000);

test('temporary workspace contention does not cancel an active UI conversation',async()=>{
 const f=fixture();let entered=false;let release!:()=>void;const gate=new Promise<void>(r=>release=r);
 model(f,async()=>{entered=true;await gate;return {content:'The foreground answer survived temporary workspace contention.'};});
 expect((await f.run(['fossil','init','--json'])).code).toBe(0);
 const native=host(f);const observed:any[]=[];native.on('event',(e:any)=>observed.push(e));
 const ending=terminal(native,'contention-survival');
 await native.request('prompt',{text:'Provide a short informational answer.'},{id:'contention-survival'});
 const deadline=Date.now()+30000;while(!entered&&Date.now()<deadline)await Bun.sleep(20);expect(entered).toBe(true);
 const binding=JSON.parse(readFileSync(join(f.home,'.fx/omos-workspace.json'),'utf8'));
 const commandLock=join(f.home,'.fx/fossil',createHash('sha256').update(binding.repository).digest('hex'),'command.lock');
 const blocker=Bun.spawn(['python3','-u','-c',"import fcntl,sys\nwith open(sys.argv[1],'r+') as lock:\n fcntl.flock(lock,fcntl.LOCK_EX)\n print('locked',flush=True)\n sys.stdin.read()\n",commandLock],{stdin:'pipe',stdout:'pipe',stderr:'pipe'});
 try{
  const reader=blocker.stdout.getReader();let signal='';while(!signal.includes('\n')){const chunk=await reader.read();if(chunk.done)break;signal+=new TextDecoder().decode(chunk.value);}reader.releaseLock();expect(signal).toBe('locked\n');
  await expect(native.request('initialize',{}, {timeout:60000})).rejects.toThrow('WorkspaceBusy');
 }finally{blocker.stdin.end();await blocker.exited;release();}
 expect((await ending).data.exit_code).toBe(0);
 const result=observed.find(e=>e.data.type==='result');
 expect(result.data.data.final_output).toContain('survived temporary workspace contention');
 expect(native.stderr).toBe('');
},90000);

test('workspace content is natively authorized in auto mode without an auxiliary safety reviewer', async()=>{
 const f=fixture();let stage=0;const calls:any[]=[];
 model(f,(body)=>{calls.push(body);stage++;
  if(stage===1)return {tool_calls:[{index:0,id:'status',type:'function',function:{name:'fossil_workspace',arguments:JSON.stringify({action:'status'})}}]};
  if(stage===2)return {tool_calls:[{index:0,id:'write',type:'function',function:{name:'fossil_workspace',arguments:JSON.stringify({action:'write',path:'memory/native-owner.md',content:'Workspace ownership checked by the native host.'})}}]};
  return {content:'Saved the workspace note.'};
 });
 expect((await f.run(['fossil','init','--json'])).code).toBe(0);
 const native=host({...f,env:{...f.env,FX_PERMISSION_MODE:'auto'}});const seen:any[]=[];native.on('event',(event:any)=>seen.push(event));
 const ending=terminal(native,'native-workspace-authority');await native.request('prompt',{text:'Save a note in this workspace.'},{id:'native-workspace-authority'});await ending;
 expect(calls.length).toBe(3);
 expect(calls[0].messages.some((m:any)=>m.role==='system'&&m.content.includes('Fossil ui/ tree'))).toBe(true);
 const tool=seen.find(e=>e.data.type==='tool_start'&&e.data.call_id==='write');expect(tool.data.path).toBe('memory/native-owner.md');expect(tool.data.action).toBe('write');expect(tool.data.content).toBeUndefined();
 const state=await native.request('snapshot',{action:'fossil.status'});expect(state.files.includes('memory/native-owner.md')).toBe(true);expect(state.tasks[0].state).toBe('accepted');expect(native.stderr).toBe('');
},90000);

function nextEvent(native: NativeClient, matches: (event: any) => boolean) {
 return new Promise<any>((resolve,reject)=>{
  const timer=setTimeout(()=>{native.off('event',listener);reject(Error('Scheduled invocation did not expose its input'))},45000);
  const listener=(event:any)=>{if(matches(event)){clearTimeout(timer);native.off('event',listener);resolve(event)}};
  native.on('event',listener);
 });
}

async function scheduledState(read:()=>Promise<any>, wanted:string) {
 const deadline=Date.now()+45000;let latest:any;
 do{latest=await read();if(latest.schedules[0]?.state===wanted)return latest;await Bun.sleep(100)}while(Date.now()<deadline);
 throw Error(`Schedule did not become ${wanted}: ${JSON.stringify(latest)}`);
}

function questionCall() {
 return {tool_calls:[{index:0,id:'scheduled-choice',type:'function',function:{name:'ask_user_question',arguments:JSON.stringify({questions:[{question:'Which presentation should the retained report use?',options:[{label:'Brief'},{label:'Detailed'}]}]})}}]};
}

test('scheduled UI work exposes its active native turn and accepts a user answer',async()=>{
 const f=fixture();let phase='initial';
 const provider=model(f,()=>phase==='question'?questionCall():{content:phase==='initial'?'The report needs a presentation choice.':'The retained report uses the requested brief presentation.'},()=>phase==='initial'?'blocked':phase==='question'?'pending':'met');
 expect((await f.run(['fossil','init','--json'])).code).toBe(0);
 expect((await f.run(['ask','Prepare a report after I choose its presentation','--json'])).code).toBe(1);
 const task=JSON.parse((await f.run(['fossil','tasks','--json'])).stdout).tasks[0];
 const native=host(f);const before=await native.request('schedule',{action:'list'});
 const input=nextEvent(native,event=>event.data.type==='input_required'&&event.data.kind==='question');
 phase='question';
 const created=await native.request('schedule',{action:'add',task:task.id,at:'2020-01-01T09:00:00Z',revision:before.revision});
 const required=await input.catch(async(error)=>{throw Error(`${error.message}: ${JSON.stringify(await native.request('schedule',{action:'show',id:created.schedules[0].id}))} ${native.stderr}`)});
 expect(required.turn).toStartWith('schedule-');
 expect((await native.request('initialize')).active_turn).toBe(required.turn);
 const actors=provider.counts().actors;const secondHost=host(f);
 const running=await secondHost.request('schedule',{action:'show',id:created.schedules[0].id});
 expect(running.schedules[0].state).toBe('running');
 expect(provider.counts().actors).toBe(actors);
 phase='answered';
 await native.request('input',{turn:required.turn,request_id:required.data.request_id,answers:['Brief']});
 const final=await scheduledState(()=>native.request('schedule',{action:'show',id:created.schedules[0].id}),'completed');
 expect(final.schedules[0].task_state).toBe('accepted');
 expect(final.schedules[0].contract_version).toBe(task.definition.version);
 expect(final.schedules[0].history.filter((event:any)=>event.kind==='running')).toHaveLength(1);
 expect(native.stderr).toBe('');
},120000);

async function workspaceService(f:ReturnType<typeof fixture>) {
 const token='scheduled-workspace-service-fixture-token';
 const child=Bun.spawn([resolve(import.meta.dir,'../../zig-out/bin/fx'),'fossil','serve','0','--write','--json'],{cwd:f.cwd,env:{...process.env,...f.env,OMOS_WORKSPACE_TOKEN:token},stdout:'pipe',stderr:'pipe'});
 services.push(child);const reader=(child.stdout as ReadableStream<Uint8Array>).getReader();let bytes='';
 try{
  while(!bytes.includes('\n')){
   const result=await Promise.race([reader.read(),Bun.sleep(15000).then(()=>{throw Error('Scheduled HTTP host did not become ready')})]);
   if(result.done)throw Error('Scheduled HTTP host exited before readiness');bytes+=new TextDecoder().decode(result.value);
  }
 }finally{reader.releaseLock()}
 const ready=JSON.parse(bytes.split('\n')[0]);
 return {child,ready,async request(body:object,authorized=true){
  // These fixtures restart services and intentionally close rejected requests.
  // Use one connection per operation rather than a stale Bun pooled socket.
  try{return await fetch(`http://127.0.0.1:${ready.port}/v1/schedules`,{method:'POST',keepalive:false,headers:{authorization:`Bearer ${authorized?token:'wrong-token'}`,'content-type':'application/json'},body:JSON.stringify({version:'omos.schedule/v1',workspace:ready.workspace,...body})})}
  catch(error){
   const exit=child.exitCode;child.kill();await child.exited;
   throw Error(`${error}\nService exit before cleanup: ${exit}\n${await new Response(child.stderr).text()}\n${existsSync(f.env.FX_TRACE_LOG)?readFileSync(f.env.FX_TRACE_LOG,'utf8').slice(-16000):''}`);
  }
 }};
}

test.each(['question','approval'])('scheduled HTTP work retains %s without waiting for terminal input',async(kind)=>{
 const f=fixture();let scheduled=false;
 const provider=model(f,()=>scheduled?(kind==='question'?questionCall():{tool_calls:[{index:0,id:'scheduled-write',type:'function',function:{name:'shell',arguments:JSON.stringify({request:{action:'run',command:'printf scheduled-permission > permission-held.txt',timeout_ms:10000}})}}]}):{content:'A presentation choice is still required.'},()=>scheduled?'pending':'blocked');
 expect((await f.run(['fossil','init','--json'])).code).toBe(0);
 expect((await f.run(['ask','Prepare the report after its presentation is chosen','--json'])).code).toBe(1);
 const task=JSON.parse((await f.run(['fossil','tasks','--json'])).stdout).tasks[0];
 const isolated=kind==='approval'?{...f,env:{...f.env,FX_PERMISSION_MODE:'ask'}}:f;
 const service=await workspaceService(isolated);
 const unauthorized=await service.request({action:'list'},false);
 expect(unauthorized.status).toBe(401);expect(await unauthorized.json()).toEqual({error:'Unauthorized'});
 const list=await(await service.request({action:'list'})).json();
 const unpinned=await service.request({action:'add',task:task.id,at:'2020-01-01T09:00:00Z'});
 expect(unpinned.status).toBe(400);expect(await unpinned.json()).toEqual({error:'WorkspaceRevisionRequired'});
 scheduled=true;
 const create=await service.request({action:'add',task:task.id,at:'2020-01-01T09:00:00Z',revision:list.revision});
 expect(create.status).toBe(200);const created=await create.json();
 const final=await scheduledState(async()=>(await service.request({action:'show',id:created.schedules[0].id})).json(),'waiting');
 expect(final.schedules[0].reason).toBe('ScheduledInputRequired');
 expect(final.schedules[0].task_state).not.toBe('accepted');
 if(kind==='approval')expect(existsSync(join(f.cwd,'permission-held.txt'))).toBe(false);
 expect(final.schedules[0].history.filter((event:any)=>event.kind==='running')).toHaveLength(1);
 const actors=provider.counts().actors;
 service.child.kill();await service.child.exited;services.splice(services.indexOf(service.child),1);
 expect(await new Response(service.child.stderr).text()).toBe('');
 const restarted=await workspaceService(isolated);
 const retained=await(await restarted.request({action:'show',id:created.schedules[0].id})).json();
 expect(retained.schedules[0].state).toBe('waiting');
 expect(provider.counts().actors).toBe(actors);
},120000);

test('background contracts release the main chat while workers await input and publish independently', async () => {
 const f = fixture(); let answered = false; let workerCalls = 0; let coordinatorCalls = 0; const assignments:string[]=[];
 const pngBase64='iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';
 const imagePath=join(f.cwd,'reference.png');writeFileSync(imagePath,Buffer.from(pngBase64,'base64'));
 model(f, (body) => {
  const names = body.tools?.map((tool:any) => tool.function?.name) || [];
  const system = body.messages.filter((m:any)=>m.role==='system').map((m:any)=>m.content).join('\n');
  if (!names.includes('write_file')) {
   coordinatorCalls++;
   expect(system).not.toContain('<omos_background_assignment');
   const user = body.messages.filter((m:any) => m.role === 'user').at(-1)?.content || '';
   if (String(user).includes('still available')) return {content:'The main chat is still available.'};
   expect(names).not.toContain('shell');
   return {tool_calls:[{index:0,id:'dispatch-original-contract',type:'function',function:{name:'fossil_workspace',arguments:'{"action":"dispatch"}'}}]};
  }
  workerCalls++;
  const assignment=system.match(/<omos_background_assignment task="([a-f0-9]{64})">/);
  expect(assignment).not.toBeNull();assignments.push(assignment![1]);
  expect(system).toContain('Complete the remaining implementation, validation and delivery directly');
  const images=body.messages.flatMap((message:any)=>Array.isArray(message.content)?message.content.filter((part:any)=>part.type==='image_url'):[]);
  expect(images.some((part:any)=>part.image_url?.url===`data:image/png;base64,${pngBase64}`)).toBe(true);
  if (!answered) return questionCall();
  return {content:'The requested report uses the chosen brief presentation.'};
 });
 const settingsPath=join(f.home,'.fx','settings.json');const settings=JSON.parse(readFileSync(settingsPath,'utf8'));settings.providers.local.model_metadata['fixture-model'].supports_vision=true;writeFileSync(settingsPath,JSON.stringify(settings));
 expect((await f.run(['fossil','init','--json'])).code).toBe(0);
 const native = host(f,routingClassifier(message=>message==='Are you still available?'?'conversation':'work')); const observed:any[] = [];
 native.on('event', (event:any) => observed.push(event));
 const until = async (read:()=>Promise<any>, predicate:(value:any)=>boolean) => {
  const deadline = Date.now()+60000; let value:any;
  do { value = await read(); if(predicate(value)) return value; await Bun.sleep(100); } while(Date.now()<deadline);
  throw Error(`Background state did not converge: ${JSON.stringify(value)}; ${native.stderr}`);
 };
 try {
  // A foreground Fossil operation may hold the command lease longer than the
  // worker's 30-second bounded wait. The same host must survive and dispatch
  // the following contract once the lease becomes available.
  const slowStart=join(f.home,'slow-host-start');writeFileSync(slowStart,'delay');
  const fossilWrapper=join(f.home,'slow-fossil');
  const realFossil=Bun.which('fossil');expect(realFossil).not.toBeNull();
  writeFileSync(fossilWrapper,`#!/usr/bin/env python3\nimport os,sys,time\nif os.path.exists(${JSON.stringify(slowStart)}) and 'cat' in sys.argv:\n time.sleep(6)\nos.execv(${JSON.stringify(realFossil)},[${JSON.stringify(realFossil)}]+sys.argv[1:])\n`,{mode:0o755});
  try {
   expect((await f.run(['ui-host','--background-start'],{OMOS_FOSSIL_BIN:fossilWrapper})).code).toBe(0);
  } finally { unlinkSync(slowStart); }
  const rootHash=createHash('sha256').update(join(f.cwd,'omos.fossil')).digest('hex');
  const commandLock=join(f.home,'.fx','fossil',rootHash,'command.lock');
  const blocker=Bun.spawn(['python3','-u','-c',"import fcntl,sys,time\nwith open(sys.argv[1],'r+') as lock:\n fcntl.flock(lock,fcntl.LOCK_EX)\n print('locked',flush=True)\n time.sleep(36)\n",commandLock],{stdout:'pipe',stderr:'pipe'});
  try {
   expect(await new Response(blocker.stdout).text()).toBe('locked\n');
   expect(await blocker.exited).toBe(0);
   expect((await native.request('background',{action:'host'})).running).toBe(true);
  } finally { blocker.kill(); await blocker.exited; }
  const ending = terminal(native,'dispatch-report');
  await native.request('coordinate',{text:'Prepare the report using the attached reference after I choose its presentation.',images:[imagePath]},{id:'dispatch-report'});
  const handoffEnd = await ending;
  if (handoffEnd.data.exit_code) console.error(JSON.stringify(observed), native.stderr);
  expect(handoffEnd.data.exit_code).toBe(0);
  const dispatched = observed.find(e=>e.data.type==='background_dispatch');
  expect(dispatched).toBeDefined();
  expect(coordinatorCalls).toBe(0);
  const original = (await native.request('background')).workers[0].record;
  expect(original.state).not.toBe('completed'); expect(original.publication_revision).toBeNull();
  const repositoryHash=createHash('sha256').update(join(f.cwd,'omos.fossil')).digest('hex');
  const activation=JSON.parse(readFileSync(join(f.home,'.fx','fossil',repositoryHash,'background','authority',original.operation+'.json'),'utf8'));
  expect(activation.images).toHaveLength(1);expect(activation.images[0].inline_data).toBeNull();
  expect(createHash('sha256').update(readFileSync(activation.images[0].snapshot_path)).digest('hex')).toBe(activation.images[0].snapshot_sha256);
  // Original upload paths are mutable; the worker owns verified snapshot bytes.
  writeFileSync(imagePath,'The original upload was replaced after handoff.');
  const session = observed.find(e=>e.data.type==='session').data.session_id;
  const running = await until(()=>native.request('background',{action:'show',task:original.task}), value=>value.state==='running');
  const input = await until(()=>native.request('background',{action:'events',task:original.task,generation:running.generation}), value=>value.events.some((e:any)=>e.data.type==='input_required'));
  expect(workerCalls).toBe(1);
  const endingSecond = terminal(native,'main-while-worker-waits');
  await native.request('coordinate',{text:'Are you still available?',session},{id:'main-while-worker-waits'});
  expect((await endingSecond).data.exit_code).toBe(0);
  expect(observed.some(e=>e.turn==='main-while-worker-waits' && e.data.type==='text_delta' && e.data.text.includes('still available'))).toBe(true);
  expect(coordinatorCalls).toBe(1);
  expect((await native.request('background',{action:'show',task:original.task})).state).toBe('running');
  const required = input.events.find((e:any)=>e.data.type==='input_required').data;
  await expect(native.request('background',{action:'input',task:original.task,generation:running.generation+1,operation:'b'.repeat(64),request_id:required.request_id,answers:['Brief']})).rejects.toThrow('StaleBackgroundOwner');
  answered = true;
  const operation = 'a'.repeat(64);
  await native.request('background',{action:'input',task:original.task,generation:running.generation,operation,request_id:required.request_id,answers:['Brief']});
  const final = await until(()=>native.request('background',{action:'show',task:original.task}), value=>value.state==='completed'||value.state==='waiting');
  if (final.state !== 'completed') {
   let offset=0; const diagnostics:any[]=[];
   for(let page=0;page<8;page++){const result=await native.request('background',{action:'events',task:original.task,generation:running.generation,offset});diagnostics.push(...result.events);if(result.next_offset===offset)break;offset=result.next_offset;}
   console.error('background final',JSON.stringify(final),JSON.stringify(diagnostics.filter(e=>['result','error','notice','background_outcome'].includes(e.data.type)).slice(-12)));
  }
  expect(final.state).toBe('completed'); expect(final.task).toBe(original.task);
  expect(assignments).toEqual([original.task,original.task]);
  expect(final.contract_sha256).toBe(original.contract_sha256); expect(final.publication_revision).toMatch(/^[a-f0-9]{40,64}$/);
  const tasks = await native.request('snapshot',{action:'fossil.status'});
  expect(tasks.tasks.find((task:any)=>task.id===original.task).state).toBe('accepted');
  const actorsBeforeRecovery = workerCalls;
  const reconcile = {action:'resume',task:original.task,generation:running.generation,operation:'c'.repeat(64)};
  expect((await native.request('background',reconcile)).fulfilled).toBe(true);
  expect((await native.request('background',reconcile)).already_accepted).toBe(true);
  await expect(native.request('background',{...reconcile,text:'Changed retry'})).rejects.toThrow('BackgroundOperationConflict');
  expect(workerCalls).toBe(actorsBeforeRecovery);
  expect(native.stderr).toBe('');
 } finally {
  await native.request('background',{action:'stop'});
  await until(()=>native.request('background',{action:'host'}), value=>!value.running);
 }
},180000);


test('host-proposed coordinator handoff respects configured tool denial', async()=>{
 const f=fixture();let calls=0;
 model(f,(body)=>{calls++;expect(body.tools?.some((tool:any)=>tool.function?.name==='fossil_workspace')).toBe(false);return {content:'The configured policy denied the background handoff.'}});
 const settingsPath=join(f.home,'.fx','settings.json');const settings=JSON.parse(readFileSync(settingsPath,'utf8'));
 settings.permission={fossil_workspace:'deny'};writeFileSync(settingsPath,JSON.stringify(settings));
 expect((await f.run(['fossil','init','--json'])).code).toBe(0);
 const native=host(f,{...routingClassifier(()=>'work'),FX_PERMISSION_MODE:'auto'});const seen:any[]=[];
 native.on('event',(event:any)=>seen.push(event));
 const end=terminal(native,'denied-handoff');
 await native.request('coordinate',{text:'Prepare a report in this workspace.'},{id:'denied-handoff'});
 await end;
 expect(calls).toBeGreaterThan(0);
 expect(seen.some(e=>e.data.type==='background_dispatch')).toBe(false);
 expect((await native.request('background')).workers).toHaveLength(0);
 expect(seen.some(e=>e.data.type==='notice'&&e.data.text.includes('Queuing the validated work contract'))).toBe(false);
 expect(native.stderr).toBe('');
},90000);

for(const classified of [false,true])test(`coordinator chat does not auto-dispatch with classification ${classified?'configured':'absent'}`,async()=>{
 const f=fixture();let calls=0;
 model(f,()=>{calls++;return {content:'I am available to help.'}});
 expect((await f.run(['fossil','init','--json'])).code).toBe(0);
 const native=host(f,classified?routingClassifier(()=>'conversation'):{});const seen:any[]=[];
 native.on('event',(event:any)=>seen.push(event));
 let session:string|undefined;
 for(const [index,text] of ['Hello','Are you still available?'].entries()){
  const id=`chat-${index}`;const end=terminal(native,id);
  await native.request('coordinate',{text,...(session?{session}:{})},{id});
  expect((await end).data.exit_code).toBe(0);
  session=seen.find(e=>e.data.type==='session').data.session_id;
  expect(seen.some(e=>e.turn===id&&e.data.type==='text_delta'&&e.data.text.includes('available'))).toBe(true);
 }
 expect(calls).toBe(2);
 expect(seen.some(e=>e.data.type==='background_dispatch')).toBe(false);
 expect((await native.request('background')).workers).toHaveLength(0);
 expect(native.stderr).toBe('');
},90000);

for(const history of ['long ancestry','unrelated fork'])test(`restarted background host checks ${history} without repeating its external effect`, async()=>{
 const f=fixture(); const receipt=join(f.cwd,'external-receipts.txt'); let workerCalls=0; let interrupted=false;
 const call=(id:string,command:string)=>({tool_calls:[{index:0,id,type:'function',function:{name:'shell',arguments:JSON.stringify({action:'run',profile:'clean',command})}}]});
 model(f,async(body,_count,signal)=>{
  const system=body.messages.filter((m:any)=>m.role==='system').map((m:any)=>m.content).join('\n');
  if(!system.includes('<omos_background_assignment'))return {tool_calls:[{index:0,id:'dispatch-once',type:'function',function:{name:'fossil_workspace',arguments:'{"action":"dispatch"}'}}]};
  workerCalls++;
  if(workerCalls===1)return call('perform-once',`printf 'receipt-1\\n' >> '${receipt}'`);
  if(workerCalls===2){interrupted=true;await new Promise<void>(resolve=>{if(signal?.aborted)resolve();else signal?.addEventListener('abort',()=>resolve(),{once:true})});return {content:'Interrupted transport'};}
  expect(system).toContain('Use read-only checks to reconcile');
  if(workerCalls===3)return call('inspect-existing-receipt',`cat '${receipt}'`);
  return {content:'The external action completed once; receipt-1 is retained and verified.'};
 });
 expect((await f.run(['fossil','init','--json'])).code).toBe(0);
 const native=host(f);
 const until=async(read:()=>Promise<any>,predicate:(value:any)=>boolean)=>{const deadline=Date.now()+90000;let v:any;do{v=await read();if(predicate(v))return v;await Bun.sleep(100)}while(Date.now()<deadline);throw Error(JSON.stringify(v)+native.stderr)};
 const start=()=>{const child=Bun.spawn([resolve(import.meta.dir,'../../zig-out/bin/fx'),'ui-host','--background-serve'],{cwd:f.cwd,env:{...process.env,...f.env},stdout:'pipe',stderr:'pipe'});services.push(child);return child};
 const first=start();
 try{
  await until(()=>native.request('background',{action:'host'}),v=>v.running);
  const end=terminal(native,'recover-background');
  await native.request('coordinate',{text:'Perform the external action once and retain its receipt.'},{id:'recover-background'});
  expect((await end).data.exit_code).toBe(0);
  await until(async()=>interrupted,v=>v);
  expect(readFileSync(receipt,'utf8')).toBe('receipt-1\n');
  const original=(await native.request('background')).workers[0].record;
  first.kill('SIGKILL');await first.exited;
  // More than one timeline page separates the retained contract from its head.
  // Exercise real check-ins rather than fabricating ancestry in the database.
  const checkout=join(f.home,'long-history');mkdirSync(checkout);
  const fossil=(args:string[])=>execFileSync('fossil',['--user','omos',...args],{cwd:checkout,env:{PATH:process.env.PATH,HOME:f.home,FOSSIL_HOME:f.home,XDG_CONFIG_HOME:f.home,USER:'fixture',LC_ALL:'C'},encoding:'utf8'});
  const taskPath=`tasks/${original.task}.json`;
  const retained=f.fossil('cat',taskPath,'-r',`task/${original.task}`);
  fossil(['open',join(f.cwd,'omos.fossil'),history==='long ancestry'?`task/${original.task}`:'trunk']);
  if(history==='long ancestry'){
   for(let i=0;i<130;i++)fossil(['commit','--allow-empty','--nosign','-m',`Retained checkpoint ${i}`]);
  }else{
   mkdirSync(join(checkout,'tasks'),{recursive:true});writeFileSync(join(checkout,taskPath),retained);
   fossil(['add',taskPath]);
   fossil(['commit','--allow-fork','--force','--branch',`task/${original.task}`,'--nosign','-m','Unrelated replacement branch']);
  }
  fossil(['close']);
  const second=start();
  const finished=await until(()=>native.request('background',{action:'show',task:original.task}),v=>history==='long ancestry'?v.state==='completed':v.state==='waiting'&&v.reason==='StaleWorkContract');
  expect(finished.worker_session).toBe(original.worker_session);
  expect(readFileSync(receipt,'utf8')).toBe('receipt-1\n');
  if(history==='long ancestry'){
   expect(finished.generation).toBe(2);expect(finished.recoveries).toBe(1);
   expect(workerCalls).toBe(4);
   expect(finished.publication_revision).toMatch(/^[a-f0-9]{40,64}$/);
  }else{
   expect(workerCalls).toBe(2);
   expect(finished.publication_revision).toBeNull();
  }
  await native.request('background',{action:'stop'});await second.exited;
 }finally{await native.request('background',{action:'stop'}).catch(()=>{});}
},180000);

test('interrupted execution resumes automatically without a completion candidate or duplicate effect', async()=>{
 const f=fixture(); const receipt=join(f.cwd,'external-receipts.txt'); let workerCalls=0; let interrupted=false;
 const call=(id:string,command:string)=>({tool_calls:[{index:0,id,type:'function',function:{name:'shell',arguments:JSON.stringify({action:'run',profile:'clean',command})}}]});
 model(f,async(body,_count,signal)=>{
  const system=body.messages.filter((m:any)=>m.role==='system').map((m:any)=>m.content).join('\n');
  if(!system.includes('<omos_background_assignment'))return {tool_calls:[{index:0,id:'dispatch-once',type:'function',function:{name:'fossil_workspace',arguments:'{"action":"dispatch"}'}}]};
  workerCalls++;
  if(workerCalls===1)return call('perform-once',`printf 'receipt-1\\n' >> '${receipt}'`);
  if(workerCalls===2||workerCalls===3){interrupted=true;return new Response('data: '+JSON.stringify({choices:[{index:0,delta:{content:'Checking retained work'},finish_reason:null}]})+'\n\n',{headers:{'content-type':'text/event-stream'}});}
  expect(system).toContain('Use read-only checks to reconcile');
  if(workerCalls===4)return call('inspect-existing-receipt',`cat '${receipt}'`);
  return {content:'The external action completed once; receipt-1 is retained and verified.'};
 });
 expect((await f.run(['fossil','init','--json'])).code).toBe(0);
 const native=host(f);
 const until=async(read:()=>Promise<any>,predicate:(value:any)=>boolean)=>{const deadline=Date.now()+90000;let v:any;do{v=await read();if(predicate(v))return v;await Bun.sleep(100)}while(Date.now()<deadline);throw Error(JSON.stringify(v)+native.stderr)};
 const start=()=>{const child=Bun.spawn([resolve(import.meta.dir,'../../zig-out/bin/fx'),'ui-host','--background-serve'],{cwd:f.cwd,env:{...process.env,...f.env},stdout:'pipe',stderr:'pipe'});services.push(child);return child};
 const first=start();
 try{
  await until(()=>native.request('background',{action:'host'}),v=>v.running);
  const end=terminal(native,'recover-background');
  await native.request('coordinate',{text:'Perform the external action once and retain its receipt.'},{id:'recover-background'});
  expect((await end).data.exit_code).toBe(0);
  await until(async()=>interrupted,v=>v);
  expect(readFileSync(receipt,'utf8')).toBe('receipt-1\n');
  const original=(await native.request('background')).workers[0].record;

  const finished=await until(()=>native.request('background',{action:'show',task:original.task}),v=>v.state==='completed'&&v.activity?.recent_events.some((event:any)=>event.type==='background_outcome'));
  // Each partially emitted stream ends its invocation; both faults recover.
  expect(finished.generation).toBe(3);expect(finished.recoveries).toBe(2);
  expect(finished.worker_session).toBe(original.worker_session);
  expect(readFileSync(receipt,'utf8')).toBe('receipt-1\n');
  expect(workerCalls).toBe(5);
  expect(finished.activity.journal_available).toBe(true);
  expect(finished.activity.offset_unit).toBe('bytes');
  expect(finished.activity.recent_events.some((event:any)=>event.timestamp_ms>0)).toBe(true);
  const page=await native.request('background',{action:'events',task:original.task,offset:1});
  expect(page.requested_offset).toBe(1);
  expect(page.aligned_offset).toBeGreaterThan(1);
  expect(page.events[0].cursor).toBe(2);
  expect(page.next_offset).toBeGreaterThan(page.aligned_offset);
  const journalEnd=await native.request('background',{action:'events',task:original.task,offset:finished.activity.next_offset});
  expect(journalEnd.events).toEqual([]);
  expect(journalEnd.next_offset).toBe(finished.activity.next_offset);
  expect(finished.publication_revision).toMatch(/^[a-f0-9]{40,64}$/);
  await native.request('background',{action:'stop'});await first.exited;
 }finally{await native.request('background',{action:'stop'}).catch(()=>{});}
},180000);

test('native owner settings persist validated defaults and expose MCP inventory', async()=>{
 const f=fixture();model(f,()=>({content:'Hello.'}));
 expect((await f.run(['fossil','init','--json'])).code).toBe(0);
 const native=host(f);
 const before=await native.request('settings');
 expect(before.settings.length).toBe(14);
 await expect(native.request('settings',{action:'set',key:'credentials',value:'forbidden'})).rejects.toThrow('UnknownSetting');
 await expect(native.request('settings',{action:'set',key:'fast_mode',value:'invalid'})).rejects.toThrow('InvalidSettingValue');
 await native.request('settings',{action:'set',key:'session_titles',value:'off'});
 await native.request('settings',{action:'set',key:'review_model',value:'fixture-reviewer'});
 const after=await native.request('settings');
 expect(after.settings.find((row:any)=>row.key==='session_titles').value).toBe('off');
 expect(after.review_model).toBe('fixture-reviewer');
 expect(JSON.parse(readFileSync(join(f.home,'.fx','settings.json'),'utf8')).review_model).toBe('fixture-reviewer');
 const inventory=await native.request('snapshot',{action:'mcp'});
 expect(inventory.servers).toBeArray();
 expect(native.stderr).toBe('');
},90000);


test('channel commands survive a host restart and dispatch once through governed execution',async()=>{
 const f=fixture();const provider=model(f,(body)=>{expect(body.messages.some((message:any)=>typeof message.content==='string'&&message.content.includes('Retained channel context data follows'))).toBe(true);return {content:'Hello from the retained contract queue.'}});
 expect((await f.run(['fossil','init'])).code).toBe(0);
 const first=host(f);
 const received=await first.request('contracts',{action:'receive',destination:{channel:'cli',address:'owner'},message_id:'one',text:'Say hello from the shared workspace'});
 const command=await first.request('contracts',{action:'command',key:received.key,choice:'new'});
 expect(command.command.state).toBe('queued');
 await first.close();clients.splice(clients.indexOf(first),1);
 const second=host(f);
 const retained=await second.request('contracts',{action:'commands'});
 expect(retained.items[0].key).toBe(command.key);
 const observed:any[]=[];second.on('event',(event:any)=>observed.push(event));
 const roots=readdirSync(join(f.home,'.fx','fossil'));
 const activation=roots.map(root=>join(f.home,'.fx','fossil',root,'channel-activations',command.key)).find(existsSync)!;
 expect(activation).toBeString();unlinkSync(activation);
 const inactive=await second.request('channel.dispatch',{key:command.key});
 expect(inactive.state).toBe('blocked');expect(inactive.reason).toBe('ChannelActivationRequired');expect(provider.counts().actors).toBe(0);
 const activated=await second.request('contracts',{action:'command',key:received.key,choice:'new'});
 expect(activated.command.state).toBe('queued');
 const ending=terminal(second,command.key);
 const dispatched=await second.request('channel.dispatch',{key:command.key});
 expect(dispatched.state).toBe('accepted');
 const ended=await ending;if(ended.data.exit_code)console.error(JSON.stringify(observed),second.stderr);expect(ended.data.exit_code).toBe(0);
 const calls=provider.counts().actors;
 const replay=await second.request('channel.dispatch',{key:command.key});
 expect(replay.state).toBe('accepted');expect(provider.counts().actors).toBe(calls);
 const commands=await second.request('contracts',{action:'commands'});
 const task=commands.items[0].record.task;expect(task).toBeString();
 const followup=await second.request('contracts',{action:'receive',destination:{channel:'telegram',address:'owner'},message_id:'two',text:'How did it go?',reply_to:received.key});
 expect(followup.resolution.task).toBe(task);
 expect(followup.resolution.status.published).toBe(true);
 expect(second.stderr).toBe('');
},180000);
