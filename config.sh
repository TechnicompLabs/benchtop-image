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

#======================================
# prepare for setting root pw, timezone
#--------------------------------------
echo "** reset machine settings"
rm -f /etc/machine-id \
      /var/lib/zypp/AnonymousUniqueId \
      /var/lib/systemd/random-seed

#======================================
# Specify default systemd target
#--------------------------------------
baseSetRunlevel graphical.target

#======================================
# Import trusted rpm keys
#--------------------------------------
suseImportBuildKey

#======================================
# Set hostname by DHCP
#--------------------------------------
baseUpdateSysConfig /etc/sysconfig/network/dhcp DHCLIENT_SET_HOSTNAME yes

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
# Enable chrony if installed
#-------------------------------------
if [ -f /etc/chrony.conf ]; then
	systemctl enable chronyd
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
# creates the LUKS2 root and sizes it at install time; tik enrols TPM2 or a
# passphrase plus a recovery key. The TCBL reseal module below re-seals to the
# stable PCR list 0,2,7. measure-pcr-validator.ignore=yes stays in the kernel
# cmdline (added further down) and is copied onto the target, so a stale PCR
# prediction never halts the boot even if the reseal is skipped.

#======================================
# Installer (tik) wiring
#--------------------------------------
# Autologin into the tik session off the installer USB. tik's 10-sicu module
# clears this on the installed target, so only the USB runs the installer.
if [ -e /etc/sysconfig/displaymanager ]; then
	sed -i 's/^DISPLAYMANAGER_AUTOLOGIN=.*/DISPLAYMANAGER_AUTOLOGIN="tik"/' /etc/sysconfig/displaymanager
	grep -q '^DISPLAYMANAGER_AUTOLOGIN=' /etc/sysconfig/displaymanager || echo 'DISPLAYMANAGER_AUTOLOGIN="tik"' >> /etc/sysconfig/displaymanager
else
	mkdir -p /etc/sysconfig
	echo 'DISPLAYMANAGER_AUTOLOGIN="tik"' > /etc/sysconfig/displaymanager
fi

#======================================
# Installer session: tik user + GNOME autostart (self-deploy USB only)
#--------------------------------------
# Autologin (DISPLAYMANAGER_AUTOLOGIN="tik", set above) logs the "tik" user
# into the normal GNOME session; a GNOME autostart entry then launches
# /usr/bin/tik. tik's 10-sicu post module removes all of this on the deployed
# target, so only the USB runs the installer. Mirrors the "tik specifics" block
# of devel:microos:aeon:images/Aeon config.sh, rebranded for TCBL. Requires a
# full GNOME session (gdm + gnome-shell + gnome-session-wayland) in the image.
groupadd -f wheel
useradd -m tik
usermod -aG wheel tik

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
Name=TechniComp Benchtop Linux Installer
Comment=Installs TechniComp Benchtop Linux
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

chown -R tik:users /home/tik

# tik configuration
mkdir -p /etc/tik
cat > /etc/tik/config <<'TIKCONF'
# TechniComp Benchtop Linux tik configuration
TIK_OS_NAME="TechniComp Benchtop Linux"
# Upstream default is https://aeondesktop.org/reportbug; tik reads
# /usr/lib/tik/config first and this file second, so this wins.
TIK_BUG_URL="https://github.com/TechnicompLabs/benchtop-image/issues"
# USB devices are filtered out of the install-target list by default.
TIKCONF

# repart.d layout for tik self-deployment, taken verbatim from Aeon's
# systemd-repart-branding-Aeon (00-esp.conf + 50-root.conf). The ESP is a fresh
# vfat; the root is a fresh *btrfs* whose subvolume/snapshot layout repart builds
# and then populates file-by-file with CopyFiles= from the running USB (NOT
# CopyBlocks -- a btrfs-snapshot rootfs deploys per-file), then encrypts.
# ExcludeFiles strips the tik installer artifacts (tik user, sudoers, polkit,
# /ignition) from the deployed system. No ignition partition on the target;
# Aeon's self-deploy layout has none.
mkdir -p /usr/lib/repart.d
cat > /usr/lib/repart.d/00-esp.conf <<'REPART'
[Partition]
Type=esp
Format=vfat
SizeMinBytes=750M
SizeMaxBytes=4G
MountPoint=/boot/efi
REPART
cat > /usr/lib/repart.d/50-root.conf <<'REPART'
[Partition]
Type=root
Format=btrfs
Compression=zstd
CompressionLevel=1
GrowFileSystem=off
Subvolumes=/@ /@/.snapshots /@/home /@/opt /@/root /@/srv /@/var /@/boot/writable /@/usr/local /@/boot/grub2/x86_64-efi /@/boot/grub2/i386-pc /@/.snapshots/1/snapshot:ro /@/.snapshots/1/snapshot/etc
MakeDirectories=/@ /@/.snapshots /@/.snapshots/1/snapshot /@/.snapshots/1/snapshot/etc /@/.snapshots/1/snapshot/.snapshots /@/.snapshots/1/snapshot/boot/efi /@/.snapshots/1/snapshot/boot/writable /@/.snapshots/1/snapshot/boot/grub2/x86_64-efi /@/.snapshots/1/snapshot/boot/grub2/i386-pc /@/home /@/opt /@/root /@/srv /@/var /@/boot/writable /@/usr/local /@/boot/grub2/x86_64-efi /@/boot/grub2/i386-pc
DefaultSubvolume=/@/.snapshots/1/snapshot
MountPoint=/:'compress=zstd:1',ro=vfs
MountPoint=/.snapshots:'compress=zstd:1',subvol=/@/.snapshots
MountPoint=/home:'compress=zstd:1',subvol=/@/home
MountPoint=/opt:'compress=zstd:1',subvol=/@/opt
MountPoint=/root:'compress=zstd:1',subvol=/@/root,x-initrd.mount
MountPoint=/srv:'compress=zstd:1',subvol=/@/srv
MountPoint=/var:'compress=zstd:1',subvol=/@/var,x-initrd.mount
MountPoint=/boot/writable:'compress=zstd:1',subvol=/@/boot/writable
MountPoint=/usr/local:'compress=zstd:1',subvol=/@/usr/local
MountPoint=/boot/grub2/x86_64-efi:'compress=zstd:1',subvol=/@/boot/grub2/x86_64-efi
MountPoint=/boot/grub2/i386-pc:'compress=zstd:1',subvol=/@/boot/grub2/i386-pc
ExcludeFilesTarget=/@/.snapshots/1/snapshot/.snapshots/ /@/.snapshots/1/snapshot/home/ /@/.snapshots/1/snapshot/opt/ /@/.snapshots/1/snapshot/root/ /@/.snapshots/1/snapshot/srv/ /@/.snapshots/1/snapshot/var/ /@/.snapshots/1/snapshot/boot/writable/ /@/.snapshots/1/snapshot/usr/local/ /@/.snapshots/1/snapshot/boot/grub2/x86_64-efi/ /@/.snapshots/1/snapshot/boot/grub2/i386-pc/
ExcludeFiles=/ignition /etc/sudoers.d/51-tik /etc/polkit-1/rules.d/10-tik.rules /etc/tik-firstboot /home/tik /proc/ /dev/ /sys/ /tmp/ /var/tmp/ /boot/ /mnt/ /run/
CopyFiles=/:/@/.snapshots/1/snapshot
CopyFiles=/.snapshots/1/info.xml:/@/.snapshots/1/info.xml
CopyFiles=/home:/@/home
CopyFiles=/opt:/@/opt
CopyFiles=/root:/@/root
CopyFiles=/srv:/@/srv
CopyFiles=/var:/@/var
CopyFiles=/boot/writable:/@/boot/writable
CopyFiles=/usr/local:/@/usr/local
#CopyFiles=/boot/grub2/x86_64-efi:/@/boot/grub2/x86_64-efi
#CopyFiles=/boot/grub2/i386-pc:/@/boot/grub2/i386-pc
Encrypt=key-file
REPART

# TCBL installer wallpaper (custom tik pre module). Runs after the vendored
# pre/05-setup-gnome-env (which disables the installer screen lock) and sets the
# TechniComp branded background for the tik session.
mkdir -p /etc/tik/modules/pre
cat > /etc/tik/modules/pre/50-tcbl-wallpaper <<'WALLMOD'
# SPDX-License-Identifier: MIT
# TCBL: set the TechniComp installer wallpaper (centered logo on white).
gsettings set org.gnome.desktop.background picture-uri 'file:///usr/share/backgrounds/tcbl/tcbl-installer.png' || true
gsettings set org.gnome.desktop.background picture-uri-dark 'file:///usr/share/backgrounds/tcbl/tcbl-installer.png' || true
gsettings set org.gnome.desktop.background picture-options 'zoom' || true
gsettings set org.gnome.desktop.background primary-color '#ffffff' || true
WALLMOD

# TCBL reseal module: after tik's 15-encrypt enrols TPM2 with Aeon's 4,5,7,9,
# re-seal to the stable 0,2,7 set. Runs after 15-encrypt (numbered 16), TPM
# (Default) mode only. If this step is skipped or fails the system stays on
# 4,5,7,9, but the cmdline validator-ignore still prevents any halt.
# VERIFY on a real install: tik custom-module ordering, the mount/keyfile state
# after 15-encrypt, and that a second TPM2 enrol replaces the first policy.
mkdir -p /etc/tik/modules/post
cat > /etc/tik/modules/post/16-tcbl-reseal <<'RESEAL'
# SPDX-License-Identifier: MIT
# TCBL: re-seal the TPM2 policy to the stable PCR list 0,2,7, replacing tik's
# default 4,5,7,9, so a kernel update never triggers a recovery-key prompt.
if [ "${tik_encrypt_mode}" == 0 ]; then
    tik_target_mount "" "required"
    tik_progress_step "Re-sealing TPM to stable PCRs (0,2,7)" 90
    log "[tcbl-reseal] setting FDE_SEAL_PCR_LIST=0,2,7 and re-enrolling TPM2"
    echo "FDE_SEAL_PCR_LIST=0,2,7" | prun tee "${TIK_ROOT_MNT}/etc/sysconfig/fde-tools"
    if ! prun /usr/bin/grep -q 'measure-pcr-validator.ignore=yes' "${TIK_ROOT_MNT}/etc/kernel/cmdline"; then
        prun /usr/bin/sed -i -e 's,$, measure-pcr-validator.ignore=yes,' "${TIK_ROOT_MNT}/etc/kernel/cmdline"
    fi
    prun /usr/bin/chroot "${TIK_ROOT_MNT}" sdbootutil -vv --esp-path /boot/efi --method=tpm2 enroll 1>&2
    log "[tcbl-reseal] re-seal complete"
fi
RESEAL

#======================================
# Enable NetworkManager
#--------------------------------------
systemctl enable NetworkManager

#======================================
# Enable the display manager (graphical login)
#--------------------------------------
# graphical.target is the default (baseSetRunlevel above), but the display
# manager still has to be wired in, and openSUSE makes that fiddly: it selects
# the DM via /etc/sysconfig/displaymanager and ships a generic, *symlinked*
# display-manager.service, so `systemctl enable display-manager.service` refuses
# it ("linked unit") and there is no gdm.service. Set the selector and create
# the graphical.target want by hand -- exactly what enable does under the hood.
# (Aeon gets this from systemd-presets-branding-Aeon, which TCBL dropped.)
sed -i 's/^DISPLAYMANAGER=.*/DISPLAYMANAGER="gdm"/' /etc/sysconfig/displaymanager
grep -q '^DISPLAYMANAGER=' /etc/sysconfig/displaymanager || echo 'DISPLAYMANAGER="gdm"' >> /etc/sysconfig/displaymanager
mkdir -p /etc/systemd/system/graphical.target.wants
ln -sf /usr/lib/systemd/system/display-manager.service /etc/systemd/system/graphical.target.wants/display-manager.service

#======================================
# Enable performance services
#--------------------------------------
# Source: notes Performance/Kernel Tuning.md, Memory Management.md, Storage and IO.md.
# irqbalance, systemd-zram-service (zramswap.service) and util-linux (fstrim.timer)
# come from patterns-tc-benchtop-base; rtkit and systemd-oomd (systemd-experimental)
# are pulled in via config.kiwi. The enable is guarded so a unit missing from the
# image cannot fail the set -e build.
# systemd-oomd.service is commented out in the list below: it requires
# systemd-experimental (also commented out in config.kiwi). Uncomment it
# here AND uncomment systemd-experimental in config.kiwi to enable it.
units=(
    rtkit-daemon.service
    irqbalance.service
    zramswap.service
    # systemd-oomd.service
    fstrim.timer
)
for unit in "${units[@]}"; do
    if systemctl enable "$unit"; then
        echo "TCBL: enabled $unit"
    else
        echo "TCBL: WARNING: could not enable $unit (unit not present in image)"
    fi
done

#======================================
# Enable ZYPP_SINGLE_RPMTRANS
#--------------------------------------
echo '[main]' > /usr/etc/zypp/zypp.conf.d/singletrans.conf
echo 'techpreview.ZYPP_SINGLE_RPMTRANS=1' >> /usr/etc/zypp/zypp.conf.d/singletrans.conf

#======================================
# Add default kernel boot options
#--------------------------------------
serialconsole='console=ttyS0,115200'

cmdline=('quiet' 'loglevel=2' 'systemd.show_status=0' "${serialconsole}" 'console=tty0' 'vt.global_cursor_default=0')

ignition_platform='metal'

if [ -n "${ignition_platform}" ]; then
	cmdline+=("ignition.platform.id=${ignition_platform}")
fi

#======================================
# If SELinux is installed, configure it like transactional-update setup-selinux
#--------------------------------------
if [[ -e /etc/selinux/config ]]; then
	cmdline+=("security=selinux selinux=1")
	# Adjust selinux config
	sed -i -e 's|^SELINUX=.*|SELINUX=enforcing|g' \
	    -e 's|^SELINUXTYPE=.*|SELINUXTYPE=targeted|g' \
	    "/etc/selinux/config"

	# Move an /.autorelabel file from initial installation to writeable location
	test -f /.autorelabel && mv /.autorelabel /etc/selinux/.autorelabel
fi

# Make PCR 15 validation advisory only, never a poweroff. This prevents
# the reboot-after-unlock behaviour seen on Aeon when a post-update PCR
# prediction is stale: the disk still unlocks and boot reaches the desktop.
cmdline+=("measure-pcr-validator.ignore=yes")

# Installer safety: stop systemd from auto-mounting discoverable partitions
# (root/home/var/...) or activating swap it finds on OTHER attached disks at
# boot (systemd-gpt-auto-generator). On an install target that already has
# partitions, that auto-mount holds the whole device busy and systemd-repart
# fails with "device or resource busy". A wiped disk works; this makes any
# disk work. TCBL boots from an explicit root=UUID + fstab, so it needs no
# gpt auto-discovery itself, on the USB or the installed system.
cmdline+=("systemd.gpt_auto=no")

# Performance tuning (Source: notes Performance/Kernel Tuning.md, Storage and IO.md).
# Full preemption, threaded IRQs and RCU no-callback/lazy for desktop latency;
# disable the NMI/hardware watchdog; skip staggered SATA spin-up at boot.
cmdline+=("preempt=full")
cmdline+=("threadirqs")
cmdline+=("rcu_nocbs=all")
# rcutree.enable_rcu_lazy is a no-op unless the kernel is built with
# CONFIG_RCU_LAZY=y, which the SUSE kernel configs (Tumbleweed stable,
# SL-16.0, SL-16.1) do not set. Harmless: unknown dotted parameters are
# ignored. rcu_nocbs=all still offloads callbacks. Kept so the parameter is
# in place if a CONFIG_RCU_LAZY kernel is adopted.
cmdline+=("rcutree.enable_rcu_lazy=1")
cmdline+=("nowatchdog")
# Redundant with nowatchdog (which disables both lockup detectors); kept
# explicit.
cmdline+=("nmi_watchdog=0")
cmdline+=("libahci.ignore_sss=1")

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

setsebool -P selinuxuser_execmod 1
setsebool -P selinuxuser_execheap 1
setsebool -P selinuxuser_execstack 1

# gh#AeonDesktop/project#7
systemctl mask systemd-growfs-root.service

# Add /etc mount for final system
cat >> /etc/fstab.tik << "EOF"
/etc /etc none bind,x-initrd.mount 0 0
EOF

#======================================

# NOTE (TCBL): the Aeon tik-installer user block was intentionally dropped for
# this minimal image. Deploy by writing the raw image to disk; ignition handles
# first boot. The tik GUI installer + branding are a follow-up packaging task.
