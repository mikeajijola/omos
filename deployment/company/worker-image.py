#!/usr/bin/python3 -I
"""Prepare disposable worker roots from an operator-verified runtime template.

Run only as the operator. Request data selects identities, never host source
paths, executable commands, credentials, or namespace policy.
"""
import fcntl
import hashlib
import json
import os
import pathlib
import re
import shutil
import signal
import time
import stat
import sys


class Rejected(Exception):
    pass


def require(value, code):
    if not value:
        raise Rejected(code)


def identity(value):
    return isinstance(value, str) and re.fullmatch(r"[0-9a-f]{64}", value) is not None


def directory(path):
    require(isinstance(path, str) and path.startswith("/") and "\0" not in path, "InvalidImagePath")
    parts = path.split("/")[1:]
    require(all(part and part not in (".", "..") for part in parts), "InvalidImagePath")
    fd = os.open("/", os.O_RDONLY | os.O_DIRECTORY)
    try:
        for part in parts:
            next_fd = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            info = os.fstat(next_fd)
            require(info.st_uid == 0 and (info.st_mode & 0o022 == 0 or bool(info.st_mode & stat.S_ISVTX)), "UnsafeImageAncestor")
            os.close(fd)
            fd = next_fd
        return fd
    except BaseException:
        os.close(fd)
        raise


def trusted_json(path, limit):
    parent, name = os.path.split(path)
    root = directory(parent)
    try:
        fd = os.open(name, os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=root)
        with os.fdopen(fd, "rb") as stream:
            info = os.fstat(stream.fileno())
            require(stat.S_ISREG(info.st_mode) and info.st_uid == 0 and stat.S_IMODE(info.st_mode) == 0o600 and info.st_nlink == 1 and info.st_size <= limit, "UnsafeImageConfiguration")
            raw = stream.read(limit + 1)
            require(len(raw) <= limit, "ImageConfigurationTooLarge")
            return json.loads(raw), hashlib.sha256(raw).hexdigest()
    finally:
        os.close(root)


def file_at(root, relative):
    require(isinstance(relative, str) and len(relative) <= 4096 and all(part and part not in (".", "..") for part in relative.split("/")) and not relative.startswith("/") and "\\" not in relative and not any(ord(c) < 32 for c in relative), "InvalidImageFile")
    current = os.dup(root)
    try:
        parts = relative.split("/")
        for part in parts[:-1]:
            next_fd = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=current)
            info = os.fstat(next_fd)
            require(info.st_uid == 0 and info.st_mode & 0o022 == 0, "UnsafeImageTemplate")
            os.close(current)
            current = next_fd
        return os.open(parts[-1], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=current)
    finally:
        os.close(current)


def copy_template(config, destination):
    manifest, digest = trusted_json(config["template_manifest"], 4 * 1024 * 1024)
    require(digest == config["template_manifest_sha256"] and isinstance(manifest, dict) and set(manifest) == {"version", "files"} and manifest["version"] == "omos.worker-template/v1", "InvalidImageTemplateManifest")
    files = manifest["files"]
    require(isinstance(files, list) and 1 <= len(files) <= 10000, "ImageTemplateFileBudget")
    template = directory(config["template"])
    total = 0
    seen = set()
    try:
        info = os.fstat(template)
        require(info.st_uid == 0 and info.st_mode & 0o022 == 0, "UnsafeImageTemplate")
        for item in files:
            require(isinstance(item, dict) and set(item) == {"path", "sha256", "bytes", "executable"}, "InvalidImageTemplateManifest")
            relative = item["path"]
            require(isinstance(relative, str) and relative.split("/")[0] in ("runtime", "bin", "lib", "lib64", "usr") and relative not in seen and identity(item["sha256"]) and type(item["bytes"]) is int and 0 <= item["bytes"] <= 512 * 1024 * 1024 and type(item["executable"]) is bool, "InvalidImageTemplateManifest")
            seen.add(relative)
            total += item["bytes"]
            require(total <= 2 * 1024 * 1024 * 1024, "ImageTemplateByteBudget")
            fd = file_at(template, relative)
            with os.fdopen(fd, "rb") as source:
                before = os.fstat(source.fileno())
                require(stat.S_ISREG(before.st_mode) and before.st_uid == 0 and before.st_mode & 0o6022 == 0 and before.st_size == item["bytes"] and bool(before.st_mode & 0o111) == item["executable"], "UnsafeImageTemplateFile")
                target = destination / relative
                target.parent.mkdir(parents=True, exist_ok=True, mode=0o755)
                parent = target.parent
                while parent != destination:
                    parent.chmod(0o755)
                    parent = parent.parent
                digest = hashlib.sha256()
                count = 0
                with target.open("xb") as output:
                    while chunk := source.read(65536):
                        count += len(chunk)
                        require(count <= item["bytes"], "ImageTemplateChanged")
                        digest.update(chunk)
                        output.write(chunk)
                after = os.fstat(source.fileno())
                require((before.st_dev, before.st_ino, before.st_size, before.st_mtime_ns, before.st_ctime_ns) == (after.st_dev, after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns) and count == item["bytes"] and digest.hexdigest() == item["sha256"], "ImageTemplateChanged")
                target.chmod(0o755 if item["executable"] else 0o644)
    finally:
        os.close(template)
    require("runtime/bin/omos" in seen and "runtime/bin/fossil" in seen and "bin/sh" in seen, "ImageRuntimeMissing")
    with (destination / "runtime/bin/omos").open("rb") as source:
        require(hashlib.file_digest(source, "sha256").hexdigest() == config["executable_sha256"], "ImageExecutableChanged")


def main():
    require(os.geteuid() == 0 and len(sys.argv) == 2, "ImageOperatorRequired")
    os.umask(0o077)
    config, configuration_hash = trusted_json(sys.argv[1], 8192)
    expected = {"version", "root", "template", "template_manifest", "template_manifest_sha256", "executable_sha256", "service_uid", "service_gid", "max_images", "context_window", "max_output_tokens"}
    require(isinstance(config, dict) and set(config) == expected and config["version"] == "omos.worker-images/v1" and identity(config["template_manifest_sha256"]) and identity(config["executable_sha256"]), "InvalidImageConfiguration")
    require(all(type(config[key]) is int and 0 <= config[key] < 100000 for key in ("service_uid", "service_gid")) and type(config["max_images"]) is int and 1 <= config["max_images"] <= 32, "InvalidImageConfiguration")
    require(type(config["context_window"]) is int and 1024 <= config["context_window"] <= 2000000 and type(config["max_output_tokens"]) is int and 1 <= config["max_output_tokens"] < config["context_window"], "InvalidImageModelLimits")
    require(isinstance(config["root"], str) and len(os.fsencode(config["root"])) + 46 <= 100, "ImageSocketPathTooLong")
    root_fd = directory(config["root"])
    try:
        info = os.fstat(root_fd)
        require(info.st_uid == 0 and info.st_gid == config["service_gid"] and stat.S_IMODE(info.st_mode) == 0o710, "UnsafeImagePool")
        lock = os.open(".lock", os.O_CREAT | os.O_RDWR | os.O_NOFOLLOW, 0o600, dir_fd=root_fd)
        try:
            require(os.fstat(lock).st_uid == 0 and stat.S_IMODE(os.fstat(lock).st_mode) == 0o600, "UnsafeImageLock")
            fcntl.flock(lock, fcntl.LOCK_EX)
            raw = sys.stdin.buffer.read(65537)
            require(len(raw) <= 65536, "ImageRequestTooLarge")
            request = json.loads(raw)
            require(isinstance(request, dict) and set(request) == {"version", "action", "id", "workspace", "view", "generation", "max_runtime_ms", "model"} and request["version"] == "omos.worker-image-request/v1" and request["action"] in ("prepare", "inspect", "remove", "quiesce") and all(identity(request[key]) for key in ("id", "workspace", "view")) and type(request["generation"]) is int and request["generation"] > 0 and type(request["max_runtime_ms"]) is int and 1000 <= request["max_runtime_ms"] <= 240000 and isinstance(request["model"], str) and re.fullmatch(r"[A-Za-z0-9_.:/-]{1,128}", request["model"]), "InvalidImageRequest")
            root = pathlib.Path(config["root"])
            target = root / request["id"][:24]
            uid = 100000 + int(request["id"][:12], 16) % 15900001
            descriptor = {"version": "omos.worker-root/v1", "uid": uid, "workspace": request["workspace"], "view": request["view"], "generation": request["generation"], "max_runtime_ms": request["max_runtime_ms"], "executable": "/runtime/bin/omos", "executable_sha256": config["executable_sha256"]}
            image_identity = {"request": {key: value for key, value in request.items() if key != "action"}, "configuration_sha256": configuration_hash}
            if target.exists() or target.is_symlink():
                image_metadata, _ = trusted_json(str(target / ".omos-worker-image.json"), 8192)
                require(image_metadata == image_identity, "ImageIdentityChanged")
                current, _ = trusted_json(str(target / ".omos-worker-root.json"), 8192)
                require(current == descriptor, "ImageIdentityChanged")
                if request["action"] == "quiesce":
                    require(hasattr(os, "pidfd_open") and hasattr(signal, "pidfd_send_signal"), "ImageKernelUnsupported")
                    for _ in range(250):
                        active = False
                        for entry in pathlib.Path("/proc").iterdir():
                            if not entry.name.isdecimal():
                                continue
                            fd = None
                            try:
                                fd = os.pidfd_open(int(entry.name))
                                text = (entry / "status").read_bytes()
                                match = re.search(rb"^Uid:\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s*$", text, re.MULTILINE)
                                if match and uid in map(int, match.groups()):
                                    active = True
                                    signal.pidfd_send_signal(fd, signal.SIGKILL)
                            except (FileNotFoundError, ProcessLookupError):
                                pass
                            finally:
                                if fd is not None:
                                    os.close(fd)
                        if not active:
                            return {"quiescent": True, "id": request["id"]}
                        time.sleep(0.02)
                    raise Rejected("ImageCleanupPending")
                if request["action"] == "remove":
                    # Refuse deletion while any process retains this worker UID.
                    for entry in pathlib.Path("/proc").iterdir():
                        if not entry.name.isdecimal():
                            continue
                        try:
                            text = (entry / "status").read_bytes()
                        except (FileNotFoundError, ProcessLookupError):
                            continue
                        match = re.search(rb"^Uid:\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s*$", text, re.MULTILINE)
                        require(not match or uid not in map(int, match.groups()), "ImageExecutionActive")
                    shutil.rmtree(target)
                    return {"removed": True, "id": request["id"]}
                return {"root": str(target), **descriptor}
            require(request["action"] == "prepare", "ImageNotFound")
            names = os.listdir(root_fd)
            existing = [name for name in names if re.fullmatch(r"[0-9a-f]{24}", name)]
            pending = [name for name in names if re.fullmatch(r"\.preparing-[0-9a-f]{24}", name)]
            require(len(existing) + len(pending) < config["max_images"], "ImagePoolBudgetExceeded")
            for name in existing:
                other, _ = trusted_json(str(root / name / ".omos-worker-root.json"), 8192)
                require(other["uid"] != uid, "ImageUidCollision")
            staging = root / (".preparing-" + request["id"][:24])
            require(not staging.exists() and not staging.is_symlink(), "ImagePreparationPending")
            staging.mkdir(mode=0o755)
            try:
                copy_template(config, staging)
                for name in ("workspace", "home/worker", "tmp", "run", "dev", "proc", "dev/pts", "etc"):
                    (staging / name).mkdir(parents=True, exist_ok=True, mode=0o755)
                for name in ("workspace", "home/worker", "tmp"):
                    os.chown(staging / name, uid, uid)
                    (staging / name).chmod(0o700)
                os.chown(staging / "run", config["service_uid"], config["service_gid"])
                (staging / "run").chmod(0o711)
                for name, minor in (("null", 3), ("urandom", 9)):
                    os.mknod(staging / "dev" / name, stat.S_IFCHR | 0o666, os.makedev(1, minor))
                    (staging / "dev" / name).chmod(0o666)
                (staging / "etc/passwd").write_text(f"worker:x:{uid}:{uid}:Worker:/home/worker:/bin/sh\n")
                (staging / "etc/group").write_text(f"worker:x:{uid}:\n")
                profile = staging / "home/worker/.fx"
                profile.mkdir(mode=0o700)
                settings = {"provider": "worker", "models": {"worker": request["model"]}, "permission_mode": "full-access", "auto_upgrade": False, "session_titles": False, "providers": {"worker": {"protocol": "openai-chat-completions", "base_url": "http://127.0.0.1/model/v1", "auth": {"type": "none"}, "model_metadata": {request["model"]: {"supports_tool_use": True, "context_window": config["context_window"], "max_output_tokens": config["max_output_tokens"]}}}}}
                mcp = {"mcp": {"company": {"type": "http", "url": "http://127.0.0.1:1/company/mcp", "required": True, "startup_timeout_ms": 5000, "operation_timeout_ms": 30000}}}
                for name, value in (("settings.json", settings), ("mcp.json", mcp)):
                    (profile / name).write_text(json.dumps(value))
                    os.chown(profile / name, uid, uid)
                os.chown(profile, uid, uid)
                marker = staging / ".omos-worker-root.json"
                marker.write_text(json.dumps(descriptor))
                marker.chmod(0o600)
                (staging / ".omos-worker-image.json").write_text(json.dumps(image_identity))
                for path in ("etc", "home", "dev", "dev/pts", "proc"):
                    (staging / path).chmod(0o755)
                for path in ("etc/passwd", "etc/group"):
                    (staging / path).chmod(0o644)
                staging.chmod(0o755)
                os.rename(staging, target)
            except BaseException:
                shutil.rmtree(staging)
                raise
            return {"root": str(target), **descriptor}
        finally:
            os.close(lock)
    finally:
        os.close(root_fd)


if __name__ == "__main__":
    try:
        print(json.dumps(main()))
    except BaseException as error:
        code = str(error) if isinstance(error, Rejected) else "ImageOperationFailed"
        sys.stderr.write(code + "\n")
        sys.exit(125)
