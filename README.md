# benchtop-image

The OS **disk image** for TechniComp Benchtop Linux (immutable, Slowroll-based),
built on OBS from this repo via scmsync. Forked from openSUSE Aeon's kiwi image
description, retargeted to `patterns-tc-benchtop-base` on openSUSE:Slowroll.

**This is the minimal first image**: same btrfs read-only-snapshot / UEFI /
systemd-boot(sdbootutil) / ignition scaffolding as Aeon, installing our full
pattern — building it is the authoritative dependency gate. The `tik` GUI
installer and TC Benchtop branding packages (`tc-benchtop-release`,
`tik-config-benchtop`, `*-branding-benchtop`) are deliberately **not** here yet;
they are follow-up packaging tasks. Deploy this image by writing it to disk;
ignition performs first-boot setup.
