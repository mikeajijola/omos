# Install a portable native bundle

Extract the archive for your platform and run `sh omos/install.sh`. The installer
verifies the bundle's component checksums and checks that the runtime starts
before changing the installation. It copies the native runtime into
`~/.fx/releases/<runtime-hash>/`, and copies the pinned Fossil helper into
`~/.fx/libexec/`. It then installs `omos` and `omo` aliases in `~/.local/bin/`
or `XDG_BIN_HOME`. You can remove the unpacked download afterward. Keep the
published archive checksum when checking a downloaded release.

Installation creates an empty personal Fossil instance if none is bound. An
existing workspace binding, tasks, history, files, and branches remain intact.
The helper is part of the download; a separate Fossil installation is not
required. Linux bundles use the upstream glibc executables. macOS bundles use
the upstream Intel or Apple Silicon executable matching the archive name.
Preview bundles still require the normal release signing and qualification
before production distribution.

The CLI runtime and the Fossil helper are separate files. `installation.json`
records their hashes and sizes. Packaging also reports compressed download
bytes. The CLI binary-size policy does not describe the whole archive size.

Source installations can continue using `sh scripts/install-omos.sh` to link
the current checkout's built runtime. Use `--copy` for a durable runtime copy.
Both modes preserve a verified helper and refuse unrelated existing aliases.

Update an installation by running the installer from a verified newer bundle.
Managed workspace invocations disable the upstream fx background updater and
reject `upgrade` before contacting that service. An upstream fx binary would
not preserve the Omniseed workspace runtime or its installed companions.

Build a portable runtime for the selected target before packaging. For Linux
Intel, use `zig build -Dtarget=x86_64-linux -Doptimize=ReleaseSafe -Dcpu=baseline`.
Use `aarch64-linux`, `x86_64-macos`, or `aarch64-macos` for the other platforms.
Stage the matching pinned upstream helper
with `python3 scripts/stage-fossil-helper.py --platform PLATFORM`, then run
`python3 scripts/package-omos.py --platform PLATFORM --output PATH.tar.gz`.
The lock file records upstream source identity, archive hashes, executable
hashes, and platform sizes. Packaging does not fetch or mutate personal state. Both
the runtime header and helper identity must match the requested platform.
`installation.json` marks these bundles as previews; packaging alone does not
establish production signing or PGSO qualification.

The installer also retains the optional company MCP companion and its native
operation declaration under the runtime's versioned release directory. Their
hashes and the entry path are recorded in `~/.fx/libexec/company-mcp.json`.
Interrupted installation can resume; changed files at an existing immutable
component path are retained and rejected. The unpacked download is not needed
after installation. Native CLI operation requires no Node.js runtime; using
this optional MCP transport requires Node.js 22 or newer. See the
[company connection procedure](company/README.md#connect-an-external-mcp-client).

The archive also contains the optional company gateway and Linux worker
companions under `deployment/company/`. Their bytes appear in the same verified
installation manifest. Personal installation does not enable the privileged
worker service. Retain the verified archive if you intend to install that
separate operator service, and follow [the worker deployment procedure](company/WORKERS.md).

The `Preview installation bundles` workflow builds Linux Intel, Linux ARM,
macOS Intel, and macOS Apple Silicon candidates on matching native runners.
It selects an explicit target and baseline CPU rather than inheriting the runner's
instruction set and operating-system defaults.
The Linux Intel job also starts the runtime on an emulated older CPU.
It stages the pinned helper and tests two fresh installations, both CLI aliases,
unique empty instances, portable export and restoration, and repository
verification after removing the unpacked source and making system Fossil
unavailable through `PATH`. Each artifact retains the archive checksum, byte
report, and installation result. It does not publish a release. Packaging and
its smoke procedure require Python 3.12 or newer; installed clients do not.

Run the same installation check locally with:

```sh
python3 scripts/smoke-omos-package.py PATH.tar.gz
```


Export personal state with `omos fossil export PATH`. The runtime installation
and credentials remain separate from that portable repository. Company service
deployment and authority recovery are described in
[the company deployment guide](company/README.md).
