#!/bin/bash
#=============================================================================
#          FILE: install-eSim.sh
#
#         USAGE: ./install-eSim.sh --install
#                            OR
#                ./install-eSim.sh --uninstall
#
#   DESCRIPTION: Dispatch wrapper for the eSim EDA Suite installer.
#                Detects the Ubuntu release from /etc/os-release and runs the
#                matching script from install-eSim-scripts/.
#
#       OPTIONS: ---
#  REQUIREMENTS: bash, coreutils
#          BUGS: ---
#         NOTES: Ubuntu 25.10 (questing) and 26.04 (resolute) are mapped to the
#                26.04 profile because they no longer have a KiCad 8 build.
#       AUTHORS: Fahim Khan, Rahul Paknikar, Saurabh Bansode,
#                Sumanto Kar, Partha Singha Roy, Jayanth Tatineni,
#                Anshul Verma, Shiva Krishna Sangati, Harsha Narayana P
#  ORGANIZATION: eSim Team, FOSSEE, IIT Bombay
#       CREATED: Wednesday 15 July 2015 15:26
#      REVISION: Saturday 17 November 2026
#=============================================================================

# NOTE: no `set -e` in this dispatcher. The child script owns its error
# handling and its exit status is propagated verbatim (see run_version_script).

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/install-eSim-scripts"

# Ubuntu release fields, filled by detect_os()
VERSION_ID=""
VERSION_POINT=""
UBUNTU_CODENAME=""
UBUNTU_PRETTY=""

# Detect the Ubuntu release without depending on lsb_release: the `lsb-release`
# package is not installed on minimal/server images, and on those images the
# old `lsb_release -d | grep -oP` pipeline silently produced an empty version.
detect_os() {
    if [ ! -r /etc/os-release ]; then
        echo "ERROR: /etc/os-release not found - this installer supports Ubuntu only."
        exit 1
    fi

    # shellcheck disable=SC1091
    . /etc/os-release
    VERSION_ID="${VERSION_ID:-}"
    UBUNTU_CODENAME="${UBUNTU_CODENAME:-}"
    UBUNTU_PRETTY="${PRETTY_NAME:-Ubuntu $VERSION_ID}"

    # Point release, e.g. "22.04.4" out of VERSION="22.04.4 LTS (Jammy Jellyfish)"
    VERSION_POINT="$(printf '%s' "${VERSION:-}" | grep -oE '^[0-9]+\.[0-9]+\.[0-9]+' || true)"

    if [ -z "$VERSION_ID" ]; then
        echo "ERROR: could not read VERSION_ID from /etc/os-release."
        exit 1
    fi

    case "${ID:-}" in
        ubuntu|linuxmint|pop|elementary|zorin) : ;;
        *)
            echo "ERROR: '$UBUNTU_PRETTY' is not a supported distribution."
            echo "       eSim installers are provided for Ubuntu and Ubuntu-based systems."
            exit 1
            ;;
    esac

    echo "Detected: $UBUNTU_PRETTY (VERSION_ID=$VERSION_ID, codename=${UBUNTU_CODENAME:-unknown})"
}

# Map an Ubuntu release to an installer script.
# Sets SCRIPT (absolute path) and PROFILE_NAME (used in messages).
pick_profile() {
    local major minor
    major="${VERSION_ID%%.*}"
    minor="${VERSION_ID#*.}"
    minor="${minor%%.*}"

    case "$VERSION_ID" in
        22.04)
            # Historical behaviour kept: only 22.04.4 uses the 22.04 profile,
            # other 22.04 point releases use the 23.04 profile.
            if [ "${VERSION_POINT:-}" = "22.04.4" ]; then
                PROFILE_NAME="22.04"
            else
                PROFILE_NAME="23.04"
            fi
            ;;
        23.04) PROFILE_NAME="23.04" ;;
        24.04) PROFILE_NAME="24.04" ;;
        25.04) PROFILE_NAME="25.04" ;;
        *)
            # Anything newer than 25.04 (25.10, 26.04, 26.10, ...) is handled by
            # the 25.04 profile with the KiCad 9 branch, because the kicad-8.0
            # PPA has no builds after plucky (its questing/ index is a 404).
            # LTS point releases (26.04.1, ...) are matched by major.minor.
            if [ "$major" -ge 26 ] 2>/dev/null || { [ "$major" -eq 25 ] && [ "$minor" -ge 10 ]; }; then
                PROFILE_NAME="25.04+"
            else
                echo "ERROR: Ubuntu $VERSION_ID is too old for this installer."
                echo "       Supported: 22.04, 23.04, 24.04, 25.04, 25.10 and 26.04+."
                echo "       For older releases use the eSim 2.3/2.4 installers."
                exit 1
            fi
            ;;
    esac

    case "$PROFILE_NAME" in
        "25.04+") SCRIPT="$SCRIPT_DIR/install-eSim-25.04.sh" ;;
        *)        SCRIPT="$SCRIPT_DIR/install-eSim-$PROFILE_NAME.sh" ;;
    esac

    if [ ! -f "$SCRIPT" ]; then
        echo "ERROR: installer profile '$PROFILE_NAME' not found: $SCRIPT"
        echo "       The release archive looks incomplete - re-extract it and retry."
        exit 1
    fi
}

# Make sure the commands the profile scripts rely on are present. Minimal and
# server images ship neither sudo nor unzip, and `add-apt-repository` lives in
# software-properties-common. Installing them here keeps the profile scripts
# from aborting halfway through (and leaves the system usable).
preflight() {
    local missing=()

    if [ "$(id -u)" -ne 0 ] && ! command -v sudo >/dev/null 2>&1; then
        echo "ERROR: 'sudo' is required when not running as root."
        echo "       Install it with: su -c 'apt-get install -y sudo'"
        exit 1
    fi

    command -v unzip     >/dev/null 2>&1 || missing+=(unzip)
    command -v xz        >/dev/null 2>&1 || missing+=(xz-utils)
    command -v curl      >/dev/null 2>&1 || missing+=(curl)
    command -v add-apt-repository >/dev/null 2>&1 || missing+=(software-properties-common)

    if [ "${#missing[@]}" -gt 0 ]; then
        echo "Installing preflight packages: ${missing[*]}"
        if [ "$(id -u)" -eq 0 ]; then
            apt-get update -qq && apt-get install -y --no-install-recommends "${missing[@]}" || {
                echo "ERROR: could not install preflight packages: ${missing[*]}"
                exit 1
            }
        else
            sudo apt-get update -qq && sudo apt-get install -y --no-install-recommends "${missing[@]}" || {
                echo "ERROR: could not install preflight packages: ${missing[*]}"
                exit 1
            }
        fi
    fi
}

run_version_script() {
    local rc=0

    echo "Using installer profile: $PROFILE_NAME ($SCRIPT)"

    # The profile scripts branch on the release (KiCad 8 vs 9) - hand the value
    # over so they do not need lsb_release.
    export UBUNTU_VER="$VERSION_ID"

    # Run in the current working directory: every profile script expects to be
    # started from the extracted eSim release root (it uses relative paths such
    # as library/kicadLibrary.tar.xz and nghdl.zip).
    bash "$SCRIPT" "$ARGUMENT" || rc=$?

    if [ "$rc" -ne 0 ]; then
        echo
        echo "eSim installation FAILED (profile $PROFILE_NAME, exit code $rc)."
        echo "Fix the error printed above and re-run: $0 $ARGUMENT"
    fi

    return "$rc"
}

####################################################################
#                   MAIN START FROM HERE                           #
####################################################################

main()
{
    if [ "$#" -ne 1 ]; then
        echo "USAGE :"
        echo "  $0 --install"
        echo "  $0 --uninstall"
        exit 2
    fi

    ARGUMENT="$1"
    if [ "$ARGUMENT" != "--install" ] && [ "$ARGUMENT" != "--uninstall" ]; then
        echo "Invalid argument: $ARGUMENT"
        echo "Usage: $0 --install | $0 --uninstall"
        exit 2
    fi

    detect_os
    pick_profile

    if [ "$ARGUMENT" = "--install" ]; then
        preflight
    fi

    run_version_script
    exit $?
}

# Only run when executed, so that Ubuntu/tests/ can source the functions and
# exercise the version mapping without touching the system.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi