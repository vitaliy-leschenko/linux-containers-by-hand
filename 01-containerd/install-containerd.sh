#!/usr/bin/env bash
# Installs containerd, runc, the CNI plugins and nerdctl from their GitHub releases,
# verifies every download and writes the CNI network "lab". Run as root on a disposable
# machine. Versions and the subnet are environment variables:
#
#   sudo CONTAINERD_VERSION=2.4.2 SUBNET=172.30.0.0/16 GATEWAY=172.30.0.1 ./install-containerd.sh
set -euo pipefail

CONTAINERD_VERSION="${CONTAINERD_VERSION:-2.4.2}"
RUNC_VERSION="${RUNC_VERSION:-1.5.2}"
CNI_VERSION="${CNI_VERSION:-1.10.0}"
NERDCTL_VERSION="${NERDCTL_VERSION:-2.4.2}"
SUBNET="${SUBNET:-172.30.0.0/16}"
GATEWAY="${GATEWAY:-172.30.0.1}"

work="$(mktemp -d)"
trap 'rm -rf "$work"' EXIT
cd "$work"

fetch() { curl -fsSLO "$1"; }

# containerd and its systemd unit
file="containerd-$CONTAINERD_VERSION-linux-amd64.tar.gz"
base="https://github.com/containerd/containerd/releases/download/v$CONTAINERD_VERSION"
fetch "$base/$file"
fetch "$base/$file.sha256sum"
sha256sum -c "$file.sha256sum"
tar -xzf "$file" -C /usr/local
mkdir -p /usr/local/lib/systemd/system
curl -fsSL -o /usr/local/lib/systemd/system/containerd.service \
    "https://raw.githubusercontent.com/containerd/containerd/v$CONTAINERD_VERSION/containerd.service"

# runc
base="https://github.com/opencontainers/runc/releases/download/v$RUNC_VERSION"
fetch "$base/runc.amd64"
fetch "$base/runc.sha256sum"
grep ' \*\?runc.amd64$' runc.sha256sum | sha256sum -c -
install -m 755 runc.amd64 /usr/local/sbin/runc

# CNI plugins
file="cni-plugins-linux-amd64-v$CNI_VERSION.tgz"
base="https://github.com/containernetworking/plugins/releases/download/v$CNI_VERSION"
fetch "$base/$file"
fetch "$base/$file.sha256"
sha256sum -c "$file.sha256"
mkdir -p /opt/cni/bin /etc/cni/net.d
tar -xzf "$file" -C /opt/cni/bin

# nerdctl
file="nerdctl-$NERDCTL_VERSION-linux-amd64.tar.gz"
base="https://github.com/containerd/nerdctl/releases/download/v$NERDCTL_VERSION"
fetch "$base/$file"
fetch "$base/SHA256SUMS"
grep " $file\$" SHA256SUMS | sha256sum -c -
tar -xzf "$file" -C /usr/local/bin nerdctl

# the CNI network
cat > /etc/cni/net.d/10-lab.conflist <<EOF
{
    "cniVersion": "1.0.0",
    "name": "lab",
    "plugins": [
        {
            "type": "bridge",
            "bridge": "lab0",
            "isGateway": true,
            "ipMasq": true,
            "ipam": {
                "type": "host-local",
                "ranges": [
                    [{ "subnet": "$SUBNET", "gateway": "$GATEWAY" }]
                ],
                "routes": [
                    { "dst": "0.0.0.0/0" }
                ]
            }
        },
        {
            "type": "portmap",
            "capabilities": { "portMappings": true }
        }
    ]
}
EOF

# containerd configuration and service
mkdir -p /etc/containerd
containerd config default > /etc/containerd/config.toml
systemctl daemon-reload
systemctl enable --now containerd

ctr version
runc --version
nerdctl network ls
