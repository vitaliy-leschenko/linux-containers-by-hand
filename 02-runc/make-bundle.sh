#!/usr/bin/env bash
# Builds an OCI bundle for runc from a container image: the merged filesystem
# of the image goes to <dir>/rootfs, and `runc spec` writes <dir>/config.json.
# The spec is changed to run without a terminal, in the cgroup /lab/<name of dir>,
# with the given command (sh by default).
#
# Needs containerd, nerdctl, runc and jq (see part 1). Run as root:
#   ./make-bundle.sh docker.io/library/alpine:3.24 /srv/bundle sh -c 'hostname; ps'
#   cd /srv/bundle && runc run demo
set -euo pipefail

if [ $# -lt 2 ]; then
    echo "usage: $0 <image> <dir> [command [args...]]" >&2
    exit 1
fi
img=$1
dir=$2
shift 2
if [ -e "$dir" ]; then
    echo "$dir already exists" >&2
    exit 1
fi

mkdir -p "$dir/rootfs"
id=$(nerdctl create "$img")
trap 'nerdctl rm "$id" > /dev/null' EXIT
nerdctl export "$id" | tar -C "$dir/rootfs" -xf -

cd "$dir"
runc spec
args='["sh"]'
if [ $# -gt 0 ]; then
    # through stdin: jq would take options like -c in the command as its own
    args=$(printf '%s\0' "$@" | jq -Rsc 'split("\u0000")[:-1]')
fi
jq --argjson args "$args" --arg cg "/lab/$(basename "$dir")" \
    '.process.terminal = false | .process.args = $args | .linux.cgroupsPath = $cg' \
    config.json > config.json.tmp
mv config.json.tmp config.json
echo "bundle ready: $dir"
