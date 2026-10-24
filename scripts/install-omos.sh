#!/bin/sh
set -eu
umask 077

checkout_dir=$(CDPATH='' cd -- "$(dirname -- "$0")/.." && pwd)
binary_path="$checkout_dir/zig-out/bin/fx"
install_dir="${XDG_BIN_HOME:-$HOME/.local/bin}"
copy_binary=0
if [ "$#" -gt 0 ]; then
    if [ "$#" -ne 1 ] || [ "$1" != '--copy' ]; then
        echo 'usage: install-omos.sh [--copy]' >&2
        exit 2
    fi
    copy_binary=1
fi

sha256_file() {
    if command -v sha256sum >/dev/null 2>&1; then
        sha256sum "$1" | cut -d ' ' -f 1
    else
        shasum -a 256 "$1" | cut -d ' ' -f 1
    fi
}

if [ ! -x "$binary_path" ]; then
    echo 'Build the CLI with zig build before installing its commands.' >&2
    exit 1
fi
source_binary="$binary_path"
runtime_hash=$(sha256_file "$binary_path")
runtime_dir="$HOME/.fx/releases/$runtime_hash"
if [ "$copy_binary" -eq 1 ]; then
    binary_path="$runtime_dir/fx"
fi

company_source="$checkout_dir/deployment/company/mcp.mjs"
company_schema="$checkout_dir/src/core/workspace/standard/omos.json"
if [ ! -f "$company_source" ] || [ ! -f "$company_schema" ]; then
    echo 'The installation is missing its company MCP companion or operation schema.' >&2
    exit 1
fi
company_hash=$(sha256_file "$company_source")
company_schema_hash=$(sha256_file "$company_schema")

mkdir -p "$install_dir"
for command in omos omo; do
    destination="$install_dir/$command"
    if [ -e "$destination" ] || [ -L "$destination" ]; then
        accepted=0
        if [ -L "$destination" ]; then
            previous=$(readlink "$destination")
            if [ "$previous" = "$binary_path" ]; then
                accepted=1
            elif [ "$copy_binary" -eq 1 ]; then
                case "$previous" in "$HOME/.fx/releases/"*/fx) accepted=1 ;; esac
            fi
        fi
        if [ "$accepted" -ne 1 ]; then
            echo "Refusing to replace an existing command: $destination" >&2
            exit 1
        fi
    fi
done
# Prefer a packaged helper when supplied; source installs can use host Fossil.
fossil_source="$checkout_dir/zig-out/libexec/fossil"
if [ ! -x "$fossil_source" ]; then
    fossil_source=$(command -v fossil || true)
fi
if [ -z "$fossil_source" ] || [ ! -x "$fossil_source" ]; then
    echo 'The installation requires its packaged Fossil helper or an existing Fossil executable.' >&2
    exit 1
fi
helper_dir="$HOME/.fx/libexec"
mkdir -p "$helper_dir"
chmod 700 "$helper_dir"
helper_temporary=$(mktemp "$helper_dir/fossil.install.XXXXXXXX")
trap 'rm -f "$helper_temporary" "$helper_temporary.manifest"' EXIT HUP INT TERM
cp "$fossil_source" "$helper_temporary"
chmod 700 "$helper_temporary"
helper_hash=$(sha256_file "$helper_temporary")
printf '{"version":1,"file":"fossil-%s","sha256":"%s"}\n' "$helper_hash" "$helper_hash" > "$helper_temporary.manifest"
chmod 600 "$helper_temporary.manifest"
mv "$helper_temporary" "$helper_dir/fossil-$helper_hash"
mv "$helper_temporary.manifest" "$helper_dir/fossil.json"
trap - EXIT HUP INT TERM

# Publish each immutable companion file exclusively. The locator is activated
# only after both files are verified, so interrupted installation can resume.
install_component() {
    component_source="$1"
    component_target="$2"
    component_expected="$3"
    if [ -e "$component_target" ] || [ -L "$component_target" ]; then
        if [ -L "$component_target" ] || [ ! -f "$component_target" ] || [ "$(sha256_file "$component_target")" != "$component_expected" ]; then
            echo "Refusing to replace a changed installation component: $component_target" >&2
            exit 1
        fi
        return
    fi
    component_parent=$(dirname -- "$component_target")
    mkdir -p "$component_parent"
    component_temporary=$(mktemp "$component_parent/.component.install.XXXXXXXX")
    trap 'rm -f "$component_temporary"' EXIT HUP INT TERM
    cp "$component_source" "$component_temporary"
    chmod 600 "$component_temporary"
    if [ "$(sha256_file "$component_temporary")" != "$component_expected" ]; then
        echo 'An installation component changed while it was being copied.' >&2
        exit 1
    fi
    if ln "$component_temporary" "$component_target" 2>/dev/null; then
        :
    elif [ -L "$component_target" ] || [ ! -f "$component_target" ] || [ "$(sha256_file "$component_target")" != "$component_expected" ]; then
        echo "Refusing to replace a concurrent installation component: $component_target" >&2
        exit 1
    fi
    rm -f "$component_temporary"
    trap - EXIT HUP INT TERM
}

mkdir -p "$runtime_dir"
chmod 700 "$runtime_dir"
company_relative="releases/$runtime_hash/deployment/company/mcp.mjs"
schema_relative="releases/$runtime_hash/src/core/workspace/standard/omos.json"
install_component "$company_source" "$HOME/.fx/$company_relative" "$company_hash"
install_component "$company_schema" "$HOME/.fx/$schema_relative" "$company_schema_hash"
company_locator=$(mktemp "$helper_dir/company-mcp.install.XXXXXXXX")
trap 'rm -f "$company_locator"' EXIT HUP INT TERM
printf '{"version":"omos.company-mcp-installation/v1","file":"%s","runtime_sha256":"%s","files":[{"path":"%s","sha256":"%s"},{"path":"%s","sha256":"%s"}]}\n' "$company_relative" "$runtime_hash" "$company_relative" "$company_hash" "$schema_relative" "$company_schema_hash" > "$company_locator"
chmod 600 "$company_locator"
mv "$company_locator" "$helper_dir/company-mcp.json"
trap - EXIT HUP INT TERM

if [ "$copy_binary" -eq 1 ]; then
    mkdir -p "$runtime_dir"
    chmod 700 "$runtime_dir"
    runtime_temporary=$(mktemp "$runtime_dir/runtime.install.XXXXXXXX")
    trap 'rm -f "$runtime_temporary"' EXIT HUP INT TERM
    cp "$source_binary" "$runtime_temporary"
    chmod 700 "$runtime_temporary"
    if [ "$(sha256_file "$runtime_temporary")" != "$runtime_hash" ]; then
        echo 'The runtime changed while it was being installed.' >&2
        exit 1
    fi
    mv "$runtime_temporary" "$binary_path"
    trap - EXIT HUP INT TERM
fi

for command in omos omo; do
    destination="$install_dir/$command"
    if [ ! -L "$destination" ] || [ "$(readlink "$destination")" != "$binary_path" ]; then
        pending_link="$install_dir/.$command.install.$$"
        trap 'rm -f "$pending_link"' EXIT HUP INT TERM
        ln -s "$binary_path" "$pending_link"
        mv -f "$pending_link" "$destination"
        trap - EXIT HUP INT TERM
    fi
    echo "Installed $command: $destination"
done

echo "Optional company MCP companion: $HOME/.fx/$company_relative"

"$install_dir/omos" fossil ensure --json

case ":$PATH:" in
    *":$install_dir:"*) ;;
    *) echo "Add $install_dir to your PATH to use these commands." ;;
esac
