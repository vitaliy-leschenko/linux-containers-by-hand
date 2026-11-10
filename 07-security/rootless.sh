#!/usr/bin/env bash
# Runs a command in a runc container as the current regular user, without root:
# root in the container is this user on the host (a user namespace with one ID).
# The bundle is temporary; the root filesystem only has to be readable.
#
# On Ubuntu 24.04 and later, unprivileged user namespaces are allowed only to
# programs with an AppArmor profile; for runc in /usr/local/sbin load
# runc-local.apparmor first (as root):
#   cp runc-local.apparmor /etc/apparmor.d/runc-local
#   apparmor_parser -r /etc/apparmor.d/runc-local
# Then, as a regular user:
#   ./rootless.sh /srv/c7r/rootfs                 # a shell (in a terminal)
#   ./rootless.sh /srv/c7r/rootfs id              # a command
set -euo pipefail

if [ "$(id -u)" -eq 0 ]; then
    echo "run as a regular user" >&2
    exit 1
fi
if [ $# -lt 1 ] || [ ! -d "$1" ]; then
    echo "usage: $0 <rootfs> [command [args...]]" >&2
    exit 1
fi
rootfs=$(realpath "$1")
shift

terminal=false
if [ $# -eq 0 ]; then
    set -- sh
    [ -t 0 ] && terminal=true
fi
# through stdin: jq would take options like -c in the command as its own
args=$(printf '%s\0' "$@" | jq -Rsc 'split("\u0000")[:-1]')

bundle=$(mktemp -d)
trap 'rm -rf "$bundle"' EXIT
cd "$bundle"
runc spec --rootless
jq --arg r "$rootfs" --argjson a "$args" --argjson t $terminal \
    '.root.path = $r | .process.terminal = $t | .process.args = $a' \
    config.json > config.json.tmp
mv config.json.tmp config.json
# the state of runc goes where this user can write: /run/user/<UID> in a login session
runc --root "${XDG_RUNTIME_DIR:-/tmp/runc-$(id -u)}/runc" run "rootless-$$"
