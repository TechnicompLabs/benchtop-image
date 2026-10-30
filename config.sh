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

# TCBL OS branding: rebrand os-release NAME/PRETTY_NAME so the installed system
# identifies as Technicomp Benchtop Linux (GNOME Tour/About, etc.). ID is left at
# the base openSUSE value so tooling and the sdbootutil entry token keep working.
if [ -f /usr/lib/os-release ]; then
    sed -i -e 's/^NAME=.*/NAME="Technicomp Benchtop Linux"/' \
           -e 's/^PRETTY_NAME=.*/PRETTY_NAME="Technicomp Benchtop Linux"/' \
           /usr/lib/os-release
fi

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

mkdir -p /usr/libexec/tcbl
cat > /usr/libexec/tcbl/create-user << "EOF"
#!/bin/bash
# SPDX-License-Identifier: MIT
# TCBL live USB: create an administrator account for the "Create User" session,
# then hide "Create User" from the login screen. Runs as root via sudo (see
# /etc/sudoers.d/52-tcbl-newuser). Reads three lines on stdin: username, full
# name, password. Exit status: 0 created, 2 invalid input, 3 username in use.
set -euo pipefail
PATH=/usr/sbin:/usr/bin:/sbin:/bin

IFS= read -r username
IFS= read -r fullname
IFS= read -r password || [ -n "${password}" ]

[[ "${username}" =~ ^[a-z][a-z0-9_-]{0,31}$ ]] || exit 2
[[ -n "${fullname}" && ${#fullname} -le 128 && "${fullname}" != *[:[:cntrl:]]* ]] || exit 2
[ -n "${password}" ] || exit 2
if getent passwd "${username}" > /dev/null; then
	exit 3
fi

accounts=(org.freedesktop.Accounts /org/freedesktop/Accounts org.freedesktop.Accounts)

# Create the account the way GNOME Settings and GNOME Initial Setup do: through
# AccountsService, as an administrator (account type 1).
busctl call "${accounts[@]}" CreateUser ssi "${username}" "${fullname}" 1 > /dev/null
printf '%s:%s\n' "${username}" "${password}" | chpasswd

# Hide "Create User": lock tcbl-newuser through AccountsService. GNOME's login
# screen drops locked accounts from its list, including while it is running.
read -r _ path < <(busctl call "${accounts[@]}" FindUserByName s tcbl-newuser)
busctl call org.freedesktop.Accounts "${path//\"/}" org.freedesktop.Accounts.User SetLocked b true
EOF

cat > /usr/libexec/tcbl/create-user-dialog << "EOF"
#!/bin/bash
# SPDX-License-Identifier: MIT
# TCBL live USB: the "Create User" session. Asks for the new account's details,
# creates it through /usr/libexec/tcbl/create-user, then logs out so the new
# account can be chosen on the login screen. Cancelling also logs out.
title="Create User"

end_session() {
	gnome-session-quit --logout --no-prompt || loginctl terminate-user "$(id -un)"
	exit 0
}

while true; do
	form=$(zenity --forms --title="${title}" --width=440 \
		--text="Create an account for using Technicomp Benchtop Linux from this USB drive. Any system installed from this drive will include it." \
		--separator=$'\n' \
		--add-entry="Full name" --add-entry="Username" \
		--add-password="Password" --add-password="Confirm password") || end_session
	mapfile -t field <<< "${form}"
	fullname=${field[0]:-}
	username=${field[1]:-}
	password=${field[2]:-}
	confirm=${field[3]:-}

	problem=""
	if [ -z "${fullname}" ] || [[ "${fullname}" == *:* ]]; then
		problem="Enter a full name. It cannot contain a colon."
	elif ! [[ "${username}" =~ ^[a-z][a-z0-9_-]{0,31}$ ]]; then
		problem="Enter a username of up to 32 characters: lowercase letters, digits, hyphens and underscores, starting with a letter."
	elif getent passwd "${username}" > /dev/null; then
		problem="The username ${username} is already in use."
	elif [ -z "${password}" ]; then
		problem="Enter a password."
	elif [ "${password}" != "${confirm}" ]; then
		problem="The passwords do not match."
	fi
	if [ -n "${problem}" ]; then
		zenity --error --no-markup --title="${title}" --text="${problem}"
		continue
	fi

	if printf '%s\n%s\n%s\n' "${username}" "${fullname}" "${password}" | sudo -n /usr/libexec/tcbl/create-user; then
		zenity --info --no-markup --title="${title}" --text="The account for ${fullname} is ready. Choose it on the login screen to start using it."
		end_session
	fi
	zenity --error --no-markup --title="${title}" --text="The account could not be created."
done
EOF
chmod 0755 /usr/libexec/tcbl/create-user /usr/libexec/tcbl/create-user-dialog

# tik configuration
mkdir -p /etc/tik
cat > /etc/tik/config <<'TIKCONF'
# Technicomp Benchtop Linux tik configuration
TIK_OS_NAME="Technicomp Benchtop Linux"
# Upstream default is https://aeondesktop.org/reportbug; tik reads
# /usr/lib/tik/config first and this file second, so this wins.
TIK_BUG_URL="https://github.com/TechnicompLabs/benchtop-image/issues"
# USB devices are filtered out of the install-target list by default.
# Name of the unlocked root device (/dev/mapper/benchtop_root, /etc/crypttab).
# Without it, tik derives the name from TIK_OS_NAME, as
# technicomp_benchtop_linux_root. The root partition carries the same name as
# its label (repart.d/50-root.conf below), so the text password prompt at boot
# names the disk once, as benchtop_root.
TIK_CRYPT_MAPPER="benchtop_root"
TIKCONF

# repart.d layout for tik self-deployment, taken verbatim from Aeon's
# systemd-repart-branding-Aeon (00-esp.conf + 50-root.conf). The ESP is a fresh
# vfat; the root is a fresh *btrfs* whose subvolume/snapshot layout repart builds
# and then populates file-by-file with CopyFiles= from the running USB (NOT
# CopyBlocks -- a btrfs-snapshot rootfs deploys per-file), then encrypts.
# ExcludeFiles strips the tik installer artifacts (tik user, sudoers, polkit,
# /ignition) from the deployed system. No ignition partition on the target;
# Aeon's self-deploy layout has none. TCBL addition: Label=benchtop_root names
# the root partition and its file system (systemd-repart's default is
# root-x86-64); it matches TIK_CRYPT_MAPPER in the tik configuration above.
#
# TCBL: discard=async on every MountPoint=. systemd-repart's --generate-fstab
# puts a plain "discard" in front of the options given here, and on Btrfs that
# is synchronous discard, which trims every freed extent at once and made an
# installed system stall (systemd issue 38829). Btrfs applies the discard
# options in order, so the later discard=async wins; it is also the kernel's
# own default for Btrfs on devices that support discard.
#
# TCBL: ExcludeFiles also leaves out the live session's zypper and man caches
# and its journal (the directories are kept), which the installed system
# rebuilds or starts afresh.
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
Label=benchtop_root
Format=btrfs
Compression=zstd
CompressionLevel=1
GrowFileSystem=off
Subvolumes=/@ /@/.snapshots /@/home /@/opt /@/root /@/srv /@/var /@/boot/writable /@/usr/local /@/boot/grub2/x86_64-efi /@/boot/grub2/i386-pc /@/.snapshots/1/snapshot:ro /@/.snapshots/1/snapshot/etc
MakeDirectories=/@ /@/.snapshots /@/.snapshots/1/snapshot /@/.snapshots/1/snapshot/etc /@/.snapshots/1/snapshot/.snapshots /@/.snapshots/1/snapshot/boot/efi /@/.snapshots/1/snapshot/boot/writable /@/.snapshots/1/snapshot/boot/grub2/x86_64-efi /@/.snapshots/1/snapshot/boot/grub2/i386-pc /@/home /@/opt /@/root /@/srv /@/var /@/boot/writable /@/usr/local /@/boot/grub2/x86_64-efi /@/boot/grub2/i386-pc
DefaultSubvolume=/@/.snapshots/1/snapshot
MountPoint=/:'compress=zstd:1',ro=vfs,discard=async
MountPoint=/.snapshots:'compress=zstd:1',subvol=/@/.snapshots,discard=async
MountPoint=/home:'compress=zstd:1',subvol=/@/home,discard=async
MountPoint=/opt:'compress=zstd:1',subvol=/@/opt,discard=async
MountPoint=/root:'compress=zstd:1',subvol=/@/root,x-initrd.mount,discard=async
MountPoint=/srv:'compress=zstd:1',subvol=/@/srv,discard=async
MountPoint=/var:'compress=zstd:1',subvol=/@/var,x-initrd.mount,discard=async
MountPoint=/boot/writable:'compress=zstd:1',subvol=/@/boot/writable,discard=async
MountPoint=/usr/local:'compress=zstd:1',subvol=/@/usr/local,discard=async
MountPoint=/boot/grub2/x86_64-efi:'compress=zstd:1',subvol=/@/boot/grub2/x86_64-efi,discard=async
MountPoint=/boot/grub2/i386-pc:'compress=zstd:1',subvol=/@/boot/grub2/i386-pc,discard=async
ExcludeFilesTarget=/@/.snapshots/1/snapshot/.snapshots/ /@/.snapshots/1/snapshot/home/ /@/.snapshots/1/snapshot/opt/ /@/.snapshots/1/snapshot/root/ /@/.snapshots/1/snapshot/srv/ /@/.snapshots/1/snapshot/var/ /@/.snapshots/1/snapshot/boot/writable/ /@/.snapshots/1/snapshot/usr/local/ /@/.snapshots/1/snapshot/boot/grub2/x86_64-efi/ /@/.snapshots/1/snapshot/boot/grub2/i386-pc/
ExcludeFiles=/ignition /etc/sudoers.d/51-tik /etc/polkit-1/rules.d/10-tik.rules /etc/tik-firstboot /home/tik /proc/ /dev/ /sys/ /tmp/ /var/tmp/ /boot/ /mnt/ /run/ /var/cache/zypp/ /var/cache/man/ /var/log/journal/
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

# TCBL installer fix: start the self-deploy from a blank, settled disk (custom
# tik pre module). See the module header for the full rationale.
mkdir -p /etc/tik/modules/pre
cat > /etc/tik/modules/pre/90-tcbl-repart-prep <<'PREPMOD'
# SPDX-License-Identifier: MIT
# TCBL: start the self-deploy from a blank, settled disk.
#
# On a disk that still holds partitions from a previous install, systemd-repart
# fails with "Failed to create new partition '<disk>p1': Device or resource
# busy": after repart wipes the old table, the kernel still has the old
# partitions registered for a moment while udev re-reads the disk. A blank disk
# never hits this.
#
# So before repart runs, wipefs erases the old partition table and has the
# kernel re-read it (util-linux retries that re-read itself when udev briefly
# holds the disk), and udevadm settle waits for udev to finish. repart then
# starts from the same state as a freshly wiped disk and runs once, unchanged.
#
# tik has no hook between its "erase the disk?" confirmation and repart, so this
# redefines dump_image_repart_self from tik-core-helper (tik loads its helpers
# before modules, so this definition wins). It is upstream's function plus the
# lines marked TCBL. Re-sync if a tik update changes that function.
#
# TCBL, in the same function because it is the step that follows the "erase
# the disk?" confirmation:
# - mkfs.btrfs runs without its own discard. With --empty=force,
#   systemd-repart has already discarded the whole disk, but it still has
#   mkfs.btrfs discard the new, encrypted root again (its "discard only once"
#   check counts only per-partition discards); on a large disk that is the
#   likely cause of a pause of several minutes, with nothing read or written,
#   at the start of the copy. $SYSTEMD_REPART_MKFS_OPTIONS_BTRFS is
#   systemd-repart's documented way to pass options to mkfs.btrfs; pkexec
#   clears the environment, hence env.
# - repart's messages go to tik's log instead of a dialog that does not show
#   them, and two windows replace upstream's "Deploying OS Image" bar: the
#   installation details (tik's log, as it grows, for the rest of the
#   installation) and the copy's progress (copy-progress, below).
dump_image_repart_self() {
    local image_target=$1
    create_keyfile
    prun-opt rm -rf /etc/fstab.repart
    log "[dump_image_repart_self] self-deploying"
    prun /usr/sbin/wipefs --all "${image_target}"    # TCBL
    prun-opt udevadm settle --timeout=30             # TCBL
    tcbl_show_details                                # TCBL
    tcbl_copy_progress_start                         # TCBL
    prun /usr/bin/env SYSTEMD_REPART_MKFS_OPTIONS_BTRFS=--nodiscard systemd-repart --no-pager --pretty=0 --empty=force --dry-run=no --key-file="${tik_keyfile}" --generate-fstab=/etc/fstab.repart "${image_target}" 1>&2    # TCBL: mkfs.btrfs option, output to the log
    tcbl_copy_progress_wait                          # TCBL
}

# TCBL: a window that follows tik's log for the rest of the installation. It
# closes when the installation ends (the system restarts, or after a failure
# the session ends) or when it is closed, which does not affect the
# installation.
tcbl_show_details() {
    $gui || return 0
    [ -n "${tcbl_details_pid}" ] && return 0
    (tail -n +1 -F "${tik_log}" 2>/dev/null | zenity --text-info --title="Installation Details" --auto-scroll --width=800 --height=450 --ok-label="Hide") >/dev/null 2>&1 &
    tcbl_details_pid=$!
    log "[tcbl-details] showing the installation details"
}

# TCBL: the copy's progress, from the bytes mkfs.btrfs has read against the
# size of the system that is copied, which config.sh records when the image is
# built. copy-progress reads mkfs.btrfs's I/O counters, so it runs as root, once.
tcbl_copy_progress_start() {
    tcbl_copy_pid=""
    $gui || return 0
    (pkexec /usr/libexec/tcbl/copy-progress | zenity --progress --title="Installing ${TIK_OS_NAME}" --text="Preparing the disk" --percentage=0 --auto-close --no-cancel --width=450) >/dev/null 2>&1 &
    tcbl_copy_pid=$!
}

tcbl_copy_progress_wait() {
    [ -n "${tcbl_copy_pid}" ] && wait "${tcbl_copy_pid}"
    tcbl_copy_pid=""
}
PREPMOD

# TCBL: copy-progress (see tcbl_copy_progress_start above) and the size it
# measures against. Prints zenity --progress lines while systemd-repart runs:
# a percentage and the amount copied and the time taken, while mkfs.btrfs
# copies the system into the new file system.
mkdir -p /usr/libexec/tcbl /usr/share/tcbl
cat > /usr/libexec/tcbl/copy-progress <<'COPYPROGRESS'
#!/bin/bash
# SPDX-License-Identifier: MIT
total="$(cat /usr/share/tcbl/copy-bytes 2>/dev/null)"
[[ "${total}" =~ ^[0-9]+$ ]] && [ "${total}" -gt 0 ] || total=0
start=${SECONDS}

gb() { awk -v b="$1" 'BEGIN { printf "%.1f GB", b / 1e9 }'; }
elapsed() { local s=$(( SECONDS - start )); printf '%d:%02d' $(( s / 60 )) $(( s % 60 )); }

# Wait for mkfs.btrfs, as long as systemd-repart is running
pid=""
while [ -z "${pid}" ]; do
    pgrep -x systemd-repart > /dev/null || { echo 100; exit 0; }
    pid="$(pgrep -n -x mkfs.btrfs)" && break
    echo "# Preparing the disk ($(elapsed))"
    sleep 2
done

# Follow the bytes it reads
while [ -r "/proc/${pid}/io" ]; do
    read_bytes="$(awk '/^rchar:/ { print $2 }' "/proc/${pid}/io" 2>/dev/null)"
    [ -n "${read_bytes}" ] || break
    if [ "${total}" -gt 0 ]; then
        percent=$(( read_bytes * 100 / total ))
        [ "${percent}" -gt 99 ] && percent=99
        echo "${percent}"
        echo "# Copying the system: $(gb "${read_bytes}") of about $(gb "${total}") ($(elapsed))"
    else
        echo "# Copying the system: $(gb "${read_bytes}") ($(elapsed))"
    fi
    sleep 2
done

# Until systemd-repart has finished
while pgrep -x systemd-repart > /dev/null; do
    echo 99
    echo "# Finishing the disk ($(elapsed))"
    sleep 2
done
echo 100
COPYPROGRESS
chmod 0755 /usr/libexec/tcbl/copy-progress

# TCBL live-USB tik modules. 01-tcbl-exit, 06-tcbl-wallpaper,
# 12-tcbl-machine-id, 13-tcbl-no-memtest and 14-tcbl-package-sets must run
# before particular vendored modules (10-welcome, 15-encrypt), and tik loads
# /usr/lib/tik/modules/<phase> before /etc/tik/modules/<phase>, so those five
# sit beside the vendored modules. 20-tcbl-package-sets, 22-tcbl-hostname,
# 17-tcbl-live-cleanup, 18-tcbl-hostname and 19-tcbl-autorelabel have no
# ordering need.
mkdir -p /usr/lib/tik/modules/pre /usr/lib/tik/modules/post
cat > /usr/lib/tik/modules/pre/01-tcbl-exit <<'EXITMOD'
# SPDX-License-Identifier: MIT
# TCBL: when the installer is cancelled or fails, return to the login screen
# instead of powering off, since the USB may also be in use as a live system.
# Redefines cleanup() from /usr/bin/tik: tik runs it from its EXIT trap, which
# looks the function up when it fires, so this definition replaces upstream's.
# Upstream's failure branch shows a second "Installation Failed" dialog and
# powers off; error() has already shown the specific error by then, and a
# cancel has already been confirmed. Lines marked TCBL differ from upstream;
# re-sync the rest if tik's cleanup() changes.
cleanup() {
    retval=$?
    log "[STOP][${retval}] $0"
    if [ "${debug}" == "1" ]; then
        d --timeout 5 --info --no-wrap --text="<b>Test Succeeded:</b>\n\nHave a nice day!"
    elif [ "${retval}" == "0" ]; then
        d --timeout 5 --info --no-wrap --title="Installation Complete!" --text="${TIK_OS_NAME} has been installed.\n\n<b>System is rebooting</b>"
        prun systemctl reboot --force
    else
        tik_cleanup_mounts                     # TCBL: release the target disk so a retry works
        cp -a ${tik_log} /ignition
        loginctl terminate-user "$(id -un)"    # TCBL: back to the login screen, not poweroff
    fi
}
EXITMOD

cat > /usr/lib/tik/modules/pre/06-tcbl-wallpaper <<'WALLPAPERMOD'
# SPDX-License-Identifier: MIT
# TCBL: the installer's desktop shows the navy board background
# (tc-benchtop-board.png, from tc-benchtop-branding) in both the light and the
# dark style. Like 05-setup-gnome-env, this sets the installer account's own
# GNOME settings, so installed systems and accounts made with "Create User"
# keep the default backgrounds. Runs before 10-welcome, so the background is
# in place when the first dialog appears.
tcbl_board="file:///usr/share/backgrounds/tc-benchtop/tc-benchtop-board.png"
log "[tcbl-wallpaper] installer background: ${tcbl_board}"
gsettings set org.gnome.desktop.background picture-uri "${tcbl_board}"
gsettings set org.gnome.desktop.background picture-uri-dark "${tcbl_board}"
gsettings set org.gnome.desktop.background primary-color '#141e33'
WALLPAPERMOD

cat > /usr/lib/tik/modules/post/12-tcbl-machine-id <<'IDMOD'
# SPDX-License-Identifier: MIT
# TCBL: give the installed system its own identity. The installer copies /etc
# and /var from the running USB, so every system installed from one USB would
# otherwise share the USB's machine ID. Resets the same per-machine files that
# config.sh deletes at image build time. Runs after 10-sicu (target mounted)
# and before 15-encrypt, so the initrd built there carries the new machine ID.
# Boot entries are unaffected: sdbootutil names them from
# /etc/kernel/entry-token (the OS ID), not from the machine ID.
tik_target_mount "" "required"
tik_progress_step "Generating a machine ID" 0
new_machine_id="$(systemd-id128 new)"
[[ "${new_machine_id}" =~ ^[0-9a-f]{32}$ ]] || error "Could not generate a machine ID"
log "[tcbl-machine-id] writing a new machine ID; clearing the random seed and zypp ID"
prun /usr/bin/tee "${TIK_ROOT_MNT}/etc/machine-id" <<< "${new_machine_id}" > /dev/null
prun /usr/bin/rm -f "${TIK_ROOT_MNT}/var/lib/systemd/random-seed" "${TIK_ROOT_MNT}/var/lib/zypp/AnonymousUniqueId"
tik_progress_step "Machine ID generated" 100
IDMOD

cat > /usr/lib/tik/modules/post/13-tcbl-no-memtest <<'MEMTESTMOD'
# SPDX-License-Identifier: MIT
# TCBL: memtest86+ is in the installer USB's boot menu only. The image carries
# memtest86+-bls, whose /usr/lib/sdbootutil/entries.d/memtest86+.conf would
# also put memtest86+ in the installed system's boot menu. A file of the same
# name in /etc/sdbootutil/entries.d replaces it, and this one has no EFI= line,
# so sdbootutil installs nothing for it. Runs before 15-encrypt, whose
# `sdbootutil install` fills the installed system's ESP. To offer memtest86+
# on an installed system, delete the file and run `sdbootutil update`.
tik_target_mount "" "required"
log "[tcbl-no-memtest] masking the memtest86+ boot entry on the installed system"
prun /usr/bin/mkdir -p "${TIK_ROOT_MNT}/etc/sdbootutil/entries.d"
prun /usr/bin/tee "${TIK_ROOT_MNT}/etc/sdbootutil/entries.d/memtest86+.conf" <<< "# TCBL: no memtest86+ boot entry on installed systems (see /usr/lib/sdbootutil/entries.d/memtest86+.conf)" > /dev/null
MEMTESTMOD

cat > /usr/lib/tik/modules/post/14-tcbl-package-sets <<'SETSPOSTMOD'
# SPDX-License-Identifier: MIT
# TCBL: install the optional package sets chosen in the pre module
# 20-tcbl-package-sets (/etc/tik/modules/pre). Runs before 15-encrypt, so the
# boot entries, initrd and TPM policy that 15-encrypt creates cover the final
# system.
#
# transactional-update cannot install into another disk: it rejects --root,
# tukit has no option for another root, and in tik's chroot tukit would reach
# the USB's own snapper through the D-Bus socket in the bind-mounted /run.
# Instead, this installs into the new system's first snapshot before that
# system has ever booted, the way the image build installs packages: the
# snapshot is made writable, zypper installs into it with --root (as
# transactional-update runs zypper into its new snapshot), and the snapshot is
# made read-only again. Packages are downloaded first, so a lost connection
# leaves the snapshot unchanged. Recommended packages stay out, as in the
# image.

# Reads zypper's output: logs each line and shows it in tik's progress
# dialog, mapping zypper's (n/N) counter onto module percentages $1 to $2.
# tik's own log lines (from prun-opt) go straight to the log.
tcbl_sets_progress() {
    local from=$1 to=$2 line percent=$1
    while IFS= read -r line; do
        if [[ "${line}" == "["*"][LOG] "* ]]; then
            echo "${line}" >&2
            continue
        fi
        log "[tcbl-package-sets] ${line}"
        if [[ "${line}" =~ \(\ *([0-9]+)/([0-9]+)\) ]] && [ "${BASH_REMATCH[2]}" -gt 0 ]; then
            percent=$(( from + (to - from) * BASH_REMATCH[1] / BASH_REMATCH[2] ))
        fi
        line="${line//[<>&]/}"
        tik_progress_step "${line:0:100}" "${percent}"
    done
}

# Runs zypper on the new system with its output in tik's progress dialog,
# between module percentages $1 and $2. Sets retval to zypper's exit code.
tcbl_sets_zypper() {
    local from=$1 to=$2 fifo reader
    shift 2
    fifo="$(mktemp -u /tmp/tcbl-package-sets-fifo.XXXXXXXXXX)"
    mkfifo "${fifo}"
    tcbl_sets_progress "${from}" "${to}" < "${fifo}" &
    reader=$!
    retval=0
    prun-opt /usr/bin/env ZYPP_LOCK_TIMEOUT=300 /usr/bin/zypper --root "${TIK_ROOT_MNT}" --non-interactive "$@" > "${fifo}" 2>&1
    wait "${reader}"
    rm -f "${fifo}"
}

if [ -n "${tcbl_package_sets}" ]; then
    read -r -a tcbl_sets <<< "${tcbl_package_sets}"
    tik_target_mount "" "required"
    tik_progress_step "Preparing the optional software" 0
    log "[tcbl-package-sets] making the first snapshot writable to install ${tcbl_package_sets}"
    prun /usr/sbin/btrfs property set -t subvol "${TIK_ROOT_MNT}" ro false

    tcbl_sets_status=""
    while [ -z "${tcbl_sets_status}" ]; do
        tcbl_sets_zypper 0 50 install --download-only --no-recommends --auto-agree-with-licenses "${tcbl_sets[@]}"
        if [ "${retval}" = "0" ]; then
            tcbl_sets_status="downloaded"
        else
            log "[tcbl-package-sets] download failed (${retval})"
            if ! d_opt --question --no-wrap --title="Optional Software" --ok-label="Try Again" --cancel-label="Continue Without It" \
                --text="The optional software could not be downloaded.\n\nCheck the network connection and try again, or continue without it. It can be installed later with\n<tt>sudo transactional-update pkg install ${tcbl_package_sets}</tt>"; then
                tcbl_sets_status="skipped"
            fi
        fi
    done

    if [ "${tcbl_sets_status}" = "downloaded" ]; then
        tcbl_sets_zypper 50 95 install --no-recommends --auto-agree-with-licenses "${tcbl_sets[@]}"
        case "${retval}" in
            # 102 and 103: a reboot or restart is advised; 107: a package
            # script failed, but the packages are installed
            0|102|103|107)
                tcbl_sets_status="installed"
                ;;
            *)
                tcbl_sets_status="failed"
                ;;
        esac
    fi

    # Remove the downloaded packages from the new system's cache
    tcbl_sets_zypper 95 95 clean
    prun /usr/sbin/btrfs property set -t subvol "${TIK_ROOT_MNT}" ro true
    log "[tcbl-package-sets] ${tcbl_sets_status}: ${tcbl_package_sets}"

    if [ "${tcbl_sets_status}" = "failed" ]; then
        d --warning --no-wrap --title="Optional Software" \
            --text="The optional software could not be installed completely.\n\nIt can be installed later with\n<tt>sudo transactional-update pkg install ${tcbl_package_sets}</tt>"
    fi
    tik_progress_step "Optional software finished" 100
fi
SETSPOSTMOD

cat > /etc/tik/modules/pre/20-tcbl-package-sets <<'SETSPREMOD'
# SPDX-License-Identifier: MIT
# TCBL: optional package sets. The image installs patterns-tc-benchtop-base;
# this offers patterns-tc-benchtop-languages and patterns-tc-benchtop-admin,
# which the post module 14-tcbl-package-sets installs into the new system.
# Before the disk is erased, it refreshes the software sources and resolves
# the chosen sets against the running USB system, which is what gets
# installed, so a missing network connection or a set that cannot be
# installed shows up here, together with the download and disk space the sets
# need. Keep the list in step with patterns-tc-benchtop.spec. zenity's
# checklist has no console (cenity) equivalent, so an installation without a
# graphical session does not offer the sets.

tcbl_package_sets=""
tcbl_sets_xml=""

tcbl_sets_gb() {
    if [ -n "$1" ]; then
        awk -v bytes="$1" 'BEGIN { printf "%.1f GB", bytes / 1e9 }'
    else
        echo "unknown"
    fi
}

# Refreshes the software sources and resolves the chosen sets, showing a busy
# dialog. Sets retval: 0 when the sets can be installed, 200 when the sources
# could not be refreshed, zypper's exit code otherwise. Leaves zypper's XML
# summary in ${tcbl_sets_xml}.
tcbl_sets_check() {
    local fifo busy sets
    rm -f "${tcbl_sets_xml}"
    tcbl_sets_xml="$(mktemp /tmp/tcbl-package-sets.XXXXXXXXXX)"
    fifo="$(mktemp -u /tmp/tcbl-package-sets-fifo.XXXXXXXXXX)"
    mkfifo "${fifo}"
    d --progress --title="Optional Software" --text="Checking the software sources" --pulsate --auto-close --no-cancel --width=400 < "${fifo}" &
    busy=$!
    exec {tcbl_sets_fd}> "${fifo}"
    read -r -a sets <<< "${tcbl_package_sets}"
    retval=0
    prun-opt /usr/bin/env ZYPP_LOCK_TIMEOUT=300 /usr/bin/sh -c 'zypper --non-interactive refresh --services >&2 || exit 200
exec zypper --xmlout --non-interactive install --dry-run --no-recommends --auto-agree-with-licenses "$@"' sh "${sets[@]}" > "${tcbl_sets_xml}"
    exec {tcbl_sets_fd}>&-
    wait "${busy}"
    rm -f "${fifo}"
}

tcbl_sets_ask() {
    local name message download space
    while true; do
        d --list --checklist --width=900 --height=300 --title="Optional Software" --ok-label="Continue" \
            --text="${TIK_OS_NAME} installs its base system. These sets can be installed with it. They are downloaded during the installation, so this computer needs a network connection.\n\nThey can also be added or removed later." \
            --column="Install" --column="Package" --column="Software" --column="Includes" \
            --hide-column=2 --print-column=2 --separator=" " \
            FALSE patterns-tc-benchtop-languages "Programming languages" "Clang, Python, Ruby, Java, Go, Rust, Node.js, PHP, R, Haskell, OCaml and more" \
            FALSE patterns-tc-benchtop-admin "Remote administration and servers" "Cockpit, the Samba and NFS servers, Ansible, OpenTofu, Kubernetes tools, database clients"
        tcbl_package_sets=""
        for name in ${result}; do
            case "${name}" in
                patterns-tc-benchtop-languages|patterns-tc-benchtop-admin)
                    tcbl_package_sets="${tcbl_package_sets:+${tcbl_package_sets} }${name}"
                    ;;
            esac
        done
        if [ -z "${tcbl_package_sets}" ]; then
            log "[tcbl-package-sets] no optional sets chosen"
            return 0
        fi

        while true; do
            tcbl_sets_check
            case "${retval}" in
                0)
                    break
                    ;;
                200)
                    message="The software sources cannot be reached.\n\nConnect to a network with the menu in the top right corner of the screen, then try again."
                    ;;
                *)
                    message="The selected software cannot be installed at the moment.\n\n${TIK_OS_NAME} can be installed without it, and it can be added later."
                    ;;
            esac
            log "[tcbl-package-sets] check failed (${retval})"
            if ! d_opt --question --no-wrap --title="Optional Software" --ok-label="Try Again" --cancel-label="Continue Without It" --text="${message}"; then
                log "[tcbl-package-sets] continuing without the optional sets"
                tcbl_package_sets=""
                rm -f "${tcbl_sets_xml}"
                return 0
            fi
        done

        download="$(grep -o 'download-size="[0-9]*"' "${tcbl_sets_xml}" | grep -o '[0-9][0-9]*' | head -n 1)"
        space="$(grep -o 'space-usage-diff="[0-9]*"' "${tcbl_sets_xml}" | grep -o '[0-9][0-9]*' | head -n 1)"
        rm -f "${tcbl_sets_xml}"
        if d_opt --question --no-wrap --title="Optional Software" --ok-label="Continue" --cancel-label="Change Selection" \
            --text="The selected software is downloaded and installed during the installation.\n\nDownload: <b>$(tcbl_sets_gb "${download}")</b>\nDisk space: <b>$(tcbl_sets_gb "${space}")</b>\n\nKeep this computer connected to the network until the installation is complete."; then
            log "[tcbl-package-sets] chosen: ${tcbl_package_sets} (download ${download:-unknown} bytes, disk space ${space:-unknown} bytes)"
            return 0
        fi
    done
}

if $gui; then
    tcbl_sets_ask
else
    log "[tcbl-package-sets] no graphical session, not offering the optional sets"
fi
SETSPREMOD

cat > /etc/tik/modules/pre/22-tcbl-hostname <<'HOSTPREMOD'
# SPDX-License-Identifier: MIT
# TCBL: ask for the installed system's host name, which the post module
# 18-tcbl-hostname writes to /etc/hostname. That makes it the static host
# name, so NetworkManager does not replace it with a name from DHCP. A host
# name here is one label: letters, digits and hyphens, up to 63 characters,
# not starting or ending with a hyphen, stored in lowercase. The console
# (cenity) entry has no default text, so there the name has to be typed.
tcbl_hostname=""
while true; do
    d --entry --title="Computer Name" --width=500 --entry-text="benchtop" \
        --text="Choose a name for this computer. It identifies the computer on the network.\n\nUse letters, digits and hyphens, up to 63 characters."
    tcbl_hostname="${result,,}"
    if [[ "${tcbl_hostname}" =~ ^[a-z0-9]([a-z0-9-]{0,61}[a-z0-9])?$ ]] && [ "${tcbl_hostname}" != "localhost" ]; then
        log "[tcbl-hostname] chosen: ${tcbl_hostname}"
        break
    fi
    log "[tcbl-hostname] rejected: ${result}"
    d --warning --no-wrap --title="Computer Name" \
        --text="<b>${result//[<>&]/}</b> cannot be used as a computer name.\n\nUse letters, digits and hyphens, up to 63 characters, not starting or ending with a hyphen."
done
HOSTPREMOD

mkdir -p /etc/tik/modules/post
cat > /etc/tik/modules/post/17-tcbl-live-cleanup <<'CLEANMOD'
# SPDX-License-Identifier: MIT
# TCBL: remove the live USB's login-screen setup from the installed system.
# 10-sicu removes the tik account; this removes the "Create User" account, its
# sudo rule, the passwordless GDM login rule and both accounts' AccountsService
# records. Accounts made with "Create User" are kept. It also removes the live
# session's log files, which the installer copies with /var (its caches and
# journal are not copied; see ExcludeFiles in repart.d/50-root.conf). Log
# directories are kept, since packages own them, and so is
# /var/log/zypp/history, which records the optional sets that
# 14-tcbl-package-sets installed.
tik_target_mount "" "required"
tik_progress_step "Removing live USB accounts" 0
log "[tcbl-live-cleanup] removing tcbl-newuser, its sudo rule and the passwordless GDM rule"
prun /usr/bin/chroot "${TIK_ROOT_MNT}" userdel -r tcbl-newuser
prun /usr/bin/rm -f "${TIK_ROOT_MNT}/etc/sudoers.d/52-tcbl-newuser" \
    "${TIK_ROOT_MNT}/var/lib/AccountsService/users/tik" \
    "${TIK_ROOT_MNT}/var/lib/AccountsService/users/tcbl-newuser" \
    "${TIK_ROOT_MNT}/var/lib/AccountsService/icons/tik" \
    "${TIK_ROOT_MNT}/var/lib/AccountsService/icons/tcbl-newuser"
# config.sh made /etc/pam.d/gdm-password as a copy of the packaged
# /usr/lib/pam.d/gdm-password plus the rule, so deleting the copy restores the
# packaged file. Only delete it if it is TCBL's copy.
prun-opt /usr/bin/grep -q 'user in tik:tcbl-newuser' "${TIK_ROOT_MNT}/etc/pam.d/gdm-password"
if [ "${retval}" = "0" ]; then
    prun /usr/bin/rm -f "${TIK_ROOT_MNT}/etc/pam.d/gdm-password"
fi
log "[tcbl-live-cleanup] removing the live session's log files"
prun /usr/bin/find "${TIK_ROOT_MNT}/var/log" -xdev -type f ! -path "${TIK_ROOT_MNT}/var/log/zypp/history" -delete
tik_progress_step "Live USB accounts removed" 100
CLEANMOD

cat > /etc/tik/modules/post/18-tcbl-hostname <<'HOSTPOSTMOD'
# SPDX-License-Identifier: MIT
# TCBL: write the host name chosen in the pre module 22-tcbl-hostname to the
# installed system.
if [ -n "${tcbl_hostname}" ]; then
    tik_target_mount "" "required"
    tik_progress_step "Setting the computer name" 0
    log "[tcbl-hostname] writing /etc/hostname: ${tcbl_hostname}"
    prun /usr/bin/tee "${TIK_ROOT_MNT}/etc/hostname" <<< "${tcbl_hostname}" > /dev/null
    tik_progress_step "Computer name set" 100
fi
HOSTPOSTMOD

cat > /etc/tik/modules/post/19-tcbl-autorelabel <<'RELABELMOD'
# SPDX-License-Identifier: MIT
# TCBL: have the installed system give every file the SELinux label its policy
# assigns, at its first boot. The installer copies the running USB's files and
# their labels, including what the live session created (on one test system,
# /var/log/tuned with the wrong type, which kept tuned-ppd from starting), and
# 14-tcbl-package-sets installs with the USB's policy loaded rather than the
# new system's, so packages that add policy modules (Cockpit, swtpm) get
# generic labels. /etc/selinux/.autorelabel is openSUSE's request for a
# relabel: selinux-autorelabel (required by microos-tools) relabels the root
# snapshot, /etc and /var in the initrd and the other file systems before
# local-fs.target, then removes the file. An empty file relabels types only,
# keeping labels that are set on purpose, such as those of containers.
tik_target_mount "" "required"
if [ -e "${TIK_ROOT_MNT}/etc/selinux/config" ]; then
    log "[tcbl-autorelabel] the installed system relabels itself at its first boot"
    prun /usr/bin/touch "${TIK_ROOT_MNT}/etc/selinux/.autorelabel"
fi
RELABELMOD

#======================================
# Services
#--------------------------------------
# Enabled by presets, which systemd applies at the first boot: NetworkManager,
# systemd-resolved and zram swap by tc-benchtop-settings (85-tcbl.preset);
# chronyd, irqbalance and fstrim.timer by openSUSE's own presets. rtkit-daemon
# is started by D-Bus when a program asks for realtime scheduling.

#======================================
# Add default kernel boot options
#--------------------------------------
# TCBL: only options that cannot be set anywhere else go on the kernel command
# line. tc-benchtop-settings sets the rest: systemd's boot status messages
# (system.conf.d), the lockup detectors (sysctl.d) and SATA staggered spin-up
# (modprobe.d).
# TCBL: no serial console. Aeon, like MicroOS, adds console=ttyS0,115200
# console=tty0 for servers and VMs; without console= the kernel uses the screen.
cmdline=('quiet' 'loglevel=2' 'vt.global_cursor_default=0')

# TCBL: Plymouth shows its splash, and its graphical disk-password prompt, only
# with "splash" on the kernel command line; without it, it prints boot messages.
cmdline+=("splash")

ignition_platform='metal'

if [ -n "${ignition_platform}" ]; then
	cmdline+=("ignition.platform.id=${ignition_platform}")
fi

#======================================
# If SELinux is installed, configure it like transactional-update setup-selinux
#--------------------------------------
if [[ -e /etc/selinux/config ]]; then
	cmdline+=("security=selinux selinux=1")
	# enforcing and targeted are what selinux-policy writes on a new install

	# Move an /.autorelabel file from initial installation to writeable location
	test -f /.autorelabel && mv /.autorelabel /etc/selinux/.autorelabel
fi

# Make PCR 15 validation advisory only, never a poweroff. This prevents
# the reboot-after-unlock behaviour seen on Aeon when a post-update PCR
# prediction is stale: the disk still unlocks and boot reaches the desktop.
cmdline+=("measure-pcr-validator.ignore=yes")

# Performance tuning (Source: notes Performance/Kernel Tuning.md).
# Threaded IRQs and RCU no-callback/lazy for desktop latency. Full preemption
# is already the default of openSUSE's kernel (CONFIG_PREEMPT=y).
cmdline+=("threadirqs")
cmdline+=("rcu_nocbs=all")
# rcutree.enable_rcu_lazy is a no-op unless the kernel is built with
# CONFIG_RCU_LAZY=y, which the SUSE kernel configs (Tumbleweed stable,
# SL-16.0, SL-16.1) do not set. Harmless: unknown dotted parameters are
# ignored. rcu_nocbs=all still offloads callbacks. Kept so the parameter is
# in place if a CONFIG_RCU_LAZY kernel is adopted.
cmdline+=("rcutree.enable_rcu_lazy=1")

# TCBL: turn the IOMMU on for Intel machines too. openSUSE's kernel leaves
# CONFIG_INTEL_IOMMU_DEFAULT_ON off, although upstream turns it on. The AMD
# IOMMU is on by default (amd_iommu= has no "on" value), and iommu=pt would
# repeat openSUSE's own default, CONFIG_IOMMU_DEFAULT_PASSTHROUGH. Without an
# Intel DMAR table the Intel driver does nothing, so the option is harmless on
# AMD. A TCBL kernel built with CONFIG_INTEL_IOMMU_DEFAULT_ON makes it
# unnecessary (notes: Build Configuration.md, Custom kernel).
cmdline+=("intel_iommu=on")

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
# The installer's copy-progress (repart-prep module above) measures the
# bytes mkfs.btrfs reads against this: the apparent size of the files that
# repart.d/50-root.conf copies, leaving out what its ExcludeFiles= leaves out.
# Measured last, so that it includes what config.sh added.
du -sbx --exclude=/tmp --exclude=/var/tmp --exclude=/boot --exclude=/mnt --exclude=/run \
    --exclude=/ignition --exclude=/var/cache/zypp --exclude=/var/cache/man --exclude=/var/log/journal \
    / | cut -f1 > /usr/share/tcbl/copy-bytes
