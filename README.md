# Linux containers by hand

Examples for a blog series on [vitaliy.org](https://www.vitaliy.org) about running Linux
containers without Docker, going one layer down at a time:

1. containerd without Kubernetes: a manual install, `ctr`, runc, the CNI `bridge` plugin, nerdctl.
2. Below containerd: an OCI bundle (`rootfs` and `config.json`) and runc's `create`, `start`, `kill`, `delete`.
3. Without runc: namespaces with `unshare` and `nsenter`, the root with `pivot_root`, `/proc`, `/sys` and `/dev` by hand.

Each folder holds the examples of one part. Everything here has been run on the lab described
below before it was committed.

## Lab

- Ubuntu Server 26.04 (kernel 7.0, cgroup v2), a Hyper-V VM with 4 vCPUs and 8 GB of memory.
- Images from Docker Hub.

The examples change system state (network namespaces, bridges, iptables rules, cgroups).
Run them on a disposable VM, not on a machine you rely on.

## License

[MIT](LICENSE)
