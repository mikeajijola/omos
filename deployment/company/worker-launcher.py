#!/usr/bin/python3 -I
"""Operator-only Linux worker launcher. Run with an isolated Python interpreter.

The trusted coordinator prepares a root-owned image containing only authorized
content and runtimes. This launcher never stages files or executes code as root.
It is not installed setuid and does not enroll or grant company authority.
"""
import ctypes
import errno
import fcntl
import hashlib
import json
import os
import platform
import re
import resource
import select
import signal
import socket
import stat
import sys
import time


class Rejected(Exception):
    pass


def require(condition, code):
    if not condition:
        raise Rejected(code)


def directory(path):
    require(path.startswith("/") and "\0" not in path, "InvalidWorkerRoot")
    parts = path.split("/")[1:]
    require(parts and all(part and part not in (".", "..") for part in parts), "InvalidWorkerRoot")
    fd = os.open("/", os.O_RDONLY | os.O_DIRECTORY)
    try:
        for part in parts:
            next_fd = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=fd)
            os.close(fd)
            fd = next_fd
        return fd
    except BaseException:
        os.close(fd)
        raise


def configuration(root):
    info = os.fstat(root)
    require(info.st_uid == 0 and info.st_mode & 0o022 == 0, "UnsafeWorkerRoot")
    fd = os.open(".omos-worker-root.json", os.O_RDONLY | os.O_NOFOLLOW, dir_fd=root)
    with os.fdopen(fd, "rb") as stream:
        info = os.fstat(stream.fileno())
        require(stat.S_ISREG(info.st_mode) and info.st_uid == 0 and info.st_nlink == 1 and stat.S_IMODE(info.st_mode) == 0o600 and info.st_size <= 8192, "UnsafeWorkerDescriptor")
        value = json.load(stream)
    expected = {"version", "uid", "workspace", "view", "generation", "max_runtime_ms", "executable", "executable_sha256"}
    require(type(value) is dict and expected <= set(value) <= expected | {"namespaces"} and value["version"] == "omos.worker-root/v1", "InvalidWorkerDescriptor")
    require(type(value.get("namespaces", True)) is bool, "InvalidWorkerDescriptor")
    require(type(value["uid"]) is int and 100000 <= value["uid"] <= 16000000, "InvalidWorkerUid")
    require(type(value["generation"]) is int and value["generation"] > 0 and type(value["max_runtime_ms"]) is int and 1 <= value["max_runtime_ms"] <= 3600000, "InvalidWorkerBudget")
    require(all(type(value[key]) is str and re.fullmatch(r"[0-9a-f]{64}", value[key]) for key in ("workspace", "view", "executable_sha256")), "InvalidWorkerIdentity")
    executable = value["executable"]
    require(type(executable) is str and executable.startswith("/") and all(part and part not in (".", "..") for part in executable.split("/")[1:]), "InvalidWorkerExecutable")
    current = os.dup(root)
    try:
        parts = executable.split("/")[1:]
        for part in parts[:-1]:
            next_fd = os.open(part, os.O_RDONLY | os.O_DIRECTORY | os.O_NOFOLLOW, dir_fd=current)
            info = os.fstat(next_fd)
            require(info.st_uid == 0 and info.st_mode & 0o022 == 0, "UnsafeWorkerExecutable")
            os.close(current)
            current = next_fd
        fd = os.open(parts[-1], os.O_RDONLY | os.O_NOFOLLOW | os.O_NONBLOCK, dir_fd=current)
        with os.fdopen(fd, "rb") as stream:
            before = os.fstat(stream.fileno())
            require(stat.S_ISREG(before.st_mode) and before.st_uid == 0 and before.st_mode & 0o022 == 0 and before.st_mode & 0o111 and 0 < before.st_size <= 512 * 1024 * 1024, "UnsafeWorkerExecutable")
            digest = hashlib.file_digest(stream, "sha256").hexdigest()
            after = os.fstat(stream.fileno())
            require((before.st_ino, before.st_size, before.st_mtime_ns, before.st_ctime_ns) == (after.st_ino, after.st_size, after.st_mtime_ns, after.st_ctime_ns) and digest == value["executable_sha256"], "WorkerExecutableChanged")
    finally:
        os.close(current)
    return value


LIBC = ctypes.CDLL(None, use_errno=True)
LIBC.syscall.restype = ctypes.c_long
if sys.platform == "linux":
    LIBC.mount.argtypes = [ctypes.c_char_p, ctypes.c_char_p, ctypes.c_char_p, ctypes.c_ulong, ctypes.c_void_p]
NAMESPACES = 0x6C020000  # mount, UTS, IPC, PID, and network namespaces


def probe():
    abi = -1
    if sys.platform == "linux":
        abi = LIBC.syscall(444, 0, 0, 1)
    supported = sys.platform == "linux" and platform.machine() in ("x86_64", "aarch64") and abi >= 3 and hasattr(os, "pidfd_open") and hasattr(signal, "pidfd_send_signal")
    namespaces = False
    if supported and os.geteuid() == 0:
        pid = os.fork()
        if pid == 0:
            os._exit(0 if LIBC.unshare(NAMESPACES) == 0 else 1)
        namespaces = os.waitstatus_to_exitcode(os.waitpid(pid, 0)[1]) == 0
    return {"version": "omos.worker-sandbox-support/v1", "kernel_supported": supported and (namespaces or abi >= 6), "landlock_abi": abi, "operator_privileges": os.geteuid() == 0, "private_namespaces": namespaces}


def checked(result):
    if result < 0:
        raise OSError(ctypes.get_errno(), "WorkerKernelRestrictionFailed")
    return result


def landlock(root, private_namespaces):
    # ABI 6 introduces abstract Unix socket and signal scoping. Chroot alone
    # cannot isolate the host's abstract Unix socket namespace.
    abi = checked(LIBC.syscall(444, 0, 0, 1))
    require(abi >= 3 and (private_namespaces or abi >= 6), "WorkerKernelUnsupported")
    class Ruleset(ctypes.Structure):
        _fields_ = [("filesystem", ctypes.c_uint64), ("network", ctypes.c_uint64), ("scoped", ctypes.c_uint64)]
    filesystem = (1 << (16 if abi >= 5 else 15)) - 1
    ruleset = Ruleset(filesystem, 0, 3 if abi >= 6 else 0)
    fd = checked(LIBC.syscall(444, ctypes.byref(ruleset), ctypes.sizeof(ruleset), 0))
    try:
        class Beneath(ctypes.Structure):
            _fields_ = [("allowed", ctypes.c_uint64), ("parent", ctypes.c_int)]
        # DAC still protects the immutable image. Landlock additionally keeps
        # an opened directory from becoming an escape if the host moves it.
        rule = Beneath(filesystem & ~((1 << 6) | (1 << 11)), root)
        checked(LIBC.syscall(445, fd, 1, ctypes.byref(rule), 0))
        checked(LIBC.syscall(446, fd, 0))
    finally:
        os.close(fd)


def seccomp():
    machine = platform.machine()
    tables = {
        "x86_64": (0xC000003E, 41, 53, 56, [101, 155, 161, 165, 166, 248, 249, 250, 272, 298, 303, 304, 308, 310, 311, 312, 321]),
        "aarch64": (0xC00000B7, 198, 199, 220, [40, 39, 41, 51, 97, 117, 217, 218, 219, 241, 264, 265, 268, 270, 271, 272, 280]),
    }
    require(machine in tables, "WorkerArchitectureUnsupported")
    architecture, socket, socketpair, clone, denied = tables[machine]
    class Filter(ctypes.Structure):
        _fields_ = [("code", ctypes.c_ushort), ("jt", ctypes.c_ubyte), ("jf", ctypes.c_ubyte), ("k", ctypes.c_uint)]
    class Program(ctypes.Structure):
        _fields_ = [("length", ctypes.c_ushort), ("filters", ctypes.POINTER(Filter))]
    load, equal, bits, ret = 0x20, 0x15, 0x45, 0x06
    deny, allow, kill = 0x50000 | errno.EPERM, 0x7FFF0000, 0x80000000
    instructions = [(load, 0, 0, 4), (equal, 1, 0, architecture), (ret, 0, 0, kill), (load, 0, 0, 0)]
    if machine == "x86_64":
        instructions += [(bits, 0, 1, 0x40000000), (ret, 0, 0, kill)]
    for number in denied + [425, 426, 427, 428, 429, 430, 431, 432, 433, 438, 442]:
        instructions += [(equal, 0, 1, number), (ret, 0, 0, deny)]
    # clone3's pointed-to flags cannot be inspected by classic BPF. Returning
    # ENOSYS permits libc to use clone(), whose namespace flags are checked.
    instructions += [(equal, 0, 1, 435), (ret, 0, 0, 0x50000 | errno.ENOSYS)]
    for number in (socket, socketpair):
        instructions += [(equal, 0, 4, number), (load, 0, 0, 16), (equal, 1, 0, 1), (ret, 0, 0, deny), (ret, 0, 0, allow)]
    instructions += [(equal, 0, 4, clone), (load, 0, 0, 16), (bits, 0, 1, 0x7E028000), (ret, 0, 0, deny), (ret, 0, 0, allow), (ret, 0, 0, allow)]
    array = (Filter * len(instructions))(*(Filter(*entry) for entry in instructions))
    program = Program(len(instructions), array)
    checked(LIBC.prctl(22, 2, ctypes.byref(program), 0, 0))


def owned_processes(uid):
    for name in os.listdir("/proc"):
        if not name.isdecimal():
            continue
        fd = None
        try:
            fd = os.pidfd_open(int(name))
            with open(f"/proc/{name}/status", "rb") as stream:
                matches = re.findall(rb"^Uid:\s+(\d+)\s+(\d+)\s+(\d+)\s+(\d+)\s*$", stream.read(16384), re.MULTILINE)
            if len(matches) == 1 and uid in map(int, matches[0]):
                yield fd
                fd = None
        except (ProcessLookupError, FileNotFoundError):
            pass
        finally:
            if fd is not None:
                os.close(fd)


def child(root, config, arguments, parent, parent_fd=None):
    stage = "root"
    try:
        os.setsid()
        os.fchdir(root)
        os.chroot(".")
        os.chdir("/workspace")
        os.umask(0o077)
        os.setgroups([])
        os.setresgid(config["uid"], config["uid"], config["uid"])
        os.setresuid(config["uid"], config["uid"], config["uid"])
        class CapHeader(ctypes.Structure):
            _fields_ = [("version", ctypes.c_uint32), ("pid", ctypes.c_int)]
        class Capabilities(ctypes.Structure):
            _fields_ = [("effective", ctypes.c_uint32), ("permitted", ctypes.c_uint32), ("inheritable", ctypes.c_uint32)]
        header = CapHeader(0x20080522, 0)
        cleared = (Capabilities * 2)()
        checked(LIBC.capset(ctypes.byref(header), cleared))
        checked(LIBC.prctl(47, 4, 0, 0, 0))  # clear ambient capabilities
        checked(LIBC.prctl(1, signal.SIGKILL, 0, 0, 0))
        if parent_fd is None:
            require(os.getppid() == parent, "WorkerCoordinatorLost")
        else:
            observer = select.poll()
            observer.register(parent_fd, select.POLLIN)
            require(not observer.poll(0), "WorkerCoordinatorLost")
        stage = "limits"
        resource.setrlimit(resource.RLIMIT_CORE, (0, 0))
        resource.setrlimit(resource.RLIMIT_NOFILE, (1024, 1024))
        resource.setrlimit(resource.RLIMIT_NPROC, (64, 64))
        resource.setrlimit(resource.RLIMIT_FSIZE, (512 * 1024 * 1024,) * 2)
        resource.setrlimit(resource.RLIMIT_DATA, (512 * 1024 * 1024,) * 2)
        resource.setrlimit(resource.RLIMIT_CPU, (60, 60))
        checked(LIBC.prctl(38, 1, 0, 0, 0))
        stage = "landlock"
        landlock(root, config.get("namespaces", True))
        stage = "seccomp"
        seccomp()
        os.closerange(3, 1048576)
        environment = {"HOME": "/home/worker", "USER": "worker", "LOGNAME": "worker", "PATH": "/runtime/bin:/usr/bin:/bin", "SHELL": "/bin/bash", "LANG": "C", "LC_ALL": "C", "TERM": "dumb", "FX_SOUND": "0", "FX_CONTRACT_REVIEW": "1", "FX_DISABLE_KEYCHAIN": "1", "FX_SKIP_ONBOARDING": "1", "FX_AUTO_UPGRADE": "0", "OMOS_FOSSIL_BIN": "/runtime/bin/fossil", "OMOS_WORKER_BROKER": "/run/omos-broker.sock", "OMOS_WORKER_PROJECTION": "/runtime/worker-source.json"}
        stage = "exec"
        os.execve(config["executable"], [config["executable"], *arguments], environment)
    except BaseException as error:
        detail = str(error) if isinstance(error, Rejected) else str(getattr(error, "errno", type(error).__name__))
        os.write(2, f"Isolated worker setup failed at {stage}: {detail}.\n".encode())
        os._exit(125)


def namespace_child(root, root_path, config, arguments, parent):
    try:
        checked(LIBC.prctl(1, signal.SIGKILL, 0, 0, 0))
        require(os.getppid() == parent, "WorkerCoordinatorLost")
        checked(LIBC.unshare(NAMESPACES))
        checked(LIBC.mount(None, b"/", None, 16384 | 262144, None))  # recursive private propagation
        # Existing descriptors still name the parent's mounts after unshare.
        # Reopen the same inode through this namespace before mounting procfs.
        selected = directory(root_path)
        before, after = os.fstat(root), os.fstat(selected)
        require((before.st_dev, before.st_ino) == (after.st_dev, after.st_ino), "WorkerRootChanged")
        os.close(root)
        root = selected
        parent_fd = os.pidfd_open(os.getpid())
        pid = os.fork()
        if pid == 0:
            checked(LIBC.prctl(1, signal.SIGKILL, 0, 0, 0))
            observer = select.poll()
            observer.register(parent_fd, select.POLLIN)
            require(not observer.poll(0), "WorkerCoordinatorLost")
            os.fchdir(root)
            for path in ("proc", "dev/pts"):
                os.makedirs(path, mode=0o755, exist_ok=True)
            checked(LIBC.mount(b"proc", b"proc", b"proc", 2 | 4 | 8, None))
            options = f"newinstance,ptmxmode=0666,mode=0600,gid={config['uid']}".encode()
            checked(LIBC.mount(b"devpts", b"dev/pts", b"devpts", 2 | 8, options))
            try:
                os.symlink("pts/ptmx", "dev/ptmx")
            except FileExistsError:
                require(os.readlink("dev/ptmx") == "pts/ptmx", "UnsafeWorkerPty")
            child(root, config, arguments, parent, parent_fd)
        status = os.waitstatus_to_exitcode(os.waitpid(pid, 0)[1])
        os._exit(status if status >= 0 else 128 - status)
    except BaseException:
        os.write(2, b"Isolated worker private namespaces unavailable.\n")
        os._exit(125)


def launch(root_path, arguments):
    require(sys.platform == "linux" and os.geteuid() == 0, "WorkerOperatorPrivilegesRequired")
    require(hasattr(os, "pidfd_open") and hasattr(signal, "pidfd_send_signal"), "WorkerKernelUnsupported")
    root = directory(root_path)
    config = configuration(root)
    for fd in (0, 1, 2):
        mode = os.fstat(fd).st_mode
        require(not stat.S_ISDIR(mode), "WorkerStdioHandleDenied")
        if stat.S_ISSOCK(mode):
            # Node/Bun can implement piped stdio with Unix socket pairs. These
            # are explicit host channels; an inherited IP socket is rejected.
            with socket.socket(fileno=os.dup(fd)) as channel:
                require(channel.getsockopt(socket.SOL_SOCKET, socket.SO_DOMAIN) == socket.AF_UNIX and channel.getsockopt(socket.SOL_SOCKET, socket.SO_TYPE) == socket.SOCK_STREAM, "WorkerStdioHandleDenied")
    try:
        os.mkdir("/run/omos-worker-leases", 0o700)
    except FileExistsError:
        pass
    leases = directory("/run/omos-worker-leases")
    info = os.fstat(leases)
    require(info.st_uid == 0 and stat.S_IMODE(info.st_mode) == 0o700, "UnsafeWorkerLeaseDirectory")
    lock = os.open(str(config["uid"]), os.O_RDWR | os.O_CREAT | os.O_NOFOLLOW, 0o600, dir_fd=leases)
    info = os.fstat(lock)
    require(stat.S_ISREG(info.st_mode) and info.st_uid == 0 and stat.S_IMODE(info.st_mode) == 0o600 and info.st_nlink == 1, "UnsafeWorkerLease")
    fcntl.flock(lock, fcntl.LOCK_EX | fcntl.LOCK_NB)
    existing = list(owned_processes(config["uid"]))
    for fd in existing:
        os.close(fd)
    require(not existing, "WorkerUidBusy")
    checked(LIBC.prctl(36, 1, 0, 0, 0))  # child subreaper
    cancelled = False
    def cancel(_signal, _frame):
        nonlocal cancelled
        cancelled = True
    signal.signal(signal.SIGTERM, cancel)
    signal.signal(signal.SIGINT, cancel)
    parent = os.getpid()
    pid = os.fork()
    if pid == 0:
        if config.get("namespaces", True):
            namespace_child(root, root_path, config, arguments, parent)
        else:
            child(root, config, arguments, parent)
    deadline = time.monotonic() + config["max_runtime_ms"] / 1000
    outcome = None
    while not cancelled and time.monotonic() < deadline:
        finished, status = os.waitpid(pid, os.WNOHANG)
        if finished:
            outcome = os.waitstatus_to_exitcode(status)
            break
        time.sleep(0.05)
    if outcome is None:
        try:
            os.kill(pid, signal.SIGKILL)
        except ProcessLookupError:
            pass
    for _ in range(200):
        processes = list(owned_processes(config["uid"]))
        for fd in processes:
            try:
                signal.pidfd_send_signal(fd, signal.SIGKILL)
            except ProcessLookupError:
                pass
            finally:
                os.close(fd)
        try:
            while os.waitpid(-1, os.WNOHANG)[0]:
                pass
        except ChildProcessError:
            pass
        if not processes:
            return 124 if outcome is None else outcome if outcome >= 0 else 128 - outcome
        time.sleep(0.02)
    raise Rejected("WorkerCleanupPending")


if __name__ == "__main__":
    try:
        if sys.argv[1:] == ["--probe"]:
            print(json.dumps(probe()))
            sys.exit(0)
        require(len(sys.argv) >= 3 and sys.argv[2] == "--", "WorkerRootAndArgumentsRequired")
        sys.exit(launch(sys.argv[1], sys.argv[3:]))
    except (Rejected, OSError, ValueError, KeyError, TypeError) as error:
        code = str(error) if isinstance(error, Rejected) else "WorkerLaunchFailed"
        print(f"Isolated worker rejected: {code}", file=sys.stderr)
        sys.exit(125)
