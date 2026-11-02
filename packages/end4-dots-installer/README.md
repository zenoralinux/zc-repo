# end4-dots-installer

Independent Arch Linux package for installing the end-4 / Illogical Impulse Hyprland configuration.

## Prerequisites

Install the packages from the separate dependency release first:

https://github.com/zenoralinux/zc-repo/releases/tag/end4-deps-2f2a376fdb2a

The PKGBUILD declares the Illogical Impulse metapackages as dependencies, so pacman will refuse to install this package if those prerequisites are not installed.

## Install

```bash
sudo pacman -U end4-dots-installer-*.pkg.tar.zst
end4-install
```

Run `end4-install` as your normal user, not as root. Use `end4-install --yes` to skip the confirmation prompt; backups are still created.

## What it does

- Installs the upstream `dots/` configuration snapshot.
- Backs up conflicting user configuration under `~/ii-original-dots-backup/<timestamp>/`.
- Sets up the Quickshell Python 3.12 virtual environment from the upstream pinned requirements file.
- Adds the user to the `video`, `input`, and `i2c` groups when available.
- Configures the `i2c-dev` module and enables Bluetooth / ydotool systemd services when available.
- Applies available GNOME/KDE appearance settings.
- Installs Google Sans Flex as a system font.

This package does **not** run upstream `setup`, `install.sh`, `install-deps.sh`, or any other upstream installer script. It does not install GPU drivers, configure a display manager, or change the default login session.

The current installer is designed for x86_64 Arch-based distributions using systemd. The user must log out and back in after installation so group membership and the new session configuration take effect.

## Source revisions

- end-4/dots-hyprland: `2f2a376fdb2ad738bf55f693dd0b474b64bb0ab8`
- end-4/google-sans-flex: `251aa5abd30496368f634e54ce2a508fe5a2fdfa`

Licenses from both upstream projects are included in the package.
