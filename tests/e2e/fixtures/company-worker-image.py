"""Operator fixture for the production image preparer; never an installed API."""
import hashlib
import json
import os
import pathlib
import re
import shutil
import stat
import subprocess
import sys
import tempfile

spec = json.load(sys.stdin)
repository = pathlib.Path(__file__).resolve().parents[3]
helper = repository / "deployment/company/worker-image.py"
launcher = repository / "deployment/company/worker-launcher.py"
if spec["action"] == "setup":
    assert type(spec["owner"]) is int and type(spec["group"]) is int
    base = pathlib.Path(tempfile.mkdtemp(prefix="omos-worker-image-test-"))
    template = base / "template"
    template.mkdir()
    pool = base / "pool"
    pool.mkdir()
    os.chown(pool, 0, spec["group"])
    pool.chmod(0o710)
    files = {}
    def binary(source, target):
        source = pathlib.Path(source).resolve()
        destination = template / target.lstrip("/")
        if destination.exists():
            return
        destination.parent.mkdir(parents=True, exist_ok=True)
        shutil.copyfile(source, destination)
        destination.chmod(0o755)
        files[str(destination.relative_to(template))] = {"path": str(destination.relative_to(template)), "bytes": destination.stat().st_size, "sha256": hashlib.file_digest(destination.open("rb"), "sha256").hexdigest(), "executable": True}
        result = subprocess.run(["/usr/bin/ldd", str(source)], capture_output=True, text=True)
        for item in re.findall(r"(?<!\S)(/[^\s()]+)", result.stdout):
            binary(item, item)
    binary(repository / "zig-out/bin/fx", "/runtime/bin/omos")
    packaged = repository / "zig-out/libexec/fossil"
    binary(packaged if packaged.exists() else shutil.which("fossil"), "/runtime/bin/fossil")
    binary("/bin/sh", "/bin/sh")
    binary("/bin/bash", "/bin/bash")
    binary("/usr/bin/env", "/usr/bin/env")
    binary("/bin/rm", "/bin/rm")
    if spec.get("validation"):
        binary(sys.executable, "/runtime/bin/python3")
        stdlib = pathlib.Path(sys.base_prefix) / "lib" / ("python" + ".".join(map(str, sys.version_info[:2])))
        for source in stdlib.rglob("*"):
            if not source.is_file() or any(part in ("__pycache__", "site-packages", "dist-packages", "test", "tests") for part in source.relative_to(stdlib).parts):
                continue
            target = template / str(source).lstrip("/")
            target.parent.mkdir(parents=True, exist_ok=True)
            shutil.copyfile(source, target)
            target.chmod(0o644)
            files[str(target.relative_to(template))] = {"path": str(target.relative_to(template)), "bytes": target.stat().st_size, "sha256": hashlib.file_digest(target.open("rb"), "sha256").hexdigest(), "executable": False}
        for module in (stdlib / "lib-dynload").glob("*.so"):
            result = subprocess.run(["/usr/bin/ldd", str(module)], capture_output=True, text=True)
            for dependency in re.findall(r"(?<!\S)(/[^\s()]+)", result.stdout):
                binary(dependency, dependency)
    manifest = base / "template.json"
    manifest.write_text(json.dumps({"version": "omos.worker-template/v1", "files": list(files.values())}))
    manifest.chmod(0o600)
    configuration = {"version": "omos.worker-images/v1", "root": str(pool), "template": str(template), "template_manifest": str(manifest), "template_manifest_sha256": hashlib.sha256(manifest.read_bytes()).hexdigest(), "executable_sha256": files["runtime/bin/omos"]["sha256"], "service_uid": spec["owner"], "service_gid": spec["group"], "max_images": 2 if spec.get("validation") else 1, "context_window": 262144, "max_output_tokens": 8192}
    (base / "configuration.json").write_text(json.dumps(configuration))
    (base / "configuration.json").chmod(0o600)
    print(json.dumps({"base": str(base)}))
    sys.exit(0)
base = pathlib.Path(spec["base"])
assert base.parent == pathlib.Path("/tmp") and base.name.startswith("omos-worker-image-test-") and not base.is_symlink()
assert base.stat().st_uid == 0 and stat.S_IMODE(base.stat().st_mode) == 0o700
if spec["action"] == "cleanup":
    shutil.rmtree(base)
    sys.exit(0)
if spec["action"] == "backend":
    tools = base / "tools"
    tools.mkdir()
    settings = spec["settings"]
    profile = base / "operator"
    (profile / ".fx/company-keys").mkdir(parents=True)
    key = pathlib.Path(settings["key_file"])
    assert key.name == settings["company"]["key_handle"] + ".seed" and key.parent.name == "company-keys" and key.stat().st_size == 32
    assert any(part.startswith("fx-test-home-") for part in key.parts)
    (profile / ".fx/company-keys" / key.name).write_bytes(key.read_bytes())
    (profile / ".fx/company-keys" / key.name).chmod(0o600)
    company = base / "client.json"
    company.write_text(json.dumps(settings["company"]))
    company.chmod(0o600)
    program = {}
    for name in ("worker-image.py", "worker-launcher.py"):
        selected = tools / name
        shutil.copyfile(repository / "deployment/company" / name, selected)
        selected.chmod(0o600)
        program[name] = {"path": str(selected), "sha256": hashlib.sha256(selected.read_bytes()).hexdigest()}
    backend = {"imageTool": program["worker-image.py"]["path"], "imageToolSha256": program["worker-image.py"]["sha256"], "launcher": program["worker-launcher.py"]["path"], "launcherSha256": program["worker-launcher.py"]["sha256"], "imageConfiguration": str(base / "configuration.json"), "companyConfiguration": str(company), "companyHome": str(profile), "model": settings["model"]}
    if "validation" in settings:
        image_config = json.loads((base / "configuration.json").read_text())
        manifest = json.loads(pathlib.Path(image_config["template_manifest"]).read_text())
        shell = next(item for item in manifest["files"] if item["path"] == "bin/bash")
        validation = {"version": "omos.worker-validation/v1", "handle": "company-default", "entry": {"path": "/bin/bash", "sha256": shell["sha256"]}, "checks": settings["validation"]}
        validation_file = base / "validation.json"
        validation_file.write_text(json.dumps(validation))
        validation_file.chmod(0o600)
        backend["validationConfiguration"] = str(validation_file)
    configuration = base / "backend.json"
    configuration.write_text(json.dumps({"backend": backend, "control": settings["control"], "view": settings["view"]}))
    configuration.chmod(0o600)
    assert pathlib.Path(spec["node"]).is_absolute() and pathlib.Path(spec["node"]).name in ("node", "bun")
    result = subprocess.run([spec["node"], str(repository / "tests/e2e/fixtures/company-worker-linux.mjs"), str(configuration)], capture_output=True, text=True, timeout=360, env={"PATH": "/usr/bin:/bin", "HOME": str(profile)})
    print(json.dumps({"code": result.returncode, "stdout": result.stdout, "stderr": result.stderr, "images": len([name for name in os.listdir(base / "pool") if re.fullmatch(r"[0-9a-f]{24}", name)])}))
    sys.exit(0)
request = spec["request"]
assert re.fullmatch(r"[0-9a-f]{64}", request["id"])
def invoke(value):
    result = subprocess.run([sys.executable, "-I", str(helper), str(base / "configuration.json")], input=json.dumps(value), capture_output=True, text=True, timeout=120)
    return {"code": result.returncode, "stdout": result.stdout, "stderr": result.stderr}
if spec["action"] == "invoke":
    print(json.dumps(invoke(request)))
elif spec["action"] == "template_entry":
    config = json.loads((base / "configuration.json").read_text())
    manifest = json.loads(pathlib.Path(config["template_manifest"]).read_text())
    entry = next(item for item in manifest["files"] if item["path"] == "bin/bash")
    print(json.dumps({"path": "/bin/bash", "sha256": entry["sha256"]}))
elif spec["action"] == "profile":
    root = base / "pool" / request["id"][:24]
    print(json.dumps({"settings": json.loads((root / "home/worker/.fx/settings.json").read_text()), "mcp": json.loads((root / "home/worker/.fx/mcp.json").read_text()), "marker": json.loads((root / ".omos-worker-root.json").read_text()), "directories": {name: stat.S_IMODE((root / name).stat().st_mode) for name in ("runtime", "runtime/bin", "home", "home/worker", "home/worker/.fx", "run", "dev")}, "keys": list((root / "home/worker/.fx").iterdir()).__len__()}))
elif spec["action"] == "active_remove":
    descriptor = json.loads((base / "pool" / request["id"][:24] / ".omos-worker-root.json").read_text())
    child = subprocess.Popen(["/bin/sleep", "30"], user=descriptor["uid"], group=descriptor["uid"], extra_groups=[])
    try:
        print(json.dumps(invoke({**request, "action": "remove"})))
    finally:
        child.kill()
        child.wait()
elif spec["action"] == "quiesce":
    descriptor = json.loads((base / "pool" / request["id"][:24] / ".omos-worker-root.json").read_text())
    child = subprocess.Popen(["/bin/sleep", "30"], user=descriptor["uid"], group=descriptor["uid"], extra_groups=[])
    helper_child = subprocess.Popen([sys.executable, "-I", str(helper), str(base / "configuration.json")], stdin=subprocess.PIPE, stdout=subprocess.PIPE, stderr=subprocess.PIPE, text=True)
    try:
        helper_child.stdin.write(json.dumps({**request, "action": "quiesce"}))
        helper_child.stdin.close()
        child.wait(timeout=10)
        helper_child.wait(timeout=10)
        print(json.dumps({"code": helper_child.returncode, "stdout": helper_child.stdout.read(), "stderr": helper_child.stderr.read(), "child_code": child.returncode}))
    finally:
        if child.poll() is None:
            child.kill()
            child.wait()
        if helper_child.poll() is None:
            helper_child.kill()
            helper_child.wait()
elif spec["action"] == "launch":
    result = subprocess.run([sys.executable, "-I", str(launcher), str(base / "pool" / request["id"][:24]), "--", "fossil", "ensure", "--json"], capture_output=True, text=True, timeout=60)
    print(json.dumps({"code": result.returncode, "stdout": result.stdout, "stderr": result.stderr}))
elif spec["action"] == "corrupt_template":
    (base / "template/bin/sh").write_bytes(b"changed template")
    print(json.dumps(invoke(request)))
else:
    raise ValueError("Unknown image fixture action")
