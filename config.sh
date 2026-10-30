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

# Build stamp: identifies exactly which build produced this image (and the
# system installed from it). `cat /usr/lib/tc-benchtop-build-id` on any booted
# image, matched against the OBS build time, proves whether a burn is current.
echo "TCBL $(date -u +%FT%TZ)" > /usr/lib/tc-benchtop-build-id

# The name in os-release (Technicomp Benchtop Linux) comes from repo-tcbl's
# openSUSE-release, a link to openSUSE's with only NAME and PRETTY_NAME changed.

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

# Add repos from /etc/YaST2/control.xml
if [ -x /usr/sbin/add-yast-repos ]; then
	add-yast-repos
	zypper --non-interactive rm -u live-add-yast-repos
fi

#=====================================
# Configure snapper
#-------------------------------------
if [ "${kiwi_btrfs_root_is_snapshot-false}" = 'true' ]; then
        echo "creating initial snapper config ..."
        cp /etc/snapper/config-templates/default /etc/snapper/configs/root \
		|| cp /usr/share/snapper/config-templates/default /etc/snapper/configs/root
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
# Full-disk encryption (install-time, via tik)
#--------------------------------------
# TCBL no longer encrypts in the initrd. The installer (tik + systemd-repart)
# creates the LUKS2 root and sizes it at install time; tik enrols TPM2 (sealed
# to PCRs 4,5,7,9, as on Aeon) or a passphrase, plus a recovery key.
# measure-pcr-validator.ignore=yes (added further down) is copied onto the
# target, so the PCR 15 check after unlocking never halts the boot.

#======================================
# Installer session: tik user + GNOME autostart (self-deploy USB only)
#--------------------------------------
# Choosing "Install Benchtop" (the tik account's full name) on the login screen
# logs the "tik" user into the normal GNOME session without a password (see
# "Live USB login screen" below); a GNOME autostart entry then launches
# /usr/bin/tik. tik's 10-sicu post module removes all of this on the deployed
# target, so only the USB runs the installer. Mirrors the "tik specifics" block
# of devel:microos:aeon:images/Aeon config.sh, rebranded for TCBL and without
# its tik autologin. Requires a full GNOME session (gdm + gnome-shell +
# gnome-session-wayland) in the image. Unlike on Aeon, tik is not in wheel:
# its sudo and polkit rights are granted by name below, and wheel would also
# give it the SMBus access that tc-benchtop-settings reserves for
# administrators.
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

# Suppress the GNOME welcome/initial-setup wizard for the tik user, so the
# installer autostart owns the first session instead of gnome-initial-setup.
echo yes > /home/tik/.config/gnome-initial-setup-done

# The installer account needs no Flathub: mask the per-user service that adds
# it (tcbl-flathub.service, from tc-benchtop-settings).
mkdir -p /home/tik/.config/systemd/user
ln -s /dev/null /home/tik/.config/systemd/user/tcbl-flathub.service

chown -R tik:users /home/tik

#======================================
# Live USB login screen (self-deploy USB only)
#--------------------------------------
# The USB boots to GDM, which lists two passwordless accounts:
#   "Install Benchtop" (tik)       the installer session (tik autostarts)
#   "Create User" (tcbl-newuser)   asks for a new account's details, creates it
#                                  as an administrator, then logs out
# Accounts made with "Create User" are for using the USB as a live system. The
# installer copies them, with their home folders, into every system installed
# from the USB. Once an account exists, "Create User" is hidden from the login
# screen. On the installed system, tik's 10-sicu removes tik, and the TCBL
# 17-tcbl-live-cleanup post module removes tcbl-newuser and the rules below.

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
# No Flathub for this account either (see the tik account above).
mkdir -p /home/tcbl-newuser/.config/systemd/user
ln -s /dev/null /home/tcbl-newuser/.config/systemd/user/tcbl-flathub.service
chown -R tcbl-newuser: /home/tcbl-newuser

# GNOME's login screen does not list locked accounts, and useradd creates both
# accounts locked ('!' in /etc/shadow). Give each a random password that is
# never shown or stored anywhere; they log in through the GDM rule below.
for account in tik tcbl-newuser; do
	{ printf '%s:' "${account}"; head -c 32 /dev/urandom | base64; } | chpasswd
done

# Passwordless login from the GDM login screen for these two accounts only.
# openSUSE ships gdm's PAM configuration in /usr/lib/pam.d, and a file of the
# same name in /etc/pam.d replaces it, so copy the packaged file with the rule
# added first. 17-tcbl-live-cleanup deletes this copy on the installed system,
# which then uses the packaged file again.
if [ -f /usr/lib/pam.d/gdm-password ] && [ ! -e /etc/pam.d/gdm-password ]; then
	awk -v rule='auth     sufficient     pam_succeed_if.so quiet user in tik:tcbl-newuser' '
		NR == 1 && /^#%PAM/ { print; print rule; next }
		NR == 1 { print rule }
		{ print }' /usr/lib/pam.d/gdm-password > /etc/pam.d/gdm-password
else
	echo "WARNING (TCBL): /usr/lib/pam.d/gdm-password missing or /etc/pam.d/gdm-password present; passwordless GDM login NOT configured"
fi

# The dialog runs as tcbl-newuser. Creating the account needs root, so that
# account may run exactly one root helper, with no arguments.
cat > /etc/sudoers.d/52-tcbl-newuser << "EOF"
tcbl-newuser ALL = (root) NOPASSWD: /usr/libexec/tcbl/create-user ""
EOF
chmod 0440 /etc/sudoers.d/52-tcbl-newuser
visudo -cf /etc/sudoers.d/52-tcbl-newuser

# (/usr/libexec/tcbl/create-user and its dialog come from tik-config-benchtop)

#======================================
# Installer
#--------------------------------------
# tik's settings, the target disk's layout (repart.d), TCBL's tik modules, copy
# progress and the "Create User" helpers come from tik-config-benchtop
# (repository benchtop-installer). What stays here belongs to this image alone:
# the two live accounts above, their rules, and the size of the copy below.

#======================================
# Services
#--------------------------------------
# Enabled by presets, which systemd applies at the first boot: NetworkManager,
# systemd-resolved and zram swap by tc-benchtop-settings (85-tcbl.preset);
# chronyd, irqbalance and fstrim.timer by openSUSE's own presets. rtkit-daemon
# is started by D-Bus when a program asks for realtime scheduling.

#======================================
# Kernel command line
#--------------------------------------
# TCBL: the options themselves come from tc-benchtop-settings
# (/usr/kernel/cmdline.d/90-tcbl.conf), which sdbootutil adds to every boot
# entry, so changes reach installed systems with updates. Only what belongs to
# this image is written here: ignition's platform, for the image's first boot.
# disk.sh and the installer (tik's 15-encrypt) append root=UUID=.
# TCBL: no serial console. Aeon, like MicroOS, adds console=ttyS0,115200
# console=tty0 for servers and VMs; without console= the kernel uses the screen.
cmdline=()

ignition_platform='metal'

if [ -n "${ignition_platform}" ]; then
	cmdline+=("ignition.platform.id=${ignition_platform}")
fi

#======================================
# SELinux
#--------------------------------------
# security=selinux is in tc-benchtop-settings' command line file; enforcing and
# targeted are what selinux-policy writes on a new install
if [[ -e /etc/selinux/config ]]; then
	# Move an /.autorelabel file from initial installation to writeable location
	test -f /.autorelabel && mv /.autorelabel /etc/selinux/.autorelabel
fi

if [ -e /etc/default/grub ]; then
	sed -i "s#^GRUB_CMDLINE_LINUX_DEFAULT=.*\$#GRUB_CMDLINE_LINUX_DEFAULT=\"${cmdline[*]}\"#" /etc/default/grub
else
	echo "${cmdline[*]}" > /etc/kernel/cmdline
fi

#======================================
# systemd-boot specifics
#--------------------------------------
if rpm -q sdbootutil; then
	for d in /usr/lib/modules/*; do
		test -d "$d" || continue
		depmod -a "${d##*/}"
	done
	ENTRY_TOKEN=$(. /usr/lib/os-release; echo $ID)
	mkdir -p /etc/kernel
	echo "$ENTRY_TOKEN" > /etc/kernel/entry-token
	# FIXME: kiwi needs /boot/efi to exist before syncing the disk image
	mkdir -p /boot/efi
	mkdir -p /boot/efi/loader/entries
        echo -e "LOADER_TYPE=systemd-boot\nSECURE_BOOT=yes" > /etc/sysconfig/bootloader
fi

#======================================
# Aeon specifics
#--------------------------------------

echo 'ExecStartPre=/bin/sh -c "echo 'Please wait.. setting up your computer.. this may take a few minutes'"' >> /usr/lib/dracut/modules.d/30ignition/ignition-disks.service
echo 'StandardOutput=tty' >> /usr/lib/dracut/modules.d/30ignition/ignition-disks.service

# the SELinux booleans selinuxuser_execmod, execheap and execstack are set by
# tc-benchtop-settings' post-install script

# gh#AeonDesktop/project#7
systemctl mask systemd-growfs-root.service

# Add /etc mount for final system
cat >> /etc/fstab.tik << "EOF"
/etc /etc none bind,x-initrd.mount 0 0
EOF

#======================================
# TCBL: size of what the installer copies
#--------------------------------------
# The installer's copy-progress (tik-config-benchtop) measures the bytes
# mkfs.btrfs reads against this: the apparent size of the files that
# /usr/lib/repart.d/50-root.conf copies, leaving out what its ExcludeFiles=
# leaves out.
# Measured last, so that it includes what config.sh added.
du -sbx --exclude=/tmp --exclude=/var/tmp --exclude=/boot --exclude=/mnt --exclude=/run \
    --exclude=/ignition --exclude=/var/cache/zypp --exclude=/var/cache/man --exclude=/var/log/journal \
    / | cut -f1 > /usr/share/tcbl/copy-bytes
