#!/usr/bin/env bash
# Runs a command in its own cgroup v2 group /sys/fs/cgroup/lab/run-<PID> with
# limits on memory, CPU and processes, then prints what the kernel counted and
# removes the group. Run as root:
#   ./run-limited.sh -m 64M -- bash -c 'x=a; while :; do x=$x$x; done'
#   ./run-limited.sh -c 0.5 -- sh -c 'while :; do :; done'
#   ./run-limited.sh -m 64M -p 20 -- ../03-namespaces/container.sh /srv/c5/rootfs
set -euo pipefail

usage() {
    echo "usage: $0 [-m memory] [-c cpus] [-p pids] -- command [args...]" >&2
    exit 1
}

mem=max
cpu=max
pids=max
while getopts m:c:p: o; do
    case $o in
        m) mem=$OPTARG ;;
        c) cpu=$(awk -v c="$OPTARG" 'BEGIN { printf "%d 100000", c * 100000 }') ;;
        p) pids=$OPTARG ;;
        *) usage ;;
    esac
done
shift $((OPTIND - 1))
[ "${1:-}" = "--" ] && shift
[ $# -gt 0 ] || usage

cg=/sys/fs/cgroup/lab
mkdir -p $cg
grep -qw memory $cg/cgroup.subtree_control || echo '+memory +cpu +pids' > $cg/cgroup.subtree_control
g=$cg/run-$$
mkdir $g
echo "$mem" > $g/memory.max
[ "$mem" = max ] || echo 0 > $g/memory.swap.max
echo "$cpu" > $g/cpu.max
echo "$pids" > $g/pids.max

# on any exit (Ctrl+C too): kill what the command left behind, remove the group
cleanup() {
    echo 1 > $g/cgroup.kill
    while [ -n "$(cat $g/cgroup.procs)" ]; do sleep 0.1; done
    rmdir $g
    rmdir $cg 2> /dev/null || true
}
trap cleanup EXIT

# the child moves itself into the group and becomes the command
set +e
bash -c 'echo $$ > "$1/cgroup.procs"; shift; exec "$@"' run "$g" "$@"
rc=$?
set -e

{
    echo "exit code: $rc"
    echo "memory: peak $(cat $g/memory.peak), oom_kill $(awk '/^oom_kill /{print $2}' $g/memory.events)"
    echo "cpu: $(awk '/^(usage_usec|nr_throttled) / {printf "%s %s ", $1, $2}' $g/cpu.stat)"
    echo "pids: peak $(cat $g/pids.peak), refused forks $(awk '/^max /{print $2}' $g/pids.events)"
} >&2
exit $rc
