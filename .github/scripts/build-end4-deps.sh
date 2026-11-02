#!/usr/bin/env bash
set -Eeuo pipefail

# This script is executed inside an ephemeral Arch Linux Docker container.
# It bootstraps a non-root makepkg user, then builds the Arch packages that
# the current end-4/dots-hyprland install-deps.sh references.

UPSTREAM_REPO="https://github.com/end-4/dots-hyprland.git"
UPSTREAM_DIR="/tmp/dots-hyprland"
PKGDEST="${GITHUB_WORKSPACE:-/workspace}/dist"
AUR_BUILDER_REPO="https://aur.archlinux.org/yay-bin.git"

if [[ "${1:-}" != "--build" ]]; then
    if (( EUID != 0 )); then
        echo "Run this script inside the Arch Linux container as root." >&2
        exit 1
    fi

    pacman -Sy --noconfirm archlinux-keyring
    pacman -Syu --noconfirm
    pacman -S --needed --noconfirm base-devel git sudo shadow util-linux

    id builder >/dev/null 2>&1 || useradd --create-home --shell /bin/bash builder
    printf 'builder ALL=(ALL:ALL) NOPASSWD: ALL\n' > /etc/sudoers.d/builder
    chmod 0440 /etc/sudoers.d/builder
    visudo -cf /etc/sudoers.d/builder

    install -d -o builder -g builder "$PKGDEST"
    exec runuser -u builder -- env HOME=/home/builder USER=builder LOGNAME=builder \
        bash "$0" --build
fi
shift

if [[ "$(uname -m)" != "x86_64" ]]; then
    echo "This workflow currently builds x86_64 packages only." >&2
    exit 1
fi

mkdir -p "$HOME/.cache" "$HOME/yay-bootstrap" "$PKGDEST"
printf 'PKGDEST="%s"\n' "$HOME/yay-bootstrap" > "$HOME/.makepkg.conf"

echo "::group::Build yay-bin"
git clone --depth=1 "$AUR_BUILDER_REPO" "$HOME/yay-bin"
(
    cd "$HOME/yay-bin"
    makepkg --syncdeps --install --noconfirm
)
echo "::endgroup::"

# Route all subsequent makepkg/yay build outputs to the mounted workspace.
printf 'PKGDEST="%s"\n' "$PKGDEST" > "$HOME/.makepkg.conf"
export UPSTREAM_REPO UPSTREAM_DIR PKGDEST

echo "::group::Fetch end-4/dots-hyprland"
git clone --depth=1 "$UPSTREAM_REPO" "$UPSTREAM_DIR"
UPSTREAM_COMMIT="$(git -C "$UPSTREAM_DIR" rev-parse HEAD)"
echo "Upstream commit: $UPSTREAM_COMMIT"
SHORT_SHA="${UPSTREAM_COMMIT:0:12}"
echo "::endgroup::"

INSTALL_DEPS="$UPSTREAM_DIR/sdata/dist-arch/install-deps.sh"
if [[ ! -f "$INSTALL_DEPS" ]]; then
    echo "Could not find the current Arch dependency installer: $INSTALL_DEPS" >&2
    exit 1
fi

# Extract only the metapkgs array assignments from install-deps.sh. This
# follows upstream's package list without executing its installation logic.
mapfile -t RELATIVE_PKGDIRS < <(
    {
        printf 'metapkgs=()\n'
        grep -E '^metapkgs(\+)?=\(' "$INSTALL_DEPS" || true
        printf 'printf "%%s\\n" "${metapkgs[@]}"\n'
    } | bash
)

if (( ${#RELATIVE_PKGDIRS[@]} == 0 )); then
    echo "No local Arch PKGBUILDs were listed by install-deps.sh." >&2
    exit 1
fi

PKGDIRS=()
for relative_dir in "${RELATIVE_PKGDIRS[@]}"; do
    case "$relative_dir" in
        ./sdata/dist-arch/*) ;;
        *)
            echo "Unexpected package path from upstream: $relative_dir" >&2
            exit 1
            ;;
    esac

    package_dir="$UPSTREAM_DIR/${relative_dir#./}"
    if [[ ! -f "$package_dir/PKGBUILD" ]]; then
        echo "Missing PKGBUILD: $package_dir/PKGBUILD" >&2
        exit 1
    fi
    PKGDIRS+=("$package_dir")
done

echo "Local PKGBUILDs selected by upstream:"
printf ' - %s\n' "${PKGDIRS[@]}"

# Collect all direct runtime/build dependencies from the selected PKGBUILDs.
# yay resolves packages available in official repositories and the AUR. Names
# that are only virtual provides are left for makepkg/pacman --syncdeps.
ALL_DEPS=()
for package_dir in "${PKGDIRS[@]}"; do
    while IFS= read -r dep; do
        [[ -n "$dep" ]] && ALL_DEPS+=("$dep")
    done < <(
        cd "$package_dir"
        makepkg --printsrcinfo |
            awk -F ' = ' '
                {
                    key = $1
                    sub(/^[[:space:]]+/, "", key)
                    if (key ~ /^(depends|makedepends)(_x86_64)?$/) print $2
                }
            ' |
            sed -E 's/[<>=].*$//' |
            sed -E 's/^[[:space:]]+|[[:space:]]+$//g'
    )
done

mapfile -t ALL_DEPS < <(printf '%s\n' "${ALL_DEPS[@]}" | awk 'NF && !seen[$0]++' | sort)

RESOLVED_DEPS=()
for dep in "${ALL_DEPS[@]}"; do
    if yay -Si "$dep" >/dev/null 2>&1; then
        RESOLVED_DEPS+=("$dep")
    else
        echo "Not directly searchable by package name; deferring to makepkg/pacman: $dep"
    fi
done

if (( ${#RESOLVED_DEPS[@]} > 0 )); then
    echo "::group::Build/install AUR and repository dependencies"
    yay -S --needed --asdeps --noconfirm --sudoloop --answerclean=a \
        --mflags "--cleanbuild" "${RESOLVED_DEPS[@]}"
    echo "::endgroup::"
fi

# Build the local packages themselves. Their AUR dependency builds, including
# transitive AUR dependencies built by yay, are also collected in PKGDEST.
for package_dir in "${PKGDIRS[@]}"; do
    echo "::group::Build $(basename "$package_dir")"
    (
        cd "$package_dir"
        makepkg --syncdeps --cleanbuild --force --noconfirm
    )
    echo "::endgroup::"
done

shopt -s nullglob
BUILT_PACKAGES=("$PKGDEST"/*.pkg.tar.zst)
if (( ${#BUILT_PACKAGES[@]} == 0 )); then
    echo "Build completed but no .pkg.tar.zst files were produced." >&2
    exit 1
fi

{
    printf 'upstream_repository=%s\n' "$UPSTREAM_REPO"
    printf 'upstream_commit=%s\n' "$UPSTREAM_COMMIT"
    printf 'architecture=x86_64\n'
    printf 'built_at_utc=%s\n' "$(date -u +'%Y-%m-%dT%H:%M:%SZ')"
    printf 'local_pkgbuild_count=%s\n' "${#PKGDIRS[@]}"
    printf 'package_file_count=%s\n' "${#BUILT_PACKAGES[@]}"
    printf '\nlocal_pkgbuilds:\n'
    printf '%s\n' "${PKGDIRS[@]##*/}"
} > "$PKGDEST/BUILD_INFO"

printf 'Built %s package files.\n' "${#BUILT_PACKAGES[@]}"
