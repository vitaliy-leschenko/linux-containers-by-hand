#!/bin/sh
# Runs a command as a container without runc: new namespaces through unshare,
# the given root filesystem as the root through pivot_root, /proc, /sys and /dev
# mounted by hand, the root read-only. Everything is mounted into the rootfs
# before pivot_root, as runc does, so the image only needs sh and umount.
#
# Run as root:
#   ./container.sh /srv/c3/rootfs                 # a shell
#   ./container.sh /srv/c3/rootfs ps              # a command
# Without a cgroup, network and dropped capabilities: see parts 5, 6 and 7.
set -eu

if [ "${1:-}" != "--inside" ]; then
    if [ $# -lt 1 ] || [ ! -d "$1" ]; then
        echo "usage: $0 <rootfs> [command [args...]]" >&2
        exit 1
    fi
    exec unshare --mount --uts --ipc --net --pid --cgroup --fork "$0" --inside "$@"
fi
shift
r=$(realpath "$1")
shift

hostname box
ip link set lo up

# the new root must be a mount point
mount --bind "$r" "$r"
mount -t proc proc "$r/proc"
mount -t sysfs -o ro,nosuid,nodev,noexec sysfs "$r/sys"

mount -t tmpfs -o nosuid,mode=755,size=64k tmpfs "$r/dev"
mknod -m 666 "$r/dev/null" c 1 3
mknod -m 666 "$r/dev/zero" c 1 5
mknod -m 666 "$r/dev/full" c 1 7
mknod -m 666 "$r/dev/random" c 1 8
mknod -m 666 "$r/dev/urandom" c 1 9
mknod -m 666 "$r/dev/tty" c 5 0
mkdir "$r/dev/pts" "$r/dev/shm"
mount -t devpts -o newinstance,ptmxmode=0666,mode=0620 devpts "$r/dev/pts"
ln -s pts/ptmx "$r/dev/ptmx"
mount -t tmpfs -o nosuid,nodev,mode=1777 shm "$r/dev/shm"
ln -s /proc/self/fd "$r/dev/fd"
ln -s /proc/self/fd/0 "$r/dev/stdin"
ln -s /proc/self/fd/1 "$r/dev/stdout"
ln -s /proc/self/fd/2 "$r/dev/stderr"

# hide /proc/kcore, make /proc/sys and the root read-only
mount --bind "$r/dev/null" "$r/proc/kcore"
mount --bind "$r/proc/sys" "$r/proc/sys"
mount -o remount,bind,ro "$r/proc/sys"
mount -o remount,bind,ro "$r"

# the old root goes on top of the new one and is detached right away
cd "$r"
pivot_root . .
umount -l .
cd /

[ $# -gt 0 ] || set -- /bin/sh
exec "$@"
