#!/bin/bash
set -euxo pipefail
# Setup etc subvolume for T-U v5.0+
/usr/libexec/setup-etc-subvol

rootuuid=$(findmnt / -n --output uuid)
sed -i -e "s,\$, root=UUID=$rootuuid," /etc/kernel/cmdline
arch="$(uname -m)"
case "$arch" in
        x86_64) arch=x64 ;;
        *) echo "Unsupported architecture: $arch"; exit 1 ;;
esac
sdbootutil -v --secure-boot --no-random-seed --arch "$arch" --esp-path /boot/efi --portable --entry-token=auto --no-variables install
export hostonly_l=no # for dracut
sdbootutil -v --arch "$arch" --esp-path /boot/efi --portable --entry-token=auto add-all-kernels
# Boot menu for 5 seconds (it includes memtest86+), the OS entries as the
# default, and no restart when an entry fails to start
entry_token="$(cat /etc/kernel/entry-token)"
sed -i -e '/^#\?timeout /d' -e '/^default /d' -e '/^reboot-on-error /d' /boot/efi/loader/loader.conf
printf 'timeout 5\ndefault %s-*\nreboot-on-error no\n' "$entry_token" >> /boot/efi/loader/loader.conf
rm -f /boot/mbrid
