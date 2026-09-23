#!/bin/bash
set -euxo pipefail
# Setup etc subvolume for T-U v5.0+
/usr/libexec/setup-etc-subvol

# Fix the filesystem label of the ignition partition, uppercase doesn't work with ignition
e2label /dev/loop0p3 ignition

[ -x /usr/bin/sdbootutil ] || exit 0
echo "#######DISK"
rootuuid=$(findmnt / -n --output uuid)
sed -i -e "s,\$, root=UUID=$rootuuid," /etc/kernel/cmdline
arch="$(uname -m)"
case "$arch" in
        x86_64) arch=x64 ;;
        *) echo "Unsupported arch for Aeon - $arch"; exit 1 ;;
esac
echo "install boot loader"
sdbootutil -v --secure-boot --no-random-seed --arch "$arch" --esp-path /boot/efi --portable --entry-token=auto --no-variables install
echo "add kernels"
export hostonly_l=no # for dracut
sdbootutil -v --arch "$arch" --esp-path /boot/efi --portable --entry-token=auto add-all-kernels
echo "boot menu"
# TCBL: `sdbootutil install` above also added memtest86+ to this USB's boot
# menu, from memtest86+-bls (installed systems mask it; see the tik post module
# 13-tcbl-no-memtest in config.sh). Show the menu for 5 seconds, and keep the
# OS entries the default however the memtest86+ entry sorts.
entry_token="$(cat /etc/kernel/entry-token)"
sed -i -e '/^#\?timeout /d' -e '/^default /d' /boot/efi/loader/loader.conf
printf 'timeout 5\ndefault %s-*\n' "$entry_token" >> /boot/efi/loader/loader.conf
echo "##### AFTER ####"
rm -f /boot/mbrid
find /boot
