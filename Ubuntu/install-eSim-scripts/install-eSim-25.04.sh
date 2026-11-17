#!/bin/bash
#=============================================================================
#          FILE: install-eSim-25.04.sh
#
#         USAGE: ./install-eSim.sh --install      (from the release root)
#                ./install-eSim.sh --uninstall
#
#   DESCRIPTION: Installation script for the eSim EDA Suite on Ubuntu 25.04.
#                Normally invoked through ../../install-eSim.sh, which detects
#                the Ubuntu release and exports UBUNTU_VER.
#
#       OPTIONS: ---
#  REQUIREMENTS: sudo (or root), network access
#          BUGS: ---
#         NOTES: Non-interactive by default. Set ESIM_ASSUME_YES=no to be asked
#                before replacing a KiCad installed from another source.
#       AUTHORS: Fahim Khan, Rahul Paknikar, Saurabh Bansode,
#                Sumanto Kar, Partha Singha Roy, Harsh Narayana P,
#                Jayanth Tatineni, Anshul Verma
#  ORGANIZATION: eSim Team, FOSSEE, IIT Bombay
#       CREATED: Wednesday 15 July 2015 15:26
#      REVISION: Saturday 17 November 2026
#=============================================================================

# All variables go here
config_dir="$HOME/.esim"
config_file="config.ini"
eSim_Home="$(pwd)"
ngspiceFlag=0

# Ubuntu release. The dispatcher exports UBUNTU_VER; fall back to os-release so
# that the profile script also works when started on its own. `lsb_release` is
# deliberately NOT used: it is missing from minimal/server images and its
# absence used to produce an empty version string.
if [ -z "${UBUNTU_VER:-}" ]; then
    UBUNTU_VER="$( . /etc/os-release 2>/dev/null; printf '%s' "${VERSION_ID:-}" )" || true
fi
export UBUNTU_VER

## Helpers
log()  { echo "$*"; }
warn() { echo "WARNING: $*" >&2; }

error_exit()
{
    local rc=$?
    echo -e "\n\nError! Kindly resolve above error(s) and try again."
    echo "Last command: ${BASH_COMMAND}"
    echo "Exit status:  ${rc}"
    echo -e "\nAborting Installation...\n"
}

# Run a command with sudo unless we are already root.
as_root()
{
    if [ "$(id -u)" -eq 0 ]; then
        "$@"
    else
        sudo "$@"
    fi
}

# apt-get install wrapper: always non-interactive.
apt_install()
{
    as_root apt-get install -y --no-install-recommends "$@"
}

# pip install into the eSim virtualenv. Fails the installation on purpose.
pip_install_required()
{
    python -m pip install "$@" || {
        echo "ERROR: 'pip install $*' failed. Check your network/proxy settings."
        return 1
    }
}

# pip install for NgVeri-only helpers: a failure here must not abort the eSim
# installation, because eSim core (KiCad -> ngspice -> plot) does not need them.
pip_install_optional()
{
    python -m pip install "$@" || warn "optional package '$*' could not be installed - NgVeri/Makerchip flows may be unavailable"
}

ask_yes_no()
{
    local prompt="$1" default="${2:-no}" answer=""
    if [ ! -t 0 ]; then
        echo "$prompt [non-interactive: assuming '$default']"
        [ "$default" = "yes" ]
        return
    fi
    read -r -p "$prompt " answer || answer="$default"
    answer="${answer:-$default}"
    [[ "$answer" =~ ^([Yy][Ee][Ss]|[Yy])$ ]]
}

# Optional, comma separated list of steps to skip. Intended for CI, containers
# and for resuming an installation whose slowest stages (KiCad download, NGHDL
# source build) already succeeded:
#   ESIM_SKIP_STEPS=installKicad,installNghdl ./install-eSim.sh --install
skip_step()
{
    local steps=",${ESIM_SKIP_STEPS:-},"
    [[ "$steps" == *",$1,"* ]]
}

## All functions go here

function createConfigFile
{
    # Creating config.ini file and adding configuration information
    mkdir -p "$config_dir"
    # -f: on a re-install the directory exists but config.ini may not, and a
    # bare `rm` aborted the whole installation under `set -e`.
    rm -f "$config_dir/$config_file"

    cat > "$config_dir/$config_file" <<EOF
[eSim]
eSim_HOME = $eSim_Home
LICENSE = %(eSim_HOME)s/LICENSE
KicadLib = %(eSim_HOME)s/library/kicadLibrary.tar.xz
IMAGES = %(eSim_HOME)s/images
VERSION = %(eSim_HOME)s/VERSION
MODELICA_MAP_JSON = %(eSim_HOME)s/library/ngspicetoModelica/Mapping.json

EOF
}


function installNghdl
{
    log "Installing NGHDL..........................."

    if [ ! -f nghdl.zip ]; then
        warn "nghdl.zip not found in $eSim_Home - skipping NGHDL/NgVeri support."
        warn "eSim will start, but mixed-signal (NGHDL) and Verilog (NgVeri) flows will be unavailable."
        return 0
    fi

    unzip -q -o nghdl.zip
    if [ ! -d nghdl ]; then
        warn "nghdl.zip did not contain a 'nghdl' directory - skipping."
        return 0
    fi

    chmod +x nghdl/install-nghdl.sh

    # Do not trap on error of any command. Let the NGHDL script handle its own
    # errors: it needs to build ngspice from source, which is slow and may fail
    # for reasons unrelated to eSim itself.
    trap "" ERR
    ( cd nghdl && ./install-nghdl.sh --install ) || warn "NGHDL installation reported a failure - eSim core is still installed."
    trap error_exit ERR

    ngspiceFlag=1
    return 0
}


function installSky130Pdk
{
    log "Installing SKY130 PDK......................"

    if [ ! -f library/sky130_fd_pr.tar.xz ]; then
        warn "library/sky130_fd_pr.tar.xz not found - skipping SKY130 PDK."
        return 0
    fi

    # Extract SKY130 PDK
    tar -xJf library/sky130_fd_pr.tar.xz

    # Remove any previous sky130_fd_pr instance, if any
    as_root rm -rf /usr/share/local/sky130_fd_pr

    log "Copying SKY130 PDK........................."
    as_root mkdir -p /usr/share/local/
    as_root mv sky130_fd_pr /usr/share/local/

    # Change ownership from root to the user
    as_root chown -R "$USER:$USER" /usr/share/local/sky130_fd_pr/
}


function installKicad
{
    log "Installing KiCad..."

    local ubuntu_version="${UBUNTU_VER:-}"
    local kicad_major="" kicadppa="" installed_major="" installed_version=""

    # KiCad 8 exists in a PPA for 24.04/25.04 only. From 25.10 onwards the
    # kicad-8.0 PPA has no builds (its questing/ index returns 404), so the
    # 9.0 PPA / Ubuntu universe package is used instead.
    case "$ubuntu_version" in
        24.04|25.04)
            kicad_major=8
            kicadppa="kicad/kicad-8.0-releases"
            ;;
        *)
            if [ -z "$ubuntu_version" ]; then
                warn "Could not determine the Ubuntu release - assuming KiCad 9."
            fi
            kicad_major=9
            kicadppa="kicad/kicad-9.0-releases"
            ;;
    esac

    if dpkg -s kicad &>/dev/null; then
        installed_version="$(dpkg-query -W -f='${Version}' kicad 2>/dev/null || true)"
        installed_major="${installed_version%%.*}"

        if [ "$installed_major" = "$kicad_major" ]; then
            log "KiCad $installed_major.x is already installed ($installed_version) - nothing to do."
            # Was `exit 0`: a re-run then aborted before eSim itself was
            # installed. `return` lets the remaining steps run.
            return 0
        fi

        warn "A different KiCad version is installed ($installed_version), eSim expects $kicad_major.x."
        if ! ask_yes_no "Do you want to remove it and install KiCad $kicad_major.0? (yes/no):" "${ESIM_ASSUME_YES:-no}"; then
            echo "Keeping the installed KiCad. eSim may fail to open schematics."
            return 0
        fi
        log "Removing KiCad $installed_major..."
        as_root apt-get remove --purge -y kicad kicad-footprints kicad-libraries kicad-symbols kicad-templates || true
        as_root apt-get autoremove -y
    fi

    # Check if the PPA is already added. deb822 .sources files do not start with
    # "deb ", so match on the PPA path itself.
    if ! grep -rqs "${kicadppa}" /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null; then
        log "Adding KiCad PPA to local apt repository: $kicadppa"
        as_root add-apt-repository -y "ppa:$kicadppa"
    else
        log "KiCad PPA is already present in sources."
    fi

    as_root apt-get update || warn "apt-get update reported an error - continuing."

    # No exact version pin: `kicad=8.0.8+dfsg-1` only exists in the Ubuntu
    # archive for plucky and not at all for questing/resolute, where it made the
    # whole installation fail with "Version ... was not found". Let apt pick the
    # newest build from the PPA (or from universe as a fallback).
    if ! apt_install kicad kicad-footprints kicad-symbols kicad-templates; then
        warn "KiCad could not be installed from $kicadppa - retrying with the Ubuntu archive version."
        apt_install kicad || {
            echo "ERROR: KiCad installation failed."
            echo "       Try: sudo add-apt-repository -y ppa:$kicadppa && sudo apt install kicad"
            return 1
        }
    fi

    # kicad-libraries is a metapackage that is not present in every release;
    # install it only when available so that it cannot break the run.
    if apt-cache show kicad-libraries &>/dev/null; then
        apt_install kicad-libraries || warn "kicad-libraries could not be installed."
    fi

    log "KiCad installation completed successfully!"
}


function installDependency
{

    set +e      # Temporary disable exit on error
    trap "" ERR # Do not trap on error of any command

    # Update apt repository
    log "Updating apt index files..................."
    as_root apt-get update

    set -e      # Re-enable exit on error
    trap error_exit ERR

    log "Installing virtualenv......................."
    # -y was missing here: on a fresh install apt asked for confirmation and the
    # unattended/CI run either hung or aborted with "Abort.".
    apt_install python3-virtualenv python3-pip python3-setuptools

    log "Creating virtual environment to isolate packages "
    # Remove a previous environment first: without this, `virtualenv` on an
    # existing env keeps stale packages (pip, setuptools) from an older run.
    rm -rf "$config_dir/env"
    virtualenv -p python3 "$config_dir/env"

    log "Starting the virtual env..................."
    # shellcheck disable=SC1091
    source "$config_dir/env/bin/activate"

    log "Upgrading Pip.............................."
    python -m pip install --upgrade pip setuptools wheel

    log "Installing Xterm..........................."
    apt_install xterm

    log "Installing Psutil.........................."
    apt_install python3-psutil

    log "Installing PyQt5..........................."
    apt_install python3-pyqt5

    log "Installing Matplotlib......................"
    apt_install python3-matplotlib

    # eSim runs inside the virtualenv, so the packages it imports must be
    # installed there (apt packages are not visible to a plain venv).
    log "Installing Python runtime dependencies in the eSim virtualenv..."
    pip_install_required PyQt5
    pip_install_required matplotlib
    pip_install_required psutil
    pip_install_required watchdog

    # NgVeri/Makerchip helpers. Optional on purpose: SandPiper/makerchip-app lag
    # behind new Python releases and must not block the eSim GUI install.
    log "Installing NgVeri helpers (optional)......."
    pip_install_optional hdlparse
    pip_install_optional https://github.com/hdl/pyhdlparser/tarball/master
    pip_install_optional makerchip-app
    pip_install_optional sandpiper-saas

    return 0
}


function copyKicadLibrary
{
    local cfg_root="$HOME/.config/kicad"
    local kicad_version_dir="" version_tag="" pkg_version=""

    log "Extracting custom KiCad Library..."

    if [ -f library/kicadLibrary.tar.xz ]; then
        tar -xJf library/kicadLibrary.tar.xz -C library || {
            echo "ERROR: could not extract library/kicadLibrary.tar.xz"
            return 1
        }
    elif [ ! -d library/kicadLibrary ]; then
        warn "KiCad library not found (neither library/kicadLibrary.tar.xz nor library/kicadLibrary) - skipping."
        return 0
    fi

    # Detect the installed KiCad version instead of hardcoding 6.0: the symbol
    # library was copied into ~/.config/kicad/6.0 even when KiCad 8 was
    # installed, so eSim's symbols never showed up in KiCad's symbol chooser.
    version_tag="$(ls -1 "$cfg_root" 2>/dev/null | grep -E '^[0-9]+\.[0-9]+$' | sort -V | tail -n 1 || true)"

    if [ -z "$version_tag" ]; then
        pkg_version="$(dpkg-query -W -f='${Version}' kicad 2>/dev/null || true)"
        version_tag="$(printf '%s' "$pkg_version" | grep -oE '^[0-9]+\.[0-9]+' || true)"
    fi

    if [ -z "$version_tag" ]; then
        version_tag="8.0"
        log "KiCad configuration directory not found - creating $cfg_root/$version_tag"
    else
        log "Using KiCad configuration directory: $cfg_root/$version_tag"
    fi

    kicad_version_dir="$cfg_root/$version_tag"
    mkdir -p "$kicad_version_dir"

    # Copy symbol table for eSim custom symbols
    if [ -f library/kicadLibrary/template/sym-lib-table ]; then
        cp -f library/kicadLibrary/template/sym-lib-table "$kicad_version_dir/"
        log "Symbol table copied to $kicad_version_dir"
    else
        warn "library/kicadLibrary/template/sym-lib-table missing - symbol table not copied."
    fi

    # Copy KiCad symbols made for eSim
    as_root mkdir -p /usr/share/kicad/symbols
    if [ -d library/kicadLibrary/eSim-symbols ]; then
        as_root cp -a library/kicadLibrary/eSim-symbols/. /usr/share/kicad/symbols/
    else
        warn "library/kicadLibrary/eSim-symbols missing - symbols not copied."
    fi

    # Remove extracted KiCad Library - not needed anymore
    rm -rf library/kicadLibrary

    # Change ownership from root to the user
    as_root chown -R "$USER:$USER" /usr/share/kicad/symbols/
}


function createDesktopStartScript
{
    local desktop_dir=""

    # Generating new esim-start.sh
    cat > esim-start.sh <<EOF
#!/bin/bash
cd "$eSim_Home/src/frontEnd" || exit 1
source "$config_dir/env/bin/activate"
exec python3 Application.py "\$@"
EOF

    # Make it executable and copy esim start script
    chmod 755 esim-start.sh
    as_root cp -f esim-start.sh /usr/bin/esim
    rm -f esim-start.sh

    # Generating esim.desktop file
    cat > esim.desktop <<EOF
[Desktop Entry]
Version=1.0
Name=eSim
Comment=EDA Tool
GenericName=eSim
Keywords=eda-tools
Exec=esim %u
Terminal=true
X-MultipleArgs=false
Type=Application
Icon=$config_dir/logo.png
Categories=Development;
MimeType=text/html;text/xml;application/xhtml+xml;application/xml;application/rss+xml;application/rdf+xml;image/gif;image/jpeg;image/png;x-scheme-handler/http;x-scheme-handler/https;x-scheme-handler/ftp;x-scheme-handler/chrome;video/webm;application/x-xpinstall;
StartupNotify=true
EOF

    chmod 755 esim.desktop
    as_root cp -f esim.desktop /usr/share/applications/

    # $HOME/Desktop does not exist on minimal installs and is localised on
    # non-English desktops; ask the XDG user-dirs tool and create it if needed.
    desktop_dir="$(xdg-user-dir DESKTOP 2>/dev/null || true)"
    [ -n "$desktop_dir" ] || desktop_dir="$HOME/Desktop"
    mkdir -p "$desktop_dir"
    cp -f esim.desktop "$desktop_dir/"

    # Make esim.desktop file as trusted application (best effort: gio is not
    # available on headless systems).
    gio set "$desktop_dir/esim.desktop" "metadata::trusted" true 2>/dev/null || true
    chmod a+x "$desktop_dir/esim.desktop"

    rm -f esim.desktop

    # Copying logo.png to .esim directory to access as icon
    if [ -f images/logo.png ]; then
        cp -f images/logo.png "$config_dir"
    else
        warn "images/logo.png missing - desktop icon will not be set."
    fi
}


####################################################################
#                   MAIN START FROM HERE                           #
####################################################################

main()
{
### Checking if file is passed as argument to script

if [ "$#" -ne 1 ]; then
    echo "USAGE : "
    echo "  $0 --install"
    echo "  $0 --uninstall"
    exit 2
fi

option="$1"

## Checking flags

if [ "$option" = "--install" ]; then

    set -e  # Set exit option immediately on error
    set -E  # inherit ERR trap by shell functions

    # Trap on function error_exit before exiting on error
    trap error_exit ERR

    log "Enter proxy details if you are connected to internet through proxy"

    getProxy="n"
    if [ -t 0 ]; then
        read -r -p "Is your internet connection behind proxy? (y/n): " getProxy || getProxy="n"
    else
        log "Non-interactive shell: assuming no proxy."
    fi

    if [[ "$getProxy" =~ ^([Yy])$ ]]; then
        read -r -p 'Proxy Hostname :' proxyHostname
        read -r -p 'Proxy Port :' proxyPort
        read -r -p "username@$proxyHostname:$proxyPort :" username
        read -r -s -p 'Password :' passwd
        echo

        unset http_proxy https_proxy HTTP_PROXY HTTPS_PROXY ftp_proxy FTP_PROXY

        export http_proxy="http://$username:$passwd@$proxyHostname:$proxyPort"
        export https_proxy="http://$username:$passwd@$proxyHostname:$proxyPort"
        export HTTP_PROXY="http://$username:$passwd@$proxyHostname:$proxyPort"
        export HTTPS_PROXY="http://$username:$passwd@$proxyHostname:$proxyPort"
        export ftp_proxy="http://$username:$passwd@$proxyHostname:$proxyPort"
        export FTP_PROXY="http://$username:$passwd@$proxyHostname:$proxyPort"

        log "Install with proxy"

    elif [[ "$getProxy" =~ ^([Nn])$ ]]; then
        log "Install without proxy"

    else
        echo "Please select the right option"
        exit 0
    fi

    # Calling functions
    createConfigFile

    if skip_step installDependency; then
        warn "skipping installDependency (ESIM_SKIP_STEPS)"
    else
        installDependency
    fi

    if skip_step installKicad; then
        warn "skipping installKicad (ESIM_SKIP_STEPS)"
    else
        installKicad
    fi

    if skip_step copyKicadLibrary; then
        warn "skipping copyKicadLibrary (ESIM_SKIP_STEPS)"
    else
        copyKicadLibrary
    fi

    if skip_step installNghdl; then
        warn "skipping installNghdl (ESIM_SKIP_STEPS)"
    else
        installNghdl
    fi

    if skip_step installSky130Pdk; then
        warn "skipping installSky130Pdk (ESIM_SKIP_STEPS)"
    else
        installSky130Pdk
    fi

    if skip_step createDesktopStartScript; then
        warn "skipping createDesktopStartScript (ESIM_SKIP_STEPS)"
    else
        createDesktopStartScript
    fi

    echo "-----------------eSim Installed Successfully-----------------"
    echo "Type \"esim\" in Terminal to launch it"
    echo "or double click on \"eSim\" icon placed on Desktop"

elif [ "$option" = "--uninstall" ]; then

    echo -n "Are you sure? It will remove eSim completely including KiCad, Makerchip, NGHDL and SKY130 PDK along with their models and libraries (y/n):"
    read -r getConfirmation

    if [[ "$getConfirmation" =~ ^([Yy])$ ]]; then
        echo "Removing eSim............................"
        as_root rm -rf "$HOME/.esim" "$HOME/Desktop/esim.desktop" /usr/bin/esim /usr/share/applications/esim.desktop

        echo "Removing KiCad..........................."
        as_root apt purge -y kicad kicad-footprints kicad-libraries kicad-symbols kicad-templates || true
        as_root rm -rf /usr/share/kicad
        as_root rm -f /etc/apt/sources.list.d/kicad*.list /etc/apt/sources.list.d/kicad*.sources
        rm -rf "$HOME/.config/kicad"

        echo "Removing Virtual env......................."
        as_root rm -rf "$config_dir/env"

        echo "Removing SKY130 PDK......................"
        as_root rm -rf /usr/share/local/sky130_fd_pr

        echo "Removing NGHDL..........................."
        rm -rf library/modelParamXML/Nghdl/* library/modelParamXML/Ngveri/*
        if [ -d nghdl ]; then
            chmod +x nghdl/install-nghdl.sh
            ( cd nghdl && ./install-nghdl.sh --uninstall ) || warn "NGHDL uninstall reported a failure."
            rm -rf nghdl
            echo -e "----------------eSim Uninstalled Successfully----------------"
        else
            echo -e "\nCannot find \"nghdl\" directory. Please remove it manually if present."
        fi

    elif [[ "$getConfirmation" =~ ^([Nn])$ ]]; then
        exit 0
    else
        echo "Please select the right option."
        exit 0
    fi

else
    echo "Please select the proper operation."
    echo "--install"
    echo "--uninstall"
    exit 2
fi
}

# Only run when executed. Ubuntu/tests/ sources this file to test the helper
# functions (config generation, KiCad profile selection, ...) without root.
if [ "${BASH_SOURCE[0]}" = "$0" ]; then
    main "$@"
fi
