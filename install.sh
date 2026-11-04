#!/bin/sh
# Copyright (c) 2026, Kry10 Limited. All rights reserved.
#
# SPDX-License-Identifier: LicenseRef-Kry10

# Installs kos-tool from GitHub Releases. Creates /opt/kry10, where kos-tool installs the KOS SDK.
# Links /usr/local/bin/kos-tool to /opt/kry10/bin/kos-tool, so kos-tool is on PATH in the terminal that ran the script.
#
# Use of root in this script:
#   - Runs as the user, not under sudo. Uses sudo only to create /opt/kry10 and the link in /usr/local/bin.
#   - Shows the sudo commands and asks before it runs them.
#   - Asks on the terminal, because stdin is the script. Stops when there is not a terminal.
#   - Sets the user as the owner of the new /opt/kry10, so kos-tool does not need sudo.
#   - Does not change an /opt/kry10 that exists. Another user can own it.
#   - Does not change a /usr/local/bin/kos-tool that exists.
#
# Examples, where <url> is the address of this script:
#   curl -fsSL <url> | sh                                  Install the latest release to /opt/kry10/bin.
#   curl -fsSL <url> | sh -s -- --version 0.2.0            Install release 0.2.0.
#   curl -fsSL <url> | sh -s -- --to "$HOME/.local/bin"    Install to a different directory.
#   curl -fsSL <url> | sh -s -- --yes                      Run sudo without the question, for example in CI.
#
# Options (each also read from the environment):
#   --version <version>  KOS_TOOL_VERSION  A release such as 0.2.0, or "latest" (the default).
#   --to <dir>           KOS_TOOL_DIR      Where kos-tool goes, /opt/kry10/bin by default. Not linked in /usr/local/bin.
#   --yes                KOS_TOOL_YES=1    Run the sudo commands without asking first.
#
# KOS_TOOL_RELEASES_URL points the script at a mirror laid out like GitHub Releases.

set -eu

RELEASES_URL=${KOS_TOOL_RELEASES_URL:-https://github.com/Kry10-NZ/kos-tool-release/releases}
# nix compiles absolute paths into the packages kos-tool installs, so it needs this directory whatever --to says.
KRY10_DIR=/opt/kry10
# On the default PATH of macOS (from /etc/paths) and of the common Linux distributions.
LINK_DIR=/usr/local/bin

say() { printf '%s\n' "$*"; }
err() {
    printf 'error: %s\n' "$*" >&2
    exit 1
}

usage() {
    say "usage: install.sh [--version <version>] [--to <dir>] [--yes]"
    say "  --version  a kos-tool release such as 0.2.0, or latest (default; also KOS_TOOL_VERSION)"
    say "  --to       the directory to install into (default /opt/kry10/bin; also KOS_TOOL_DIR)"
    say "  --yes      run the sudo commands without asking first (also KOS_TOOL_YES=1)"
}

has() { command -v "$1" > /dev/null 2>&1; }

# Fails up front with every missing tool named, rather than partway through the install.
check_tools() {
    missing=
    for tool in curl uname id mktemp chmod mkdir mv cut head tail sort; do
        has "$tool" || missing="$missing $tool"
    done
    if has sha256sum; then
        SHA256=sha256sum
    elif has shasum; then
        SHA256="shasum -a 256"
    else
        missing="$missing sha256sum-or-shasum"
    fi
    [ -z "$missing" ] || err "these tools are required but not installed:$missing"
    # BusyBox sort can lack -V, which comparing versions needs.
    printf '1\n' | sort -V > /dev/null 2>&1 || err "sort does not support -V. Install GNU coreutils."
}

detect_platform() {
    os=$(uname -s)
    arch=$(uname -m)
    case $os in
        Linux)
            case $arch in
                x86_64 | amd64) echo linux-x86_64 && return ;;
                aarch64 | arm64) echo linux-aarch64 && return ;;
            esac
            ;;
        Darwin)
            # A shell under Rosetta reports x86_64 on Apple silicon.
            if [ "$arch" = arm64 ] || [ "$(sysctl -n hw.optional.arm64 2> /dev/null)" = 1 ]; then
                echo macos-aarch64 && return
            fi
            ;;
    esac
    err "kos-tool is not built for $os $arch. It is built for linux-x86_64, linux-aarch64 and macos-aarch64."
}

# Succeeds when semver $1 is newer than $2. Kept in step with the publish job in kos-tool's main.yml.
newer() {
    a=${1%%+*} b=${2%%+*}
    [ "$a" != "$b" ] || return 1
    if [ "${a%%-*}" = "${b%%-*}" ]; then
        case $a in *-*) ;; *) return 0 ;; esac
        case $b in *-*) ;; *) return 1 ;; esac
    fi
    [ "$(printf '%s\n' "$a" "$b" | sort -V | tail -n 1)" = "$a" ]
}

# check_tools picks the command, sha256sum on Linux and shasum on macOS.
sha256() {
    $SHA256 "$1" | cut -d ' ' -f 1
}

# GitHub redirects releases/latest to the newest release that is not a pre-release.
resolve_latest() {
    url=$(curl -fsSLI -o /dev/null -w '%{url_effective}' "$RELEASES_URL/latest") ||
        err "could not reach $RELEASES_URL/latest"
    tag=${url##*/}
    case $tag in
        v[0-9]*) echo "${tag#v}" ;;
        *) err "could not find the latest kos-tool release at $RELEASES_URL" ;;
    esac
}

# kos-tool --version prints "kos-tool v<semver>-<build>" on its first line.
# <build> is a short commit hash, which this removes. Older builds, like "kos-tool v0.1.1-beta-26.Oct-00", end with something else, and print as they are.
installed_version() {
    line=$("$1" --version 2> /dev/null | head -n 1) || return 0
    v=${line#kos-tool v}
    [ "$v" != "$line" ] || return 0
    build=${v##*-}
    case $build in
        "$v" | *[!0-9a-f]*) echo "$v" ;;
        *) if [ ${#build} -ge 7 ]; then echo "${v%-*}"; else echo "$v"; fi ;;
    esac
}

# Not `:`, a special built-in: dash exits the script when a special built-in's redirection fails.
can_ask() { true 2> /dev/null < /dev/tty; }

# Prints "ok" when $LINK_DIR/kos-tool links to $1, "missing" when nothing is there, and "other" for anything else.
# -ef also accepts a link made another way, for example a relative link. readlink accepts a link to a $1 that does not exist yet.
link_state() {
    if [ "$LINK_DIR/kos-tool" -ef "$1" ] || { [ -L "$LINK_DIR/kos-tool" ] && [ "$(readlink "$LINK_DIR/kos-tool")" = "$1" ]; }; then
        echo ok
    elif [ -e "$LINK_DIR/kos-tool" ] || [ -L "$LINK_DIR/kos-tool" ]; then
        echo other
    else
        echo missing
    fi
}

# Runs the commands that setup_as_root needs, each with $1 in front: "sudo", "show", or "" to run them directly.
setup_commands() {
    if [ "$make_dir" = true ]; then
        $1 mkdir -p "$KRY10_DIR" || return 1
        $1 chown "$(id -u)" "$KRY10_DIR" || return 1
    fi
    if [ "$make_link" = true ]; then
        $1 mkdir -p "$LINK_DIR" || return 1
        $1 ln -s "$KRY10_DIR/bin/kos-tool" "$LINK_DIR/kos-tool" || return 1
    fi
}

show() { say "  sudo $*"; }

# Creates $KRY10_DIR when $1 is true, and the link in $LINK_DIR when $2 is true, in one sudo step.
# On failure, setup_fix tells the user what to do.
setup_as_root() {
    make_dir=$1
    make_link=$2
    setup_fix="Run this script again."
    # For example root, or a Mac where Homebrew made the user the owner of /usr/local/bin.
    if [ "$make_link" = true ] && [ -w "$LINK_DIR" ]; then
        ln -s "$KRY10_DIR/bin/kos-tool" "$LINK_DIR/kos-tool"
        make_link=false
    fi
    [ "$make_dir" = true ] || [ "$make_link" = true ] || return 0
    if [ "$(id -u)" = 0 ]; then
        setup_commands ""
        return
    fi
    [ "$make_dir" = false ] || say "kos-tool installs the KOS SDK to $KRY10_DIR, which does not exist."
    [ "$make_link" = false ] || say "A link in $LINK_DIR puts kos-tool on your PATH."
    say "To do this, this script runs:"
    say ""
    setup_commands show
    say ""
    if ! has sudo; then
        setup_fix="sudo is not installed. Run this script again as root."
        return 1
    fi
    if [ "$yes" = false ]; then
        if ! can_ask; then
            setup_fix="This script cannot ask for permission without a terminal. Run it again in a terminal, or with --yes."
            return 1
        fi
        printf 'Continue? [Y/n] ' > /dev/tty
        read -r answer < /dev/tty || answer=n
        case $answer in
            "" | [Yy]*) ;;
            *) return 1 ;;
        esac
    fi
    setup_commands sudo
}

# Everything runs from here, called on the last line, so a download cut short by curl | sh runs nothing.
main() {
    version=${KOS_TOOL_VERSION:-latest}
    dir=${KOS_TOOL_DIR:-$KRY10_DIR/bin}
    yes=false
    [ "${KOS_TOOL_YES:-}" != 1 ] || yes=true

    while [ $# -gt 0 ]; do
        case $1 in
            --version)
                [ $# -ge 2 ] || err "--version needs a value"
                version=$2
                shift 2
                ;;
            --version=*)
                version=${1#*=}
                shift
                ;;
            --to)
                [ $# -ge 2 ] || err "--to needs a value"
                dir=$2
                shift 2
                ;;
            --to=*)
                dir=${1#*=}
                shift
                ;;
            -y | --yes)
                yes=true
                shift
                ;;
            -h | --help)
                usage
                exit 0
                ;;
            *) err "unknown argument: $1 (see --help)" ;;
        esac
    done

    # An explicit version is installed even when it is older than the one already there.
    explicit=true
    [ "$version" != latest ] || explicit=false
    version=${version#v}

    check_tools
    platform=$(detect_platform)

    # Under sudo, root owns kos-tool and /opt/kry10. Then kos-tool, run as the user, cannot write the SDK.
    [ "$(id -u)" != 0 ] || [ "${SUDO_USER:-root}" = root ] ||
        err "run this script without sudo. It runs sudo itself when it needs to."

    make_dir=false
    [ -d "$KRY10_DIR" ] || make_dir=true
    make_link=false
    if [ "$dir" = "$KRY10_DIR/bin" ] && [ "$(link_state "$KRY10_DIR/bin/kos-tool")" = missing ]; then
        make_link=true
    fi
    # A link that is not made is not an error. The PATH check at the end tells the user what to do.
    setup_as_root "$make_dir" "$make_link" || true

    kry10_problem=
    if [ ! -d "$KRY10_DIR" ]; then
        kry10_problem="$KRY10_DIR does not exist"
        kry10_fix=$setup_fix
    elif [ ! -w "$KRY10_DIR" ]; then
        kry10_problem="$KRY10_DIR is not writable by $(id -un)"
        kry10_fix="Ask its owner for write access."
    fi
    if [ -n "$kry10_problem" ]; then
        case $dir in
            "$KRY10_DIR" | "$KRY10_DIR"/*) err "$kry10_problem. $kry10_fix" ;;
        esac
    fi

    [ "$version" != latest ] || version=$(resolve_latest)

    bin="$dir/kos-tool"
    old=
    [ ! -x "$bin" ] || old=$(installed_version "$bin")

    if [ "$old" = "$version" ]; then
        say "kos-tool $version is already installed at $bin"
        exit 0
    fi
    if [ "$explicit" = false ] && [ -n "$old" ] && newer "$old" "$version"; then
        say "kos-tool $old at $bin is newer than the latest release $version. Pass --version $version to change to it."
        exit 0
    fi

    mkdir -p "$dir" 2> /dev/null || err "could not create $dir"
    [ -w "$dir" ] || err "$dir is not writable. Choose another directory with --to, or make it writable."

    asset="kos-tool-$version-$platform"
    url="$RELEASES_URL/download/v$version/$asset"

    # In the install directory, so the final mv is a rename and nobody sees a half-written binary.
    tmp=$(mktemp "$dir/.kos-tool.XXXXXX")
    trap 'rm -f "$tmp"' EXIT
    trap 'exit 1' HUP INT TERM

    say "1. Download kos-tool $version for $platform"
    say "   $url"
    curl -fsSL -o "$tmp" "$url" || err "could not download kos-tool $version for $platform from $url"

    say "2. Check the SHA-256 checksum"
    expected=$(curl -fsSL "$url.sha256" | cut -d ' ' -f 1) || err "could not download $url.sha256"
    actual=$(sha256 "$tmp")
    [ "$expected" = "$actual" ] || err "checksum mismatch for $asset: expected $expected, got $actual"
    say "   $actual"

    say "3. Move it to $bin"
    chmod 755 "$tmp"
    mv -f "$tmp" "$bin"
    trap - EXIT

    say ""

    if [ -n "$old" ]; then
        say "kos-tool $old → $version"
    else
        say "kos-tool $version installed to $bin"
    fi

    if [ -n "$kry10_problem" ]; then
        say ""
        say "$kry10_problem, so kos-tool cannot install the KOS SDK yet. $kry10_fix"
    fi

    on_path=false
    case ":$PATH:" in *":$dir:"*) on_path=true ;; esac
    if [ "$(link_state "$bin")" = ok ]; then
        case ":$PATH:" in *":$LINK_DIR:"*) on_path=true ;; esac
    elif [ "$dir" = "$KRY10_DIR/bin" ] && [ "$(link_state "$bin")" = other ]; then
        say ""
        say "$LINK_DIR/kos-tool exists and is not a link to $bin, so this script did not change it."
    elif [ "$dir" = "$KRY10_DIR/bin" ]; then
        say ""
        say "This script did not make the link in $LINK_DIR. $setup_fix"
    fi
    if [ "$on_path" = false ]; then
        say ""
        say "$dir is not on your PATH. Add it with:"
        say ""
        say "  export PATH=\"$dir:\$PATH\""
    fi
}

main "$@"
