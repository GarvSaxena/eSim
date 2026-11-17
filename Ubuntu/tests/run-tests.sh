#!/bin/bash
#=============================================================================
#          FILE: run-tests.sh
#
#         USAGE: ./run-tests.sh [-v]
#
#   DESCRIPTION: Offline regression tests for the eSim Ubuntu installers.
#                No root, no network, no apt: every privileged command is
#                stubbed, so the suite is safe to run on a working machine and
#                in CI.
#
#                Focus: the defects fixed for Ubuntu 25.04 and above
#                  * installer scripts must parse
#                  * Ubuntu release -> installer profile mapping
#                  * dispatcher must propagate the child exit status
#                  * createConfigFile must survive a re-install
#                  * installKicad must pick KiCad 8 or 9, must not `exit`
#                  * copyKicadLibrary must target the installed KiCad version
#                  * desktop entry must be created without ~/Desktop existing
#                  * no interactive apt/pip prompt may remain
#
#       AUTHORS: eSim Winter Internship 2026 submission
#  ORGANIZATION: FOSSEE, IIT Bombay
#=============================================================================

set -u

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
UBUNTU_DIR="$(cd "$HERE/.." && pwd)"
DISPATCHER="$UBUNTU_DIR/install-eSim.sh"
PROFILE2504="$UBUNTU_DIR/install-eSim-scripts/install-eSim-25.04.sh"

VERBOSE=0
[ "${1:-}" = "-v" ] && VERBOSE=1

PASS=0
FAIL=0
FAILED_NAMES=()

pass() {
    PASS=$((PASS + 1))
    printf "  \033[32mPASS\033[0m %s\n" "$1"
}

fail() {
    FAIL=$((FAIL + 1))
    FAILED_NAMES+=("$1")
    printf "  \033[31mFAIL\033[0m %s\n" "$1"
    [ -n "${2:-}" ] && printf "       %s\n" "$2"
    return 0
}

check_eq() { # name expected actual
    if [ "$2" = "$3" ]; then pass "$1"; else fail "$1" "expected: $2 | actual: $3"; fi
}

check_true() { # name condition-status
    if [ "$2" -eq 0 ]; then pass "$1"; else fail "$1"; fi
}

check_contains() { # name haystack needle
    case "$2" in
        *"$3"*) pass "$1" ;;
        *) fail "$1" "missing: $3" ;;
    esac
}

check_file_contains() { # name file needle
    if [ -f "$2" ] && grep -qF "$3" "$2"; then
        pass "$1"
    else
        fail "$1" "expected '$3' in ${2:-<missing file>}"
    fi
}

section() { printf "\n\033[1m%s\033[0m\n" "$1"; }

# Fresh HOME + release-root skeleton for every test that touches the filesystem.
new_sandbox() {
    SANDBOX="$(mktemp -d)"
    export HOME="$SANDBOX/home"
    mkdir -p "$HOME" "$SANDBOX/release/images" "$SANDBOX/release/src/frontEnd"
    mkdir -p "$SANDBOX/release/library/kicadLibrary/template"
    mkdir -p "$SANDBOX/release/library/kicadLibrary/eSim-symbols"
    : > "$SANDBOX/release/library/kicadLibrary/template/sym-lib-table"
    cp "$UBUNTU_DIR/../README.md" "$SANDBOX/release/" 2>/dev/null || : > "$SANDBOX/release/README.md"
    printf 'PNG' > "$SANDBOX/release/images/logo.png"
    cd "$SANDBOX/release" || exit 1
    RECORD="$SANDBOX/calls.log"
    : > "$RECORD"
}

cleanup_sandbox() {
    cd "$HERE" || exit 1
    [ -n "${SANDBOX:-}" ] && rm -rf "$SANDBOX"
    SANDBOX=""
}

# Load the 25.04 profile, with every privileged/external command stubbed.
load_profile() {
    # shellcheck disable=SC1090
    source "$PROFILE2504"

    as_root()          { echo "as_root $*" >> "$RECORD"; }
    apt_install()      { echo "apt_install $*" >> "$RECORD"; }
    apt_get()          { echo "apt-get $*" >> "$RECORD"; }
    apt-get()          { echo "apt-get $*" >> "$RECORD"; }
    add-apt-repository() { echo "add-apt-repository $*" >> "$RECORD"; }
    apt-cache()        { echo "apt-cache $*" >> "$RECORD"; return 1; }
    dpkg()             { echo "dpkg $*" >> "$RECORD"; return 1; }
    dpkg-query()       { echo "dpkg-query $*" >> "$RECORD"; return 1; }
    xdg-user-dir()     { echo "$SANDBOX/Desktop"; }
    gio()              { echo "gio $*" >> "$RECORD"; }
    systemctl()        { :; }
}

########################################################################
section "1. Every installer script must parse (bash -n)"

for f in "$DISPATCHER" "$UBUNTU_DIR"/install-eSim-scripts/*.sh "$HERE"/run-tests.sh; do
    if bash -n "$f" 2>/dev/null; then
        pass "parses: ${f#"$UBUNTU_DIR"/}"
    else
        fail "parses: ${f#"$UBUNTU_DIR"/}" "$(bash -n "$f" 2>&1 | head -2)"
    fi
done

########################################################################
section "2. Dispatcher maps every Ubuntu release to the right profile"

# shellcheck disable=SC1090
source "$DISPATCHER"

map_case() { # version_id version_point expected_profile expected_basename
    VERSION_ID="$1"
    VERSION_POINT="$2"
    PROFILE_NAME=""
    SCRIPT=""
    pick_profile >/dev/null 2>&1
    check_eq "Ubuntu $1 -> $3" "$3" "$PROFILE_NAME"
    check_eq "Ubuntu $1 script" "$4" "$(basename "${SCRIPT:-none}")"
}

map_case 22.04 "22.04.4" 22.04 install-eSim-22.04.sh
map_case 22.04 "22.04.1" 23.04 install-eSim-23.04.sh
map_case 23.04 "23.04.5" 23.04 install-eSim-23.04.sh
map_case 24.04 "24.04.2" 24.04 install-eSim-24.04.sh
map_case 25.04 "25.04.1" 25.04 install-eSim-25.04.sh
map_case 25.10 "25.10"   "25.04+" install-eSim-25.04.sh
map_case 26.04 "26.04"   "25.04+" install-eSim-25.04.sh
map_case 26.10 "26.10"   "25.04+" install-eSim-25.04.sh

VERSION_ID="20.04"; VERSION_POINT="20.04.6"
( pick_profile ) >/dev/null 2>&1
[ $? -eq 1 ] && pass "Ubuntu 20.04 rejected with exit 1" || fail "Ubuntu 20.04 rejected with exit 1"

VERSION_ID="25.10"; PROFILE_NAME=""; SCRIPT=""
pick_profile >/dev/null 2>&1
if [ -f "$SCRIPT" ]; then pass "25.10 profile file exists"; else fail "25.10 profile file exists" "$SCRIPT"; fi

########################################################################
section "3. Dispatcher propagates the profile exit status (no masking)"

new_sandbox
cat > "$SANDBOX/failing-profile.sh" <<'EOF'
#!/bin/bash
echo "simulated profile failure"
exit 7
EOF
chmod +x "$SANDBOX/failing-profile.sh"
SCRIPT="$SANDBOX/failing-profile.sh"
ARGUMENT="--install"
run_version_script >/dev/null 2>&1
check_eq "child exit 7 is propagated" 7 $?
cleanup_sandbox

########################################################################
section "4. createConfigFile survives re-install and writes every key"

new_sandbox
load_profile
mkdir -p "$HOME/.esim"          # directory exists, config.ini does NOT
createConfigFile </dev/null
check_eq "createConfigFile with existing ~/.esim but no config.ini" 0 $?
check_file_contains "config.ini created" "$HOME/.esim/config.ini" "[eSim]"
check_file_contains "eSim_HOME written" "$HOME/.esim/config.ini" "eSim_HOME = $SANDBOX/release"
check_file_contains "LICENSE key written" "$HOME/.esim/config.ini" "LICENSE = %(eSim_HOME)s/LICENSE"
check_file_contains "KicadLib key written" "$HOME/.esim/config.ini" "kicadLibrary.tar.xz"
check_file_contains "MODELICA_MAP_JSON written" "$HOME/.esim/config.ini" "ngspicetoModelica/Mapping.json"

createConfigFile </dev/null
check_eq "createConfigFile is idempotent" 0 $?
check_eq "config.ini still has exactly one [eSim] header" 1 "$(grep -c '^\[eSim\]$' "$HOME/.esim/config.ini")"
cleanup_sandbox

########################################################################
section "5. installKicad picks KiCad 8 on 25.04 and KiCad 9 on 25.10+"

for case in "25.04:kicad/kicad-8.0-releases" "25.10:kicad/kicad-9.0-releases" "26.04:kicad/kicad-9.0-releases"; do
    ver="${case%%:*}"
    ppa="${case##*:}"
    new_sandbox
    load_profile
    UBUNTU_VER="$ver"
    installKicad </dev/null >/dev/null 2>&1
    rc=$?
    check_eq "installKicad($ver) returns 0" 0 "$rc"
    if grep -q "apt_install kicad" "$RECORD"; then
        pass "installKicad($ver) installs kicad"
    else
        fail "installKicad($ver) installs kicad"
    fi
    if grep -q "$ppa" "$RECORD"; then
        pass "installKicad($ver) uses $ppa"
    else
        fail "installKicad($ver) uses $ppa" "$(grep -c . "$RECORD") recorded calls"
    fi
    cleanup_sandbox
done

# No exact version pin: it does not exist on 25.10/26.04 and mixes archives on 25.04.
new_sandbox
load_profile
UBUNTU_VER="25.10"
installKicad </dev/null >/dev/null 2>&1
if grep -q "kicad=8\.0\." "$RECORD"; then
    fail "no exact kicad version pin is used"
else
    pass "no exact kicad version pin is used"
fi
cleanup_sandbox

########################################################################
section "6. installKicad must not abort the installation (exit 0 regression)"

new_sandbox
load_profile
UBUNTU_VER="25.04"
dpkg()       { return 0; }                                  # kicad installed
dpkg-query() { echo "8.0.9-0~ubuntu25.04.1"; }
( installKicad </dev/null >/dev/null 2>&1 ); rc=$?
check_eq "already-installed KiCad 8 returns (not exits)" 0 "$rc"
if grep -q "apt_install" "$RECORD"; then
    fail "already-installed KiCad is not reinstalled"
else
    pass "already-installed KiCad is not reinstalled"
fi
cleanup_sandbox

new_sandbox
load_profile
UBUNTU_VER="25.04"
dpkg()       { return 0; }
dpkg-query() { echo "9.0.3+dfsg-1"; }
ESIM_ASSUME_YES=no
( installKicad </dev/null >/dev/null 2>&1 ); rc=$?
check_eq "other KiCad major + non-interactive keeps system untouched" 0 "$rc"
if grep -q "apt-get remove" "$RECORD"; then
    fail "other KiCad major is not purged without consent"
else
    pass "other KiCad major is not purged without consent"
fi
cleanup_sandbox

########################################################################
section "7. copyKicadLibrary targets the installed KiCad version, not 6.0"

new_sandbox
load_profile
mkdir -p "$HOME/.config/kicad/9.0"
dpkg-query() { echo "9.0.3+dfsg-1"; }
copyKicadLibrary </dev/null >/dev/null 2>&1
check_eq "copyKicadLibrary returns 0" 0 $?
if [ -f "$HOME/.config/kicad/9.0/sym-lib-table" ]; then
    pass "sym-lib-table copied into ~/.config/kicad/9.0"
else
    fail "sym-lib-table copied into ~/.config/kicad/9.0"
fi
if [ -e "$HOME/.config/kicad/6.0" ]; then
    fail "no bogus 6.0 directory is created"
else
    pass "no bogus 6.0 directory is created"
fi
cleanup_sandbox

new_sandbox
load_profile
dpkg-query() { echo "9.0.3+dfsg-1"; }   # no ~/.config/kicad yet
copyKicadLibrary </dev/null >/dev/null 2>&1
if [ -f "$HOME/.config/kicad/9.0/sym-lib-table" ]; then
    pass "version derived from the dpkg version when no config dir exists"
else
    fail "version derived from the dpkg version when no config dir exists"
fi
cleanup_sandbox

########################################################################
section "8. Desktop entry is created even without ~/Desktop"

new_sandbox
load_profile
xdg-user-dir() { echo "$HOME/Desktop"; }
createDesktopStartScript </dev/null >/dev/null 2>&1
check_eq "createDesktopStartScript returns 0" 0 $?
check_file_contains "desktop file created in ~/Desktop" "$HOME/Desktop/esim.desktop" "Exec=esim %u"
if grep -q "as_root cp -f esim-start.sh /usr/bin/esim" "$RECORD"; then
    pass "launcher installed to /usr/bin/esim"
else
    fail "launcher installed to /usr/bin/esim"
fi
cleanup_sandbox

########################################################################
section "9. No interactive prompts left in the apt/pip path"

interactive_apt="$(grep -nE '(apt-get|apt)[[:space:]]+install' "$PROFILE2504" "$UBUNTU_DIR/install-eSim-scripts/install-eSim-24.04.sh" \
                  | grep -vE '^-.*###|:[0-9]+:[[:space:]]*#' \
                  | grep -vE '\-y|apt_install' || true)"
if [ -z "$interactive_apt" ]; then
    pass "every apt install is non-interactive (-y)"
else
    fail "every apt install is non-interactive (-y)" "$interactive_apt"
fi

if grep -qE '(^|[;&|][[:space:]]*)pip3?[[:space:]]+install' "$PROFILE2504"; then
    fail "pip is invoked via 'python -m pip' inside the venv"
else
    pass "pip is invoked via 'python -m pip' inside the venv"
fi

# pip_install_optional must be the wrapper used for the NgVeri helpers.
if grep -q "pip_install_optional sandpiper-saas" "$PROFILE2504"; then
    pass "third-party NgVeri packages cannot abort the install"
else
    fail "third-party NgVeri packages cannot abort the install"
fi

########################################################################
section "10. Dispatcher contains no dead code and no unsupported-release pass-through"

if grep -q 'config_file' "$DISPATCHER"; then
    fail "dispatcher does not write a stray config.ini"
else
    pass "dispatcher does not write a stray config.ini"
fi

if grep -nE '^[^#]*lsb_release' "$DISPATCHER" | grep -q .; then
    fail "dispatcher does not depend on lsb_release"
else
    pass "dispatcher does not depend on lsb_release"
fi

if grep -q 'preflight' "$DISPATCHER"; then
    pass "dispatcher installs its own preflight packages"
else
    fail "dispatcher installs its own preflight packages"
fi

########################################################################
section "11. Uninstall is safe and non-destructive when declined"

new_sandbox
mkdir -p "$HOME/.esim"
echo "sentinel" > "$HOME/.esim/keep-me"
( echo "n" | HOME="$HOME" bash "$PROFILE2504" --uninstall >/dev/null 2>&1 )
check_eq "declined uninstall exits 0" 0 $?
if [ -f "$HOME/.esim/keep-me" ]; then
    pass "declined uninstall deletes nothing"
else
    fail "declined uninstall deletes nothing"
fi
cleanup_sandbox

########################################################################
section "12. ESIM_SKIP_STEPS skips only the named stages"

new_sandbox
load_profile
ESIM_SKIP_STEPS="installKicad,installNghdl"
if skip_step installKicad && skip_step installNghdl; then
    pass "named stages are skipped"
else
    fail "named stages are skipped"
fi
if skip_step installDependency; then
    fail "unnamed stages are not skipped"
else
    pass "unnamed stages are not skipped"
fi
ESIM_SKIP_STEPS=""
if skip_step installKicad; then
    fail "empty ESIM_SKIP_STEPS skips nothing"
else
    pass "empty ESIM_SKIP_STEPS skips nothing"
fi
cleanup_sandbox

########################################################################
printf "\n\033[1mSummary:\033[0m %d passed, %d failed\n" "$PASS" "$FAIL"
if [ "$FAIL" -ne 0 ]; then
    printf "Failed tests:\n"
    for n in "${FAILED_NAMES[@]}"; do printf "  - %s\n" "$n"; done
    exit 1
fi
exit 0
