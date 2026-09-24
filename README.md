# benchtop-image

The OS **disk image** for TechniComp Benchtop Linux (immutable, Tumbleweed-based),
built on OBS from this repo via scmsync. Forked from openSUSE Aeon's kiwi image
description, retargeted to `patterns-tc-benchtop-base`. The OBS projects build
against `openSUSE:Factory` (Tumbleweed).

**The image is a self-installing USB image** with the same btrfs
read-only-snapshot / UEFI / systemd-boot (sdbootutil) base as Aeon, installing
our full pattern; building it is the authoritative dependency gate. Written to a
USB stick, it boots to a login screen with two accounts: **Install Benchtop**
runs the `tik` installer, which deploys the system with systemd-repart onto a
LUKS2-encrypted disk (TPM2 or passphrase, plus a recovery key), and **Create
User** makes an account for using the stick as a live system; accounts made
there are copied onto every system installed from it. TC Benchtop branding is
applied by `config.sh` and the `root/` overlay; separate branding packages
(`tc-benchtop-release`, `*-branding-benchtop`) are still to come.
