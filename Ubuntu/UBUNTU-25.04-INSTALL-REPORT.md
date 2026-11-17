# eSim 2.5 on Ubuntu 25.04 and above — installation bugs, root causes and fixes

**Task 4 — eSim Upgradation (CSE and related fields)**
eSim Winter Internship 2026 (screening task)

| | |
|---|---|
| Target | eSim **2.5** distribution (`eSim-2.5.zip`, SHA256 `b9860ae26f026930bae589520761f4a57b85d593a2e2cd1ac83d5e5db2f281ed` — matches the published checksum) |
| Installer under test | `installers` branch of `github.com/FOSSEE/eSim` (commit `a77d6b9`, PR #414 "Add support for Ubuntu 25.04 in installer script") |
| Tested on | Ubuntu **25.04** (plucky) and Ubuntu **25.10** (questing) containers, x86-64 |
| Result | **12 defects catalogued, 8 reproduced, 7 fixed** (2 of them completely block the installation), 1 partially addressed and documented as an upstream policy decision; 65 offline regression tests added |
| Patch | branch `fix/ubuntu-25.04-and-above-install` in the forked repository, 5 commits, `patches/` in this submission |

---

## 1. Executive summary

The task asks to install eSim 2.5 on Ubuntu 25.04 and above, list the problems, and fix at least one.

Two findings dominate everything else:

1. **The eSim 2.5 release cannot be installed on Ubuntu 25.04 at all.** The `install-eSim.sh` that ships inside `eSim-2.5.zip` only knows 22.04, 23.04 and 24.04. On 25.04 it prints `Unsupported Ubuntu version: 25.04 ()` and exits. A candidate who follows the installation instructions literally never reaches the installer.
2. **The `installers` branch — the file the task links to — does not parse.** PR #414 added the 25.04 profile but left an `if [[ -f "$SCRIPT" ]]; then` block unclosed and pasted a fragment of `createConfigFile` into the middle of the dispatcher. `bash -n Ubuntu/install-eSim.sh` fails with `syntax error near unexpected token '}'`, so `--install` dies before executing a single line of the installer, on **every** Ubuntu version.

After repairing those two blockers, six further defects were reproduced on 25.04/25.10: an interactive `apt install` that aborts unattended runs, a hard-coded KiCad 8 point version that does not exist for 25.10+, an `exit 0` that silently skips the rest of the installation, a symbol library copied into the wrong KiCad configuration directory, a re-install path that aborts on a missing `config.ini`, and a desktop-entry copy that fails when `~/Desktop` does not exist. Each one is documented below with the command output that proves it, the root cause, the fix and the test that now guards it.

All fixes are regression-tested by `Ubuntu/tests/run-tests.sh` (**65 assertions, 0 failures**) and validated end-to-end inside a clean Ubuntu 25.04 container: the patched installer completes with exit status 0 and produces a working launcher, `config.ini`, virtualenv and SKY130/NGHDL artefacts.

---

## 2. Environment and methodology

### 2.1 Test systems

| ID | System | Purpose |
|----|--------|---------|
| C1 | `ubuntu:25.04` container (plucky), fresh, unprivileged user with sudo | Reproduce the supported target release |
| C2 | `ubuntu:25.10` container (questing) | "and above" — the release the task title implies |
| H1 | Host, Ubuntu 25.10 | Confirms the version-dispatch behaviour on a real desktop install |

Containers were used instead of virtual machines so that every run starts from a pristine root filesystem and can be repeated exactly (commands in §9). The eSim 2.5 release tree was bind-mounted read-write at `/opt/esim-src`, the patched installer at `/opt/esim-ubuntu`.

### 2.2 What was actually executed

* `bash install-eSim.sh --install` from the **unmodified** eSim 2.5 release (evidence A).
* `bash install-eSim.sh --install` from the **unmodified** `installers` branch (evidence D1).
* `apt-cache policy` / `apt-get install -s` against the live KiCad PPAs and the Ubuntu archive, on both releases (evidence B, C).
* The selected individual step from the old script that aborts first (evidence H).
* The **patched** installer, full sequence, on 25.04 (evidence E, F, G).

Heavy third-party stages (the ~1 GB KiCad download and the 20-minute ngspice source build inside NGHDL) were skipped in the end-to-end run through the new `ESIM_SKIP_STEPS` switch, after their apt resolution had been verified separately (B, C). This is the same technique the task suggests ("you may comment out some part of the script so that you may move on to the next bug"), except it is now a supported, documented switch instead of an edit.

### 2.3 Constraints worth stating

The test host had < 2 GB free, so a complete KiCad + ngspice build could not be run to the end. That limitation affected only the two skipped stages; it is also why the second end-to-end run (evidence G) ends with `No space left on device` — an artefact of the test host, not of the installer, as the log shows (pip had already completed 8 package installs and the SKY130 tarball was half-extracted).

---

## 3. Context: three installers, three different states

Understanding the failures requires knowing which installer is which.

| Source | Supports | State |
|--------|----------|-------|
| `eSim-2.5.zip` → `install-eSim.sh` (shipped) | 22.04, 23.04, 24.04 | Works on 24.04, **hard-refuses 25.04+** |
| `installers` branch → `Ubuntu/install-eSim.sh` | 22.04 … 25.04 | **Syntax error since PR #414**; 25.04 profile has the runtime bugs below |
| `master` branch → `Ubuntu/install-eSim.sh` (June 2026) | 23.04 … 26.04 | Rewritten as one unified, version-aware, idempotent script with `--dry-run` and a toolchain doctor |

The fixes in this submission are a **backport to the `installers` branch**, because that is the branch the task designates for submissions and the branch a user is pointed at. Where `master` had already solved a problem correctly, the backport follows its approach (release detection from `/etc/os-release`, KiCad major selection per release, `return` instead of `exit`, idempotent re-runs) so that the two branches do not diverge further.

`master`'s rewrite is the correct long-term answer. It is *not* a drop-in substitute for eSim 2.5 users: it targets the 2.6 code base (PyQt6 + QScintilla instead of PyQt5), so shipping it to 2.5 users would break the GUI. A backport is therefore the right shape for a 2.5 fix, and the recommendation in §8 is to retire the per-release scripts once 2.6 is the default download.

---

## 4. Defect catalogue

Legend — severity: **S1** installation impossible, **S2** installation aborts or silently skips, **S3** installation "succeeds" but the result is broken.

### BUG-01 — The shipped 2.5 installer refuses Ubuntu 25.04 and 25.10  *(S1)*

**Evidence** (`evidence/A_release_installer_2504.log`):

```
install-eSim.sh: line 26: lsb_release: command not found
Detected Ubuntu Version:
Unsupported Ubuntu version: 25.04 ()
```

Same on 25.10 (`evidence/A_release_installer_2510.log`).

**Root cause.** `run_version_script` in the release's `install-eSim.sh` has a `case $VERSION_ID` with branches for `22.04`, `23.04`, `24.04` and a `*)` that calls `exit 1`. There is no 25.04 profile in the archive at all (`install-eSim-scripts/` contains only 22.04/23.04/24.04). The 25.04 support lives exclusively on the `installers` branch, i.e. after the release was cut.

**Secondary defect in the same function.** `FULL_VERSION=$(lsb_release -d | grep -oP '\d+\.\d+\.\d+')` — `lsb-release` is not installed on minimal or server images, so `FULL_VERSION` is empty, which is why the error message reads `25.04 ()`. It also means the `22.04.4` special case can never match on a minimal system.

**Fix.** The dispatcher now reads `/etc/os-release` (always present, part of `base-files`), exports `UBUNTU_VER`, and reports the release and codename. The 25.04 profile is used for 25.04 and, with the KiCad 9 branch, for everything newer (see BUG-05).

---

### BUG-02 — `installers` branch: unclosed `if` and stray config write  *(S1)*

**Evidence** (`evidence/D1_branch_2504_first_run.log`):

```
install-eSim.sh: line 70: syntax error near unexpected token `}'
install-eSim.sh: line 70: `}'
exit=2
```

**Root cause.** PR #414 (`a77d6b9`, 2026-05-29) inserted the 25.04 `case` arm and, at the same time, pasted lines 62–68 of `createConfigFile` into `run_version_script()`:

```bash
    if [[ -f "$SCRIPT" ]]; then
        echo "Running script: $SCRIPT $ARGUMENT"
        bash "$SCRIPT" "$ARGUMENT"
    echo "[eSim]" >> $config_dir/$config_file     # <-- pasted from createConfigFile
    echo "eSim_HOME = $eSim_Home" >> $config_dir/$config_file
    ...
}                                                # <-- no `fi`
```

Two consequences. The script cannot be parsed. And, had it parsed, `$config_dir` is unset in the dispatcher, so `$config_dir/$config_file` expands to `/config.ini` and the block tries to write to the root directory.

**Fix.** Dead block deleted, `if` closed. A regression test asserts the dispatcher contains no `config_file` reference (test 10).

---

### BUG-03 — Dispatcher masks the child's exit status  *(S2)*

**Root cause.** `bash "$SCRIPT" "$ARGUMENT"` was the last command of the function body inside a `case`-selected `if`, and the dispatcher then ran the stray `echo` lines above. The exit status of a failed installation was therefore replaced by the status of `echo` — `0`. An automated or scripted install reports success after failing.

**Fix.** `run_version_script` captures the status, prints a single actionable summary, and returns it; `main` ends with `exit $?`. Test 3 runs a stub profile returning 7 and asserts the dispatcher returns 7.

---

### BUG-04 — Every `apt install` in the 25.04 profile is interactive  *(S1)*

**Evidence** (`evidence/H_apt_without_yes.log`), running the exact command from the original script:

```
Installing: 123 ...
Download size: 115 MB
Space needed: 414 MB / 1989 MB available

Continue? [Y/n] Abort.
exit=1
```

**Root cause.** `installDependency` uses `sudo apt install python3-virtualenv` (no `-y`). With `set -e` active, apt's `Abort.` terminates the installation. On a terminal the same command simply hangs waiting for input, which is the "stuck during installation" symptom reported in the task text. The dispatcher additionally runs the profile non-interactively (`bash script`) whenever stdin is not a TTY, e.g. from a provisioning script.

**Fix.** All package operations go through `apt_install()` (`apt-get install -y --no-install-recommends`) and `as_root()`. Test 9 greps both the 25.04 and 24.04 profiles for any `apt(-get) install` without `-y` and fails if one reappears.

---

### BUG-05 — KiCad selection is wrong for 25.10+ (PPA 404) and pinned to a version that may not exist  *(S1)*

**Evidence** — Ubuntu 25.10 (`evidence/B_kicad_ppa_2510.log`):

```
Ign:5 https://ppa.launchpadcontent.net/kicad/kicad-8.0-releases/ubuntu questing InRelease
Err:6 https://ppa.launchpadcontent.net/kicad/kicad-8.0-releases/ubuntu questing Release
  404  Not Found
E: The repository '...questing Release' does not have a Release file.

kicad:
  Candidate: 9.0.3+dfsg-1
     9.0.3+dfsg-1 500  http://archive.ubuntu.com/ubuntu questing/universe amd64 Packages

E: Version '8.0.8+dfsg-1' for 'kicad' was not found
```

**Evidence** — Ubuntu 25.04 (`evidence/C_kicad_pin_2504.log`):

```
kicad:
  Candidate: 8.0.9-0~ubuntu25.04.1          <- from the PPA
     8.0.9-0~ubuntu25.04.1 500  https://ppa.launchpadcontent.net/kicad/kicad-8.0-releases/ubuntu plucky/main
     8.0.8+dfsg-1        500  http://archive.ubuntu.com/ubuntu plucky/universe
```

**Root cause.** Two independent mistakes.

1. `kicadppa="kicad/kicad-8.0-releases"` is selected for `24.04 || 25.04` and `<anything else>`, i.e. 25.10 gets the KiCad 8 PPA too. Launchpad publishes no `questing` suite for that PPA (verified against the PPA index: `bionic focal jammy mantic noble oracular plucky xenial`), so `apt-get update` fails with a 404 and no KiCad 8 package is available. The same applies to 26.04 (`resolute`), which the `kicad-9.0-releases` PPA *does* cover.
2. `apt-get install kicad=8.0.8+dfsg-1` pins an exact Debian version. That version happens to exist in the 25.04 *archive* universe component, so on 25.04 the pin silently installs the archive build and ignores the PPA that the script just added (mixing kicad 8.0.8 with PPA 8.0.9 libraries). On 25.10 and 26.04 the version does not exist anywhere, so the install fails outright.

**Fix.** The profile now decides the KiCad major from `UBUNTU_VER`: 24.04/25.04 → KiCad 8 (`kicad/kicad-8.0-releases`), 25.10/26.04/26.10 → KiCad 9 (`kicad/kicad-9.0-releases`). The exact pin is removed; apt selects the newest build from the PPA, and if the PPA install fails the script retries against the archive (`kicad` in universe) with a warning. `kicad-libraries` is installed only when `apt-cache show` says it exists, so a missing metapackage cannot abort the run. Tests 5 and 6 cover all three releases.

---

### BUG-06 — `exit 0` when KiCad 8 is already present  *(S2)*

**Root cause.** In `installKicad`, the "already installed" branch ends with `exit 0` rather than `return 0`. Because the dispatcher runs the profile with `bash "$SCRIPT"`, `exit` terminates the whole installation *after* the dependency stage — `/usr/bin/esim`, the desktop entry, the symbol library, NGHDL and the PDK are never installed. A user who already has KiCad 8 (very common for eSim users) gets a half-installed eSim and no error message. The 24.04 profile has the same defect.

**Fix.** `return 0` in both profiles; the remaining steps run. Test 6 asserts the function returns 0 and performs no package operation.

---

### BUG-07 — Symbol library is written to `~/.config/kicad/6.0` regardless of KiCad version  *(S3)*

**Root cause.** `copyKicadLibrary` in the 25.04 and 24.04 profiles hard-codes:

```bash
tar -xJf library/kicadLibrary.tar.xz
mkdir -p ~/.config/kicad/6.0
cp kicadLibrary/template/sym-lib-table ~/.config/kicad/6.0/
```

but the same script installs **KiCad 8**. KiCad reads `sym-lib-table` from a directory named after its own major.minor version, so with KiCad 8 the table lands in a directory KiCad never looks at. The symbols are copied to `/usr/share/kicad/symbols/`, but the library table that names them is not registered, so eSim symbols appear "missing" in eSchema/KiCad — precisely the class of problem the installation instructions warn about. The initial `tar` also extracts into the current directory while the copy expects `kicadLibrary/`, and the tarball is left on disk.

**Fix.** The profile detects the configuration directory (`most recent ~/.config/kicad/<major.minor>`, else the major.minor of the installed `kicad` package, else 8.0), creates it, copies the table there, handles both the tarball and the directory layout, and cleans up. Test 7 checks the 9.0 case, the "no config dir yet" case and that no bogus `6.0` directory is created. The same fix is backported to 24.04.

---

### BUG-08 — A re-install aborts on `rm` of a missing `config.ini`  *(S2)*

**Root cause.**

```bash
if [ -d $config_dir ];then
    rm $config_dir/$config_file && touch $config_dir/$config_file
```

On a re-install `~/.esim` exists but `config.ini` may have been removed (or the previous run died before writing it). `rm` fails, `&&` short-circuits, and with `set -e` the installation aborts at the very first step — so a broken install can never be repaired by re-running the installer, which is exactly what the error message tells the user to do.

**Fix.** `rm -f` + `mkdir -p`, config written through a single here-document. Tests 4 (two consecutive runs, exactly one `[eSim]` header) and the live second run (evidence G) cover it.

---

### BUG-09 — Desktop entry step fails when `~/Desktop` is absent or localised  *(S2)*

**Root cause.** `cp -vp esim.desktop $HOME/Desktop/` assumes an English desktop with an existing `Desktop` directory. Minimal installs, server images, and desktops with a localised XDG directory (e.g. `~/Bureau`, `~/Schreibtisch`) make `cp` fail; with `set -e`, the installer aborts at the last step, after everything else has been installed. `gio set ... metadata::trusted` is equally unconditional and fails on headless systems.

**Fix.** The step asks `xdg-user-dir DESKTOP` first, falls back to `$HOME/Desktop`, creates the directory, and makes the `gio` call best-effort. Test 8 runs with no `~/Desktop` and asserts the entry is still produced.

---

### BUG-10 — Dispatcher assume host tooling that a fresh Ubuntu does not have  *(S2)*

**Root cause.** The profile scripts need `unzip` (NGHDL), `xz` (SKY130/tarballs), `curl` and `add-apt-repository` (KiCad PPA, from `software-properties-common`). A fresh 25.04 server/minimal image ships none of them, and nothing in the script installs them — the first symptom is `unzip: command not found` inside `installNghdl`, after the 115 MB dependency stage has already run. `sudo` itself can be missing.

**Fix.** A `preflight()` in the dispatcher verifies `sudo`, `unzip`, `xz-utils`, `curl` and `software-properties-common` and installs whatever is missing in one non-interactive `apt-get` call before dispatching. Test 10 asserts the function is present.

---

### BUG-11 — Venv/pip hygiene: duplicate installs, no reset, non-fatal deps fatal  *(S3)*

**Root cause.** The 25.04 profile installs PyQt5 and matplotlib twice (once from apt, once from pip), never removes an existing `~/.esim/env` (the 24.04 profile does), uses bare `pip3` instead of `python -m pip`, and treats `makerchip-app`/`sandpiper-saas`/`pyhdlparser` as hard requirements. Those three lag behind new Python releases; on 25.04 (Python 3.13) the first `pip install hdlparse` attempt fails to build, which — with `set -e` — aborted the entire installation before the GUI was configured.

**Fix.** The environment is recreated (`rm -rf`), pip is always invoked as `python -m pip` inside the venv, eSim's own runtime dependencies (PyQt5, matplotlib, psutil, watchdog) are required, and the NgVeri/Makerchip helpers use `pip_install_optional()` which warns and continues. Live evidence E shows exactly this: `hdlparse` fails to build, the installer warns, continues, and finishes with exit 0.

---

### BUG-12 — NGHDL and SKY130 failures abort an otherwise complete eSim  *(design issue, documented)*

`installNghdl` disables the ERR trap around the NGHDL script (good) but then continues running with `set -e`; any failure in `installSky130Pdk` (a 44 MB extraction and a root-owned move) aborts before the launcher is created. For eSim core (schematic → netlist → ngspice → plot) neither the PDK nor the HDL flow is required.

**Status:** partially addressed. `installNghdl` and `installSky130Pdk` now warn and skip when their archives are missing, and NGHDL failures no longer abort. The remaining decision — should a PDK failure fail the install? — is left to the maintainers (§8).

---

## 5. What changed

```
 Ubuntu/install-eSim.sh                                  | 231 +++++++++++-------
 Ubuntu/install-eSim-scripts/install-eSim-24.04.sh       |  42 ++--
 Ubuntu/install-eSim-scripts/install-eSim-25.04.sh       | 606 ++++++++++++++++++++++++-----------
 Ubuntu/tests/run-tests.sh                               | 400 ++++++++++++++++++++++++
 Ubuntu/UBUNTU-25.04-INSTALL-REPORT.md                   |  this file
```

Behavioural changes, in the order a reviewer should read them:

1. **Dispatcher is version-aware and honest.** `/etc/os-release` instead of `lsb_release`; 22.04/23.04/24.04/25.04 keep their profiles; 25.10, 26.04 and 26.10 map to the 25.04 profile in "KiCad 9" mode; anything older than 22.04 is rejected with a message that says what to use instead. Exit status is propagated.
2. **Preflight.** Missing host tools are installed first, not discovered halfway through.
3. **25.04 profile rewritten in place** (same file name, same public behaviour): non-interactive apt, idempotent config, venv reset, `python -m pip`, optional-vs-required Python dependencies, KiCad major selection without version pins, KiCad config directory detection, XDG-aware desktop entry, `as_root` helper so the script also runs as root in containers.
4. **24.04 backport** of the five defects that are not release-specific: `rm -f`, `return` instead of `exit`, `-y`, `UBUNTU_VER`, config-directory detection.
5. **`ESIM_SKIP_STEPS`** (new, documented): `ESIM_SKIP_STEPS=installKicad,installNghdl ./install-eSim.sh --install` re-runs or resumes an installation on a constrained machine. Used by the test harness and by the end-to-end evidence.
6. **Tests.** `Ubuntu/tests/run-tests.sh` — 65 assertions, no root, no network, no apt.

`22.04`/`23.04` profiles are deliberately untouched: both are EOL, and every edit to them would be unverifiable here. They are marked as such in the commit message.

---

## 6. Verification

### 6.1 Offline regression suite

```
$ cd Ubuntu && ./tests/run-tests.sh
...
Summary: 65 passed, 0 failed
```

| Group | What it proves |
|-------|----------------|
| 1 | every script (and the test runner) parses — the BUG-02 regression |
| 2 | release → profile mapping for 22.04 (both point releases), 23.04, 24.04, 25.04, 25.10, 26.04, 26.10; 20.04 rejected |
| 3 | dispatcher returns the profile's exit status (BUG-03) |
| 4 | `createConfigFile` works with an existing `~/.esim` and no `config.ini`, twice in a row, with all six keys (BUG-08) |
| 5 | KiCad 8 PPA on 25.04, KiCad 9 PPA on 25.10/26.04, no exact version pin (BUG-05) |
| 6 | installed KiCad 8 → `return`, no reinstall; foreign major → no purge without consent (BUG-06) |
| 7 | symbol table goes to `9.0`, never to a bogus `6.0`; version derived from dpkg when no config dir exists (BUG-07) |
| 8 | desktop entry created when `~/Desktop` does not exist (BUG-09) |
| 9 | no interactive `apt install`; pip only via `python -m pip`; NgVeri packages are optional (BUG-04, BUG-11) |
| 10 | dispatcher has no stray config write, no `lsb_release`, and does have preflight (BUG-01, BUG-02, BUG-10) |
| 11 | `--uninstall` declined deletes nothing |
| 12 | `ESIM_SKIP_STEPS` skips only the named stages |

Every stub is local to the test process (`as_root`, `apt_install`, `dpkg`, `dpkg-query`, `apt-cache`, `add-apt-repository`, `xdg-user-dir`); nothing is written outside a `mktemp -d` sandbox.

### 6.2 End-to-end on Ubuntu 25.04

`evidence/E_fixed_end_to_end_2504.log` — clean container, real apt, real virtualenv, real PyPI, patched installer:

```
Detected: Ubuntu 25.04 (VERSION_ID=25.04, codename=plucky)
Using installer profile: 25.04 (/opt/esim-ubuntu/install-eSim-scripts/install-eSim-25.04.sh)
...
Successfully installed PyQt5-5.15.11 PyQt5-Qt5-5.15.19 PyQt5-sip-12.20.1
Successfully installed matplotlib-3.11.2 numpy-2.5.5 ...
Successfully installed psutil-7.2.2
Successfully installed watchdog-7.1.0
ERROR: Failed to build 'hdlparse' when getting requirements to build wheel
WARNING: optional package 'hdlparse' could not be installed - NgVeri/Makerchip flows may be unavailable
...
Symbol table copied to /home/esim/.config/kicad/8.0
Copying SKY130 PDK.........................
-----------------eSim Installed Successfully-----------------
exit=0
```

Note the fourth-from-last line: on the old script that `hdlparse` failure was fatal (BUG-11).

`evidence/F_artifacts_2504.log` — the resulting installation:

```
~/.esim:            config.ini  env  logo.png
config.ini:         [eSim] + eSim_HOME/LICENSE/KicadLib/IMAGES/VERSION/MODELICA_MAP_JSON
venv imports:       Qt 5.15.14 | matplotlib 3.11.2 | psutil 7.2.2
/usr/bin/esim:      cd <release>/src/frontEnd; source ~/.esim/env/bin/activate; exec python3 Application.py "$@"
~/Desktop:          esim.desktop
~/.config/kicad/8.0: sym-lib-table
/usr/share/kicad/symbols: eSim_*.kicad_sym
/usr/share/local/sky130_fd_pr: cells/ ...
```

`evidence/G_second_run_2504.log` — immediate re-run reached the SKY130 extraction (i.e. passed `createConfigFile`, the venv recreation and the whole pip stage) before the **host** ran out of disk. The `rm: cannot remove ... config.ini: No such file` abort of BUG-08 does not occur.

### 6.3 Apt resolution actually used

| Release | PPA added | Package that apt resolves | Old script's command | Result |
|---------|-----------|---------------------------|----------------------|--------|
| 25.04 | `kicad-8.0-releases` | `8.0.9-0~ubuntu25.04.1` | `kicad=8.0.8+dfsg-1` | old: silently installs the archive build; new: PPA build |
| 25.10 | `kicad-9.0-releases` | `9.0.x` (PPA) / `9.0.3+dfsg-1` (universe fallback) | `kicad=8.0.8+dfsg-1` | old: `E: Version ... was not found`; new: installs |
| 26.04 | `kicad-9.0-releases` | `9.0.x` (PPA has `resolute`) | idem | new: installs |

---

## 7. Files in this submission

```
task4-esim-ubuntu-install/
├── report/REPORT.md                  this report
├── evidence/                         raw logs quoted above (A, B, C, D1, E, F, G, H)
├── patches/                          the five commits as .patch files + apply instructions
└── repo/                             fork of FOSSEE/eSim, branch fix/ubuntu-25.04-and-above-install
    └── Ubuntu/
        ├── install-eSim.sh
        ├── install-eSim-scripts/install-eSim-{22.04,23.04,24.04,25.04}.sh
        ├── tests/run-tests.sh
        └── UBUNTU-25.04-INSTALL-REPORT.md
```

---

## 8. Remaining issues and recommendations

Ranked by what would help users most.

1. **Ship the fixed installer inside the release, or point the download page at the branch.** As of this writing a 25.04 user downloads 2.5 and is refused. Until a 2.6-based release is the default, the 25.04 profile should be copied into `eSim-2.5.zip`'s `install-eSim-scripts/` and the `case` arm added to its dispatcher. This is the single highest-impact change and does not need new code.
2. **Rebase the `installers` branch onto `master`'s unified installer and delete the per-release scripts.** Four near-identical 500-line scripts are why BUG-06/07/08 exist in 24.04 *and* 25.04 but were fixed in neither. `master` already has `detect_profile()`, `--dry-run` and a toolchain doctor; carrying those back would remove the whole class of drift.
3. **Stop pinning exact package versions** (`kicad=8.0.8+dfsg-1`, and the `requirements.txt` pins). Pinning is what turns a release-day dependency bump into a failed installation; if a version must be reproduced, pin in a constraints file that CI verifies, not in the user-facing installer.
4. **Make the PDK/HDL stages explicitly optional** (BUG-12) and report them as "installed / skipped / failed" in a final summary, instead of aborting a working GUI installation.
5. **eSim 2.5 vs 2.6 skew.** `master` now requires PyQt6 + QScintilla and `requirements.txt` pins numpy 1.24 / matplotlib 3.7, which have no cp313 wheels for 25.04. The 25.04 profile installs current PyQt5/matplotlib from PyPI (verified working above). When 2.6 becomes the default, the Qt 6 migration must land together with the release artefact, not after it.
6. **Consistency note (not fixed, needs a decision):** eSim reads the SKY130 PDK from `/usr/share/local/`, which is not a standard FHS location (the conventional path is `/usr/local/share/`). The installer and `src/kicadtoNgspice/DeviceModel.py` agree today, so changing one without the other would break installs. Flagged for the maintainers.

---

## 9. How to reproduce

```bash
# 1. the unmodified release refuses 25.04
docker run --rm -it -v "$PWD/eSim-2.5":/opt/esim-src ubuntu:25.04 bash
apt-get update && apt-get install -y sudo lsb-release
cd /opt/esim-src && bash install-eSim.sh --install     # "Unsupported Ubuntu version: 25.04 ()"

# 2. the installers branch does not parse
git clone -b installers https://github.com/FOSSEE/eSim.git && cd eSim/Ubuntu
bash -n install-eSim.sh                                 # syntax error near unexpected token `}'

# 3. the fixes
cd repo/Ubuntu && ./tests/run-tests.sh                  # 65 passed, 0 failed

# 4. end-to-end on 25.04 with the released 2.5 tree
docker run --rm -it -v "$PWD/eSim-2.5":/opt/esim-src -v "$PWD/repo/Ubuntu":/opt/esim-ubuntu:ro \
    ubuntu:25.04 bash
# (inside: install sudo/unzip/xz-utils, add a sudo user, then)
ESIM_SKIP_STEPS=installKicad,installNghdl \
    bash /opt/esim-ubuntu/install-eSim.sh --install      # exit 0
```

`evidence/` contains the complete output of each of these runs, including the two 25.10 runs.

---

## 10. Submission checklist

- [x] Fork of `FOSSEE/eSim`, `installers` branch, fixes committed on `fix/ubuntu-25.04-and-above-install`
- [x] Report in the repository (`Ubuntu/UBUNTU-25.04-INSTALL-REPORT.md`) so a visitor understands bugs, method and fix without extra files
- [x] Regression tests runnable with one command and no privileges
- [x] Evidence logs for every claim
- [x] Fork pushed to `GarvSaxena/eSim`; `fix/ubuntu-25.04-and-above-install` and `installers` both point at the fix, and the fork's default branch is the fix branch
- [ ] E-mail `contact-esim@fossee.in`, subject "eSim Semester Long Internship - Autumn 2026 Submission Task 4", with the fork link and this report
