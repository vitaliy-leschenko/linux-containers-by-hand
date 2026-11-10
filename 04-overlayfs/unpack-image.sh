#!/usr/bin/env bash
# Unpacks the layers of an image into separate directories and mounts them with
# overlayfs, without the snapshotter of containerd:
#   <dir>/layers/1 .. N   the layers, from the bottom one to the top one
#   <dir>/upper, work     the writable layer of the container and the work directory
#   <dir>/merged          the mounted root of the container
#   <dir>/image-config.json   the config of the image (entrypoint, command, environment)
# Whiteouts of the OCI format (.wh.<name> and .wh..wh..opq) are converted to the
# format of overlayfs (a 0:0 character device and the trusted.overlay.opaque xattr).
#
# Needs ctr (part 1), jq and setfattr (package attr). Run as root:
#   ./unpack-image.sh docker.io/library/nginx:1.30-alpine /srv/c4
#   umount /srv/c4/merged && rm -rf /srv/c4
set -euo pipefail

if [ $# -ne 2 ]; then
    echo "usage: $0 <image> <dir>" >&2
    exit 1
fi
img=$1
dir=$2
if [ -e "$dir" ]; then
    echo "$dir already exists" >&2
    exit 1
fi
case $(uname -m) in
    x86_64) arch=amd64 ;;
    aarch64) arch=arm64 ;;
    *) arch=$(uname -m) ;;
esac

blob() { echo "$dir/oci/blobs/sha256/${1#sha256:}"; }

# overlayfs whiteouts instead of OCI ones, in one unpacked layer
convert_whiteouts() {
    find "$1" -name '.wh..wh..opq' -print0 | while IFS= read -r -d '' f; do
        setfattr -n trusted.overlay.opaque -v y "$(dirname "$f")"
        rm "$f"
    done
    find "$1" -name '.wh.*' -print0 | while IFS= read -r -d '' f; do
        name=$(basename "$f")
        rm "$f"
        mknod "$(dirname "$f")/${name#.wh.}" c 0 0
    done
}

mkdir -p "$dir/oci"
ctr image pull --platform "linux/$arch" "$img" > /dev/null
ctr image export --platform "linux/$arch" "$dir/image.tar" "$img"
tar -C "$dir/oci" -xf "$dir/image.tar"
rm "$dir/image.tar"

# index.json -> (index of platforms ->) manifest
m=$(jq -r '.manifests[0].digest' "$dir/oci/index.json")
while jq -e '.manifests' "$(blob "$m")" > /dev/null; do
    m=$(jq -r --arg a "$arch" '[.manifests[] | select(.platform.os == "linux" and .platform.architecture == $a)][0].digest' "$(blob "$m")")
done
cp "$(blob "$(jq -r '.config.digest' "$(blob "$m")")")" "$dir/image-config.json"

n=0
lower=""
for d in $(jq -r '.layers[].digest' "$(blob "$m")"); do
    n=$((n + 1))
    mkdir -p "$dir/layers/$n"
    tar -C "$dir/layers/$n" -xf "$(blob "$d")"
    convert_whiteouts "$dir/layers/$n"
    lower="$dir/layers/$n${lower:+:$lower}"
done
rm -rf "$dir/oci"

mkdir -p "$dir/upper" "$dir/work" "$dir/merged"
mount -t overlay overlay -o "lowerdir=$lower,upperdir=$dir/upper,workdir=$dir/work" "$dir/merged"
echo "$n layers mounted at $dir/merged"
jq -c '.config | {Entrypoint, Cmd}' "$dir/image-config.json"
