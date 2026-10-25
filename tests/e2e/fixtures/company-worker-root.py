import hashlib,json,os,pathlib,re,shutil,stat,subprocess,sys
import socket

spec=json.load(open(sys.argv[1]))
root=pathlib.Path(spec['root'])
assert root.is_absolute() and root.parent.name.startswith('fx-test-home-') and root.name=='worker-root'
parent=root.parent.stat()
assert parent.st_uid==spec['owner'] and stat.S_IMODE(parent.st_mode)==0o700
if spec.get('action') in ('entry','namespaces'):
 marker=root/'.omos-worker-root.json';value=json.load(open(marker))
 assert value['version']=='omos.worker-root/v1' and value['uid']==spec['uid']
 if spec['action']=='entry':
  assert spec['entry'] in ['/runtime/bin/python3','/runtime/bin/omos']
  value['executable']=spec['entry']
  with (root/spec['entry'].lstrip('/')).open('rb') as stream:value['executable_sha256']=hashlib.file_digest(stream,'sha256').hexdigest()
 else:value['namespaces']=spec['namespaces']
 marker.write_text(json.dumps(value));marker.chmod(0o600)
 sys.exit(0)
if spec.get('action')=='probe':
 launcher=pathlib.Path(__file__).resolve().parents[3]/'deployment/company/worker-launcher.py'
 marker=json.load(open(root/'.omos-worker-root.json'))
 assert marker['version']=='omos.worker-root/v1' and marker['uid']==spec['uid']
 sentinel=root.parent/'host-sentinel';sentinel.write_text('host-only-fixture');sentinel.chmod(0o600)
 (root/'workspace/authorized.txt').write_text('authorized input')
 os.chown(root/'workspace/authorized.txt',spec['uid'],spec['uid'])
 address='omos-worker-fixture-'+str(os.getpid())
 listener=socket.socket(socket.AF_UNIX,socket.SOCK_STREAM);listener.bind('\0'+address);listener.listen(1);listener.settimeout(.05)
 extra=os.open(sentinel,os.O_RDONLY);identity=os.fstat(extra)
 script='''import os,socket,json,time,ctypes
r={'uid':os.getuid(),'cwd':os.getcwd(),'authorized':open('/workspace/authorized.txt').read(),'private_environment':bool(os.getenv('OMOS_TEST_PRIVATE_TOKEN'))}
class H(ctypes.Structure):_fields_=[('version',ctypes.c_uint32),('pid',ctypes.c_int)]
class D(ctypes.Structure):_fields_=[('effective',ctypes.c_uint32),('permitted',ctypes.c_uint32),('inheritable',ctypes.c_uint32)]
h=H(0x20080522,0);d=(D*2)();ctypes.CDLL(None).capget(ctypes.byref(h),d)
r['capabilities_cleared']=all(x.effective==x.permitted==x.inheritable==0 for x in d)
try:open(HOST);r['host_read']='unexpected-success'
except OSError as e:r['host_read']=e.errno
try:socket.socket(socket.AF_INET,socket.SOCK_STREAM);r['tcp']='unexpected-success'
except OSError as e:r['tcp']=e.errno
try:
 with socket.socket(socket.AF_UNIX,socket.SOCK_STREAM) as s:s.connect('\\0'+ABSTRACT);r['abstract']='unexpected-success'
except OSError as e:r['abstract']=e.errno
try:os.setuid(0);r['root_restore']='unexpected-success'
except OSError as e:r['root_restore']=e.errno
try:
 st=os.fstat(EXTRA);r['inherited_host_file']=(st.st_dev,st.st_ino)==IDENTITY
except OSError:r['inherited_host_file']=False
pid=os.fork()
if pid==0:os.setsid();time.sleep(60);os._exit(0)
r['descendant']=pid
print(json.dumps(r))
'''.replace('HOST',repr(str(sentinel))).replace('ABSTRACT',repr(address)).replace('EXTRA',repr(extra)).replace('IDENTITY',repr((identity.st_dev,identity.st_ino)))
 environment=dict(os.environ,OMOS_TEST_PRIVATE_TOKEN='host-only-fixture')
 result=subprocess.run([sys.executable,'-I',str(launcher),str(root),'--','-I','-c',script],capture_output=True,text=True,env=environment,pass_fds=(extra,),timeout=20)
 os.close(extra)
 connected=False
 try:listener.accept();connected=True
 except TimeoutError:pass
 listener.close()
 print(json.dumps({'code':result.returncode,'stdout':result.stdout,'stderr':result.stderr,'abstract_connected':connected}))
 sys.exit(0)
if spec.get('action')=='remove':
 assert not root.is_symlink()
 if root.exists():
  marker=json.load(open(root/'.omos-worker-root.json'))
  assert marker['version']=='omos.worker-root/v1' and marker['uid']==spec['uid']
  shutil.rmtree(root)
 sys.exit(0)
assert not root.exists()
root.mkdir(mode=0o755)
copied=set()
def binary(source,target=None):
 source=pathlib.Path(source)
 destination=root/str(target or source).lstrip('/')
 if str(destination) in copied:return
 copied.add(str(destination));destination.parent.mkdir(parents=True,exist_ok=True)
 shutil.copyfile(source.resolve(),destination)
 destination.chmod(0o755)
 result=subprocess.run(['ldd',str(source.resolve())],stdout=subprocess.PIPE,stderr=subprocess.PIPE,text=True,check=False)
 for path in re.findall(r'(?<!\S)(/[^\s()]+)',result.stdout):
  p=pathlib.Path(path)
  dst=root/path.lstrip('/')
  if not dst.exists():dst.parent.mkdir(parents=True,exist_ok=True);shutil.copyfile(p.resolve(),dst);dst.chmod(0o755)
binary(spec['executable'],'/runtime/bin/omos')
binary(spec['fossil'],'/runtime/bin/fossil')
binary('/bin/sh','/bin/sh')
python=sys.executable
binary(python,'/runtime/bin/python3')
stdlib=pathlib.Path(sys.base_prefix)/'lib'/('python'+'.'.join(map(str,sys.version_info[:2])))
destination=root/str(stdlib).lstrip('/')
shutil.copytree(stdlib,destination,ignore=shutil.ignore_patterns('__pycache__','site-packages','dist-packages','test','tests'))
for module in (stdlib/'lib-dynload').glob('*.so'):binary(module)
for relative in ['workspace','home/worker','tmp','run','dev']:(root/relative).mkdir(parents=True,exist_ok=True)
(root/'etc').mkdir(exist_ok=True)
(root/'etc/passwd').write_text(f'worker:x:{spec["uid"]}:{spec["uid"]}:Isolated worker:/home/worker:/bin/sh\n')
(root/'etc/group').write_text(f'worker:x:{spec["uid"]}:\n')
if spec.get('profile'):shutil.copytree(spec['profile'],root/'home/worker/.fx')
os.mknod(root/'dev/null',stat.S_IFCHR|0o666,os.makedev(1,3))
os.mknod(root/'dev/urandom',stat.S_IFCHR|0o666,os.makedev(1,9))
(root/'dev/null').chmod(0o666)
(root/'dev/urandom').chmod(0o666)
for path in root.rglob('*'):
 if path.is_file():path.chmod(path.stat().st_mode&0o777&~0o022)
 if path.is_dir():path.chmod(0o755)
 os.chown(path,0,0)
for relative in ['workspace','home/worker','tmp']:
 folder=root/relative
 for folder_root,dirs,files in os.walk(folder):
  for name in dirs+files:os.chown(pathlib.Path(folder_root)/name,spec['uid'],spec['uid'])
  os.chown(folder_root,spec['uid'],spec['uid']);os.chmod(folder_root,0o700)
os.chown(root/'run',int(spec['owner']),int(spec['owner']));os.chmod(root/'run',0o711)
executable=spec.get('entry','/runtime/bin/omos')
with (root/executable.lstrip('/')).open('rb') as stream:digest=hashlib.file_digest(stream,'sha256').hexdigest()
marker={'version':'omos.worker-root/v1','uid':spec['uid'],'workspace':'0'*64,'view':'1'*64,'generation':1,'max_runtime_ms':120000,'namespaces':spec.get('namespaces',True),'executable':executable,'executable_sha256':digest}
path=root/'.omos-worker-root.json';path.write_text(json.dumps(marker));path.chmod(0o600)
print(json.dumps({'root':str(root),'uid':spec['uid']}))
