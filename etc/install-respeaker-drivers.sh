#!/usr/bin/env bash

# Installs drivers for the ReSpeaker 2mic and 4mic HATs on Raspberry Pi OS.
# Must be run with sudo.
# Requires: curl raspberrypi-kernel-headers dkms i2c-tools libasound2-plugins alsa-utils

set -eo pipefail

# Extract major.minor from current kernel version (e.g., "6.12")
kernel_major_minor="$(uname -r | grep -oP '^\d+\.\d+')"

# Try to find a matching branch in the repo
echo "Looking for a driver branch that matches kernel $kernel_major_minor..."

available_branches=$(curl -s https://api.github.com/repos/HinTak/seeed-voicecard/branches | grep '"name":' | cut -d'"' -f4)

# Search for an exact match first
if echo "$available_branches" | grep -q "^v$kernel_major_minor$"; then
    kernel_branch="v$kernel_major_minor"
    echo "Found matching driver branch: $kernel_branch"
else
    echo "No matching driver branch found for kernel $kernel_major_minor"
    echo "Available branches:"
    echo "$available_branches"
    exit 1
fi


apt-get update
apt-get install --no-install-recommends --yes \
    curl raspberrypi-kernel-headers dkms i2c-tools libasound2-plugins alsa-utils

temp_dir="$(mktemp -d)"

function finish {
   rm -rf "${temp_dir}"
}

trap finish EXIT

pushd "${temp_dir}"

# Download source code to temporary directory
# NOTE: There are different branches in the repo for different kernel versions.
echo 'Downloading source code'
curl -L -o - "https://github.com/HinTak/seeed-voicecard/archive/refs/heads/${kernel_branch}.tar.gz" | \
    tar -xzf -
folder=$(find . -maxdepth 1 -type d -name "seeed-voicecard*" | head -n1)
cd "$folder" || { echo "❌ Failed to cd into extracted source folder"; exit 1; }


# 1. Build kernel module
echo 'Building kernel module'
ver='0.3'
mod='seeed-voicecard'
src='./'
kernel="$(uname -r)"
marker='0.0.0'
threads="$(getconf _NPROCESSORS_ONLN)"
memory="$(LANG=C free -m|awk '/^Mem:/{print $2}')"

if  [ "${memory}" -le 512 ] && [ "${threads}" -gt 2 ]; then
threads=2
fi

mkdir -p "/usr/src/${mod}-${ver}"
cp -a "${src}"/* "/usr/src/${mod}-${ver}/"

dkms add -m "${mod}" -v "${ver}"
dkms build -k "${kernel}" -m "${mod}" -v "${ver}" -j "${threads}" && {
    dkms install --force -k "${kernel}" -m "${mod}" -v "${ver}"
}

mkdir -p "/var/lib/dkms/${mod}/${ver}/${marker}"

# 2. Install kernel module and configure
echo 'Updating boot configuration'
config='/boot/config.txt'

cp seeed-*-voicecard.dtbo /boot/overlays
grep -q "^snd-soc-ac108$" /etc/modules || echo "snd-soc-ac108" >> /etc/modules
sed -i -e 's:#dtparam=i2c_arm=on:dtparam=i2c_arm=on:g' "${config}"
echo "dtoverlay=i2s-mmap" >> "${config}"
echo "dtparam=i2s=on" >> "${config}"
mkdir -p /etc/voicecard
cp *.conf *.state /etc/voicecard
cp seeed-voicecard /usr/bin/
cp seeed-voicecard.service /lib/systemd/system/
systemctl enable --now seeed-voicecard.service

echo 'Done. Please reboot the system.'
popd


