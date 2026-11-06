#!/bin/bash
# Copyright (c) 2020 SUSE LLC
#
# Permission is hereby granted, free of charge, to any person obtaining a copy
# of this software and associated documentation files (the "Software"), to deal
# in the Software without restriction, including without limitation the rights
# to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
# copies of the Software, and to permit persons to whom the Software is
# furnished to do so, subject to the following conditions:
# 
# The above copyright notice and this permission notice shall be included in
# all copies or substantial portions of the Software.
# 
# THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
# IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
# FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
# AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
# LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
# OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
# SOFTWARE.
# 
#======================================
# Functions...
#--------------------------------------

test -f /.kconfig && . /.kconfig
test -f /.profile && . /.profile

set -euxo pipefail

echo "Configure image: [$kiwi_iname]-[$kiwi_profiles]..."

# Systemd controls the console font now
echo FONT="eurlatgr.psfu" >> /etc/vconsole.conf

# Build stamp: which build an image or installed system came from
echo "TCBL $(date -u +%FT%TZ)" > /usr/lib/tc-benchtop-build-id

#======================================
# prepare for setting root pw, timezone
#--------------------------------------
echo "** reset machine settings"
rm -f /etc/machine-id \
      /var/lib/zypp/AnonymousUniqueId \
      /var/lib/systemd/random-seed

#======================================
# Import trusted rpm keys
#--------------------------------------
suseImportBuildKey

#=====================================
# Configure snapper
#-------------------------------------
if [ "${kiwi_btrfs_root_is_snapshot-false}" = 'true' ]; then
        echo "creating initial snapper config ..."
        cp /usr/share/snapper/config-templates/default /etc/snapper/configs/root
        baseUpdateSysConfig /etc/sysconfig/snapper SNAPPER_CONFIGS root

	# Adjust parameters
	sed -i'' 's/^TIMELINE_CREATE=.*$/TIMELINE_CREATE="no"/g' /etc/snapper/configs/root
	sed -i'' 's/^NUMBER_LIMIT=.*$/NUMBER_LIMIT="2-10"/g' /etc/snapper/configs/root
	sed -i'' 's/^NUMBER_LIMIT_IMPORTANT=.*$/NUMBER_LIMIT_IMPORTANT="4-10"/g' /etc/snapper/configs/root
fi

#=====================================
# Storage configuration
#-------------------------------------

# The %post script can't edit /etc/fstab sys due to https://github.com/OSInside/kiwi/issues/945
# so use the kiwi custom hack
cat >/etc/fstab.script <<"EOF"
#!/bin/sh
set -eux

# https://bugzilla.opensuse.org/show_bug.cgi?id=1246605 change 'ro' to 'ro=vfs'
gawk -i inplace '$2 == "/" && $4 == "compress=zstd:1,ro" { $4 = "compress=zstd:1,ro=vfs" } { print $0 }' /etc/fstab

# Relabel /etc. While kiwi already relabelled it earlier, there are some files created later (boo#1210604).
# The "gawk -i inplace" above also removes the label on /etc/fstab.
if [ -e /etc/selinux/config ]; then
        . /etc/selinux/config
        setfiles -e /proc -e /sys -e /dev /etc/selinux/${SELINUXTYPE}/contexts/files/file_contexts /etc
fi
EOF

chmod a+x /etc/fstab.script
mkdir -p /ignition

#======================================
# Installer session (USB only)
#--------------------------------------
# "Install Benchtop" logs tik in and autostarts the installer; tik's 10-sicu
# removes this on the installed system. Unlike on Aeon, tik is not in wheel,
# which would also give it SMBus access.
useradd -m -c "Install Benchtop" tik

cat > /etc/sudoers.d/51-tik << "EOF"
tik ALL = (root) NOPASSWD: ALL
EOF

cat > /etc/polkit-1/rules.d/10-tik.rules << "EOF"
polkit.addRule(function(action, subject) {
    if (subject.user == "tik") {
        return polkit.Result.YES;
    }
});
EOF

chown tik:users /ignition

mkdir -p /home/tik/.local/share/applications
cat > /home/tik/.local/share/applications/org.technicomp.tik.desktop << "EOF"
[Desktop Entry]
Name=Technicomp Benchtop Linux Installer
Comment=Installs Technicomp Benchtop Linux
Exec=/usr/bin/tik
Icon=drive-harddisk
Type=Application
Categories=System;
EOF

mkdir -p /home/tik/.config/autostart
ln -s /home/tik/.local/share/applications/org.technicomp.tik.desktop \
      /home/tik/.config/autostart/org.technicomp.tik.desktop

mkdir -p /home/tik/.config/gtk-3.0
echo "file:///ignition" >> /home/tik/.config/gtk-3.0/bookmarks

# No gnome-initial-setup and no Flathub for tik
echo yes > /home/tik/.config/gnome-initial-setup-done
mkdir -p /home/tik/.config/systemd/user
ln -s /dev/null /home/tik/.config/systemd/user/configure-user-flathub.service

chown -R tik:users /home/tik

#======================================
# Live USB login screen (USB only)
#--------------------------------------
# "Create User" makes an administrator account for using the USB as a live
# system; the installer copies such accounts to the installed system, where
# 17-tcbl-live-cleanup removes tcbl-newuser and the rules below.

# "Create User" account; its session runs only the account-creation dialog.
useradd -m -c "Create User" tcbl-newuser
mkdir -p /home/tcbl-newuser/.config/autostart
cat > /home/tcbl-newuser/.config/autostart/org.technicomp.create-user.desktop << "EOF"
[Desktop Entry]
Type=Application
Name=Create User
Exec=/usr/libexec/tcbl/create-user-dialog
NoDisplay=true
EOF
echo yes > /home/tcbl-newuser/.config/gnome-initial-setup-done
# No Flathub for tcbl-newuser
mkdir -p /home/tcbl-newuser/.config/systemd/user
ln -s /dev/null /home/tcbl-newuser/.config/systemd/user/configure-user-flathub.service
chown -R tcbl-newuser: /home/tcbl-newuser

# GDM does not list locked accounts: give both a random, unrecorded password
for account in tik tcbl-newuser; do
	{ printf '%s:' "${account}"; head -c 32 /dev/urandom | base64; } | chpasswd
done

# Passwordless GDM login for these two accounts (/etc/pam.d overrides
# /usr/lib/pam.d; 17-tcbl-live-cleanup deletes the copy)
if [ -f /usr/lib/pam.d/gdm-password ] && [ ! -e /etc/pam.d/gdm-password ]; then
	awk -v rule='auth     sufficient     pam_succeed_if.so quiet user in tik:tcbl-newuser' '
		NR == 1 && /^#%PAM/ { print; print rule; next }
		NR == 1 { print rule }
		{ print }' /usr/lib/pam.d/gdm-password > /etc/pam.d/gdm-password
else
	echo "WARNING (TCBL): /usr/lib/pam.d/gdm-password missing or /etc/pam.d/gdm-password present; passwordless GDM login NOT configured"
fi

# tcbl-newuser may run only the create-user helper as root
cat > /etc/sudoers.d/52-tcbl-newuser << "EOF"
tcbl-newuser ALL = (root) NOPASSWD: /usr/libexec/tcbl/create-user ""
EOF
chmod 0440 /etc/sudoers.d/52-tcbl-newuser
visudo -cf /etc/sudoers.d/52-tcbl-newuser

#======================================
# Kernel command line
#--------------------------------------
# Options come from tc-benchtop-settings; disk.sh and tik append root=UUID=
mkdir -p /etc/kernel
echo "ignition.platform.id=metal" > /etc/kernel/cmdline

#======================================
# SELinux
#--------------------------------------
if [[ -e /etc/selinux/config ]]; then
	# Move an /.autorelabel file from initial installation to writeable location
	test -f /.autorelabel && mv /.autorelabel /etc/selinux/.autorelabel
fi

#======================================
# systemd-boot specifics
#--------------------------------------
for d in /usr/lib/modules/*; do
	test -d "$d" || continue
	depmod -a "${d##*/}"
done
ENTRY_TOKEN=$(. /usr/lib/os-release; echo $ID)
echo "$ENTRY_TOKEN" > /etc/kernel/entry-token
# FIXME: kiwi needs /boot/efi to exist before syncing the disk image
mkdir -p /boot/efi
mkdir -p /boot/efi/loader/entries
echo -e "LOADER_TYPE=systemd-boot\nSECURE_BOOT=yes" > /etc/sysconfig/bootloader

#======================================
# Aeon specifics
#--------------------------------------

echo 'ExecStartPre=/bin/sh -c "echo 'Please wait.. setting up your computer.. this may take a few minutes'"' >> /usr/lib/dracut/modules.d/30ignition/ignition-disks.service
echo 'StandardOutput=tty' >> /usr/lib/dracut/modules.d/30ignition/ignition-disks.service

# gh#AeonDesktop/project#7
systemctl mask systemd-growfs-root.service

# Add /etc mount for final system
cat >> /etc/fstab.tik << "EOF"
/etc /etc none bind,x-initrd.mount 0 0
EOF

#======================================
# Size of what the installer copies, for its progress (measured last)
#--------------------------------------
# Same exclusions as ExcludeFiles= in /usr/lib/repart.d/50-root.conf
du -sbx --exclude=/tmp --exclude=/var/tmp --exclude=/boot --exclude=/mnt --exclude=/run \
    --exclude=/ignition --exclude=/var/cache/zypp --exclude=/var/cache/man --exclude=/var/log/journal \
    / | cut -f1 > /usr/share/tcbl/copy-bytes
