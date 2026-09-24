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
# identifies as TechniComp Benchtop Linux (GNOME Tour/About, etc.). ID is left at
# the base openSUSE value so tooling and the sdbootutil entry token keep working.
if [ -f /usr/lib/os-release ]; then
    sed -i -e 's/^NAME=.*/NAME="TechniComp Benchtop Linux"/' \
           -e 's/^PRETTY_NAME=.*/PRETTY_NAME="TechniComp Benchtop Linux"/' \
           /usr/lib/os-release
fi

# TCBL default desktop wallpaper for the installed system AND the installer
# session: system-wide GNOME background default via a gschema override (90- so it
# wins over gnome-backgrounds' default).
mkdir -p /usr/share/glib-2.0/schemas
cat > /usr/share/glib-2.0/schemas/90-tcbl-background.gschema.override <<'BGOVR'
[org.gnome.desktop.background]
picture-uri='file:///usr/share/backgrounds/tcbl/tcbl-installer.png'
picture-uri-dark='file:///usr/share/backgrounds/tcbl/tcbl-installer.png'
picture-options='zoom'
primary-color='#ffffff'
BGOVR
if command -v glib-compile-schemas >/dev/null 2>&1; then
    glib-compile-schemas /usr/share/glib-2.0/schemas/
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
		--text="Create an account for using TechniComp Benchtop Linux from this USB drive. Any system installed from this drive will include it." \
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
# before modules, so this definition wins). It is upstream's function verbatim
# plus the two lines marked TCBL. Re-sync if a tik update changes that function.
dump_image_repart_self() {
    local image_target=$1
    create_keyfile
    prun-opt rm -rf /etc/fstab.repart
    log "[dump_image_repart_self] self-deploying"
    prun /usr/sbin/wipefs --all "${image_target}"    # TCBL
    prun-opt udevadm settle --timeout=30             # TCBL
    prun systemd-repart --no-pager --pretty=0 --empty=force --dry-run=no --key-file="${tik_keyfile}" --generate-fstab=/etc/fstab.repart "${image_target}" > >(d --progress --title="Installing ${TIK_OS_NAME}" --text="Deploying OS Image" --pulsate --auto-close --no-cancel --width=400)
}
PREPMOD

# TCBL live-USB tik modules. 01-tcbl-exit, 12-tcbl-machine-id and
# 13-tcbl-no-memtest must run before particular vendored modules (10-welcome,
# 15-encrypt), and tik loads /usr/lib/tik/modules/<phase> before
# /etc/tik/modules/<phase>, so those three sit beside the vendored modules.
# 17-tcbl-live-cleanup has no ordering need.
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

mkdir -p /etc/tik/modules/post
cat > /etc/tik/modules/post/17-tcbl-live-cleanup <<'CLEANMOD'
# SPDX-License-Identifier: MIT
# TCBL: remove the live USB's login-screen setup from the installed system.
# 10-sicu removes the tik account; this removes the "Create User" account, its
# sudo rule, the passwordless GDM login rule and both accounts' AccountsService
# records. Accounts made with "Create User" are kept.
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
tik_progress_step "Live USB accounts removed" 100
CLEANMOD

#======================================
# Enable NetworkManager
#--------------------------------------
systemctl enable NetworkManager

# DNS: tc-benchtop-settings hands NetworkManager's DNS to systemd-resolved
# (90-tcbl-dns.conf). openSUSE's presets leave systemd-resolved disabled.
systemctl enable systemd-resolved

# GDM login screen logo: the light TechniComp mark, for GDM's dark background.
# GDM shows it at the bottom of the login screen, scaled to 48 px high
# (org.gnome.login-screen logo). Set in the gdm system dconf database, which
# takes precedence over GDM's packaged greeter defaults. Installed systems keep it.
mkdir -p /etc/dconf/db/gdm.d
cat > /etc/dconf/db/gdm.d/10-tcbl-logo << "EOF"
[org/gnome/login-screen]
logo='/usr/share/pixmaps/tcbl-login-logo.png'
EOF
# GDM's packaged profile (/usr/share/dconf/profile/gdm) has no system-db:gdm
# line, so install the profile GNOME's administrator guide gives for this.
mkdir -p /etc/dconf/profile
printf '%s\n' 'user-db:user' 'system-db:gdm' 'file-db:/usr/share/gdm/greeter-dconf-defaults' > /etc/dconf/profile/gdm
dconf update

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
# TCBL package repository
#--------------------------------------
# tc-benchtop-settings adds the repository (repo-tcbl) and ships its signing key;
# importing the key lets zypper use the repository without asking.
rpm --import /usr/lib/rpm/gnupg/keys/gpg-pubkey-9f72b2da-68976fe8.asc

#======================================
# Add default kernel boot options
#--------------------------------------
# TCBL: no serial console. Aeon, like MicroOS, adds console=ttyS0,115200
# console=tty0 for servers and VMs; without console= the kernel uses the screen.
cmdline=('quiet' 'loglevel=2' 'systemd.show_status=0' 'vt.global_cursor_default=0')

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
