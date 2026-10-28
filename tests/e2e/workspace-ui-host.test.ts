import {afterEach,expect,test} from 'bun:test';
import {resolve,join} from 'node:path';
import {existsSync,mkdirSync,readFileSync,writeFileSync} from 'node:fs';
import {execFileSync} from 'node:child_process';
import {createHash} from 'node:crypto';
import {NativeClient} from './workspace-ui-client.mjs';
import {cleanupFixtures,fixture,model} from './fossil-workspace-helpers';
const clients:NativeClient[]=[];
const services:ReturnType<typeof Bun.spawn>[]=[];
afterEach(async()=>{for(const client of clients.splice(0))await client.close();for(const service of services.splice(0)){service.kill();await service.exited}cleanupFixtures()});
function host(f:ReturnType<typeof fixture>){const native=new NativeClient({binary:resolve(import.meta.dir,'../../zig-out/bin/fx'),project:f.cwd,env:{...process.env,...f.env}});clients.push(native);return native}
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
 const f = fixture(); let answered = false; let workerCalls = 0; const assignments:string[]=[];
 const pngBase64='iVBORw0KGgoAAAANSUhEUgAAAAEAAAABCAYAAAAfFcSJAAAADUlEQVR42mP8z8BQDwAEhQGAhKmMIQAAAABJRU5ErkJggg==';
 const imagePath=join(f.cwd,'reference.png');writeFileSync(imagePath,Buffer.from(pngBase64,'base64'));
 model(f, (body) => {
  const names = body.tools?.map((tool:any) => tool.function?.name) || [];
  const system = body.messages.filter((m:any)=>m.role==='system').map((m:any)=>m.content).join('\n');
  if (!names.includes('write_file')) {
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
 const native = host(f); const observed:any[] = [];
 native.on('event', (event:any) => observed.push(event));
 const until = async (read:()=>Promise<any>, predicate:(value:any)=>boolean) => {
  const deadline = Date.now()+60000; let value:any;
  do { value = await read(); if(predicate(value)) return value; await Bun.sleep(100); } while(Date.now()<deadline);
  throw Error(`Background state did not converge: ${JSON.stringify(value)}; ${native.stderr}`);
 };
 try {
  const ending = terminal(native,'dispatch-report');
  await native.request('coordinate',{text:'Prepare the report using the attached reference after I choose its presentation.',images:[imagePath]},{id:'dispatch-report'});
  const handoffEnd = await ending;
  if (handoffEnd.data.exit_code) console.error(JSON.stringify(observed), native.stderr);
  expect(handoffEnd.data.exit_code).toBe(0);
  const dispatched = observed.find(e=>e.data.type==='background_dispatch');
  expect(dispatched).toBeDefined();
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
},120000);
