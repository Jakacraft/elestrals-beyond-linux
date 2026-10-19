#!/usr/bin/env bash
# Elestrals Beyond launcher on Linux (Wine/Proton) - one-command installer.
#
#   bash install-elestrals-beyond.sh
#
# Credits and notes:
#   - Adapted from setup.sh in https://github.com/s1aai/firestorm-wine-fix by
#     s1aai (LGPL-2.1-or-later). This adapted script is released under the same
#     license. The patched ole32.dll it downloads is also built and published
#     by that project.
#   - The crash and its root cause are documented in Wine bug 60225
#     (bugs.winehq.org/show_bug.cgi?id=60225).
#   - Unofficial: not affiliated with Elestrals, Piton Labs, Wine, GE-Proton or
#     Valve. It does not modify the game or the launcher. It only swaps Wine's
#     ole32.dll inside a separate copy of GE-Proton11-7.
#   - The ole32.dll is a third-party build (checksum-verified, but not from Wine
#     or GE). The secur32 patch was derived from the GE-Proton11-7 binary
#     itself. Read the script before running it.
#   - Second fix: GE-Proton11-7's secur32.dll (Wine's TLS layer) tells apps the
#     wrong number of "missing bytes" when a TLS record arrives in pieces, so
#     the launcher waits forever for data that never comes ("Couldn't load game
#     information"). Fixed upstream in Wine 11.6. This script applies the same
#     fix as a 10-byte patch to GE-Proton11-7's secur32.dll. It only patches
#     the exact original file (checksum-verified before and after) and keeps a
#     backup as secur32.dll.orig.
#   - Temporary workaround: once Wine / GE-Proton fix bug 60225 and ship
#     Wine 11.6 or newer, a normal GE-Proton update makes this unnecessary.
#
# Why this exists: the Elestrals launcher is a Tauri/WebView2 app. Stock Wine
# crashes it inside ole32 (RevokeDragDrop; Wine bug 60225), and the older Wine
# in GE-Proton11-7 breaks its network requests (secur32 bug, see below). This
# script builds a copy of GE-Proton11-7 with both fixed, then installs WebView2
# and the launcher into a fresh prefix.
#
# Steps (each one is skipped if already done, so re-running is safe):
#   1. find (or download) umu-launcher
#   2. make GE-Proton11-7-ole32fix: GE-Proton11-7 + patched ole32.dll
#      + patched secur32.dll
#   3. create the Wine prefix and set it to Windows 11
#   4. install the Microsoft WebView2 Runtime into it
#   5. download and install the Elestrals Beyond launcher
#   6. add "Elestrals Beyond Launcher" to the apps menu, then start it
#
# ELESTRALS_PREFIX=/some/dir changes where the prefix goes
# (default: ~/Games/elestrals-beyond).
#
# To remove everything (this ALSO deletes the game, once the launcher has
# downloaded it):
#   rm -rf ~/Games/elestrals-beyond ~/.local/share/elestrals-beyond-linux \
#     ~/.local/share/Steam/compatibilitytools.d/GE-Proton11-7-ole32fix \
#     ~/.local/share/applications/elestrals-beyond-launcher.desktop

main() {
set -Eeuo pipefail

INSTALLER_URL='https://elestra.ls/DLBeyondWin'
UMU_URL=https://github.com/Open-Wine-Components/umu-launcher/releases/download/1.4.4/umu-launcher-1.4.4-zipapp.tar
UMU_SHA256=eb590691841f7fad3fc3ad8fd5db4ccb87849fe7948e62b28ece7a4ee48cc851
GE_URL=https://github.com/GloriousEggroll/proton-ge-custom/releases/download/GE-Proton11-7/GE-Proton11-7-x86_64.tar.gz
GE_SHA512=7db87e9787e20c35cbdac26018431d5794626b626e4067b050684e45a88cc2ca229d7d263519eafb2e168cde5bef57611065d159d3685aaec152ccb9abe3073f
DLL_URL=https://github.com/s1aai/firestorm-wine-fix/releases/download/v1.0.0/ole32.dll
DLL_SHA256=a8477943f5cfaa2fdd939d1938d474e1cb637722b875a679c407e40a9243dfc3
WEBVIEW2_URL='https://go.microsoft.com/fwlink/?linkid=2124701'

app=$HOME/.local/share/elestrals-beyond-linux
compat=$HOME/.local/share/Steam/compatibilitytools.d
proton=$compat/GE-Proton11-7-ole32fix
prefix=${ELESTRALS_PREFIX:-$HOME/Games/elestrals-beyond}
dll=$proton/files/lib/wine/x86_64-windows/ole32.dll
s32=$proton/files/lib/wine/x86_64-windows/secur32.dll
log=$app/setup.log
umu=""

step=""
trap 'echo; echo "!!! Something went wrong during: $step"; echo "!!! Details are in $log"; echo "!!! You can run the same command again; finished steps are skipped."' ERR

say() { step=$1; echo; echo "==> $1"; }
fetch() { curl -fL --retry 3 --progress-bar -o "$2" "$1"; }
check() { echo "$2  $3" | "$1" -c --quiet - >>"$log" 2>&1 || { echo "Download is damaged: $3"; rm -f "$3"; false; }; }
in_prefix() {
    WINEPREFIX=$prefix GAMEID=umu-default PROTONPATH=$proton \
        timeout "$1" "$umu" "${@:2}" </dev/null >>"$log" 2>&1
}
webview2_installed() {
    compgen -G "$prefix/drive_c/Program Files (x86)/Microsoft/EdgeWebView/Application/*/msedgewebview2.exe" >/dev/null
}
find_launcher() {
    find "$prefix/drive_c/users" -iname 'pitonlabs-game-launcher.exe' -print -quit 2>/dev/null || true
}

say "Checking your system"
[ "$(id -u)" -ne 0 ] || { echo "Don't run this with sudo. Run it as your normal user."; exit 1; }
[ "$(uname -m)" = x86_64 ] || { echo "This only works on 64-bit PCs (x86_64)."; exit 1; }
for tool in curl tar sha256sum sha512sum python3 timeout find; do
    command -v "$tool" >/dev/null || { echo "Missing program: $tool. Install it with your package manager and run this again."; exit 1; }
done
python3 -c 'import sys; sys.exit(sys.version_info < (3, 10))' || { echo "Python 3.10 or newer is needed."; exit 1; }
if [ -e "$prefix" ] && ! grep -qs GE-Proton "$prefix/version"; then
    echo "$prefix already exists and wasn't made by this script."
    echo "Move or rename it (or set ELESTRALS_PREFIX to another folder), then run this again."
    exit 1
fi
mkdir -p "$app/downloads" "$compat" "$(dirname "$prefix")"
echo "--- setup started $(date)" >>"$log"
free_gb=$(df -P -BG "$(dirname "$prefix")" | awk 'NR==2 {print int($4)}')
[ "$free_gb" -ge 5 ] || { echo "Only ${free_gb} GB free. Setup needs about 5 GB, plus room for the game itself."; exit 1; }

say "1/6 Finding umu-launcher"
if command -v umu-run >/dev/null; then
    umu=$(command -v umu-run)
    echo "Using the one already installed: $umu"
else
    umu=$app/umu-run
    if [ ! -x "$umu" ]; then
        fetch "$UMU_URL" "$app/downloads/umu.tar"
        check sha256sum "$UMU_SHA256" "$app/downloads/umu.tar"
        tar -xOf "$app/downloads/umu.tar" umu/umu-run >"$umu"
        chmod +x "$umu"
        rm -f "$app/downloads/umu.tar"
    fi
fi

say "2/6 Making the patched Proton (GE-Proton11-7-ole32fix)"
if [ ! -f "$proton/proton" ]; then
    rm -rf "$compat/.elestrals-tmp"
    mkdir -p "$compat/.elestrals-tmp"
    if [ -f "$compat/GE-Proton11-7-x86_64/proton" ]; then
        echo "Copying your existing GE-Proton11-7..."
        cp -a "$compat/GE-Proton11-7-x86_64" "$compat/.elestrals-tmp/"
    elif [ -f "$compat/GE-Proton11-7/proton" ]; then
        echo "Copying your existing GE-Proton11-7..."
        cp -a "$compat/GE-Proton11-7" "$compat/.elestrals-tmp/"
    else
        echo "Downloading GE-Proton11-7 (about 560 MB)..."
        fetch "$GE_URL" "$app/downloads/ge-proton.tar.gz"
        check sha512sum "$GE_SHA512" "$app/downloads/ge-proton.tar.gz"
        echo "Unpacking..."
        tar -xzf "$app/downloads/ge-proton.tar.gz" -C "$compat/.elestrals-tmp"
        rm -f "$app/downloads/ge-proton.tar.gz"
    fi
    mv "$compat/.elestrals-tmp"/GE-Proton11-7* "$proton"
    rmdir "$compat/.elestrals-tmp"
    sed -i 's|^\(\s*\)"GE-Proton11-7[^"]*" // Internal name|\1"GE-Proton11-7-ole32fix" // Internal name|; s|"display_name" "[^"]*"|"display_name" "GE-Proton11-7-ole32fix (ole32 + secur32 fixes)"|' \
        "$proton/compatibilitytool.vdf" || true
    [ -f "$dll.orig" ] || cp -a "$dll" "$dll.orig"
fi
if ! echo "$DLL_SHA256  $dll" | sha256sum -c --quiet - >/dev/null 2>&1; then
    echo "Installing the patched ole32.dll..."
    fetch "$DLL_URL" "$app/downloads/ole32.dll"
    check sha256sum "$DLL_SHA256" "$app/downloads/ole32.dll"
    install -m 555 "$app/downloads/ole32.dll" "$dll"
    rm -f "$app/downloads/ole32.dll"
fi

echo "Checking secur32.dll (fix for stalled network requests)..."
[ -f "$s32.orig" ] || cp -a "$s32" "$s32.orig"
python3 - "$s32" <<'PY'
import hashlib, os, sys
path = sys.argv[1]
ORIGINAL = "4bce50164d7cd97b5c750a3a7709980445ded5ea0f2c36516585fed013ce4138"
PATCHED = "07407f3f46c9089602470e8120d152ece30c4b2f85b7323396f6e5003d7bae73"
data = bytearray(open(path, "rb").read())
digest = hashlib.sha256(data).hexdigest()
if digest == PATCHED:
    print("secur32.dll already has the fix.")
    sys.exit(0)
if digest != ORIGINAL:
    print("secur32.dll is not the expected GE-Proton11-7 file (sha256 " + digest + "); not touching it.")
    sys.exit(2)
for offset, old, new in (
    (0xE196, "89d829d041890424", "29d341891c249090"),
    (0xE1DB, "2b18", "9090"),
):
    old, new = bytes.fromhex(old), bytes.fromhex(new)
    if bytes(data[offset:offset + len(old)]) != old:
        print("Unexpected bytes at offset %#x; not patching." % offset)
        sys.exit(2)
    data[offset:offset + len(new)] = new
if hashlib.sha256(data).hexdigest() != PATCHED:
    print("Patched file does not match the expected checksum; not writing it.")
    sys.exit(2)
tmp = path + ".new"
with open(tmp, "wb") as f:
    f.write(data)
os.chmod(tmp, 0o555)
os.replace(tmp, path)
print("Applied the secur32.dll fix (10 bytes changed).")
PY

say "3/6 Creating the Windows environment in $prefix"
if [ ! -f "$prefix/system.reg" ]; then
    echo "The first time, this may also download the Steam Linux Runtime and can take a few minutes..."
    in_prefix 1800 winecfg /v win11
fi

say "4/6 Installing Microsoft WebView2 (needed by the launcher)"
if ! webview2_installed; then
    echo "Downloading WebView2 (about 200 MB)..."
    fetch "$WEBVIEW2_URL" "$app/downloads/webview2.exe"
    echo "Installing (takes a minute or two, nothing will show on screen)..."
    in_prefix 900 "$app/downloads/webview2.exe" /silent /install || true
    in_prefix 120 wineboot -k || true  # stop Edge's updater if it is still running
    webview2_installed || { echo "WebView2 did not install."; false; }
    rm -f "$app/downloads/webview2.exe"
fi

say "5/6 Installing the Elestrals Beyond launcher"
launcher=$(find_launcher)
if [ -z "$launcher" ]; then
    fetch "$INSTALLER_URL" "$app/downloads/elestrals-setup.exe"
    in_prefix 600 "$app/downloads/elestrals-setup.exe" /S || true
    launcher=$(find_launcher)
    if [ -z "$launcher" ]; then
        echo "Silent install did not finish. Trying the normal installer (a window may appear)..."
        in_prefix 900 "$app/downloads/elestrals-setup.exe" || true
        launcher=$(find_launcher)
    fi
    [ -n "$launcher" ] || { echo "The launcher did not install."; false; }
    rm -f "$app/downloads/elestrals-setup.exe"
fi
echo "Launcher found: $launcher"

say "6/6 Adding Elestrals Beyond Launcher to your apps menu"
cat >"$app/start.sh" <<EOF
#!/usr/bin/env bash
# Starts the Elestrals Beyond launcher. Made by install-elestrals-beyond.sh.
export WINEPREFIX=$(printf %q "$prefix") GAMEID=umu-default PROTONPATH=$(printf %q "$proton")
exec $(printf %q "$umu") $(printf %q "$launcher") "\$@"
EOF
chmod +x "$app/start.sh"
mkdir -p "$HOME/.local/share/applications"
cat >"$HOME/.local/share/applications/elestrals-beyond-launcher.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Elestrals Beyond Launcher
Comment=Elestrals Beyond launcher (runs with GE-Proton)
Exec="$app/start.sh"
Icon=applications-games
Terminal=false
Categories=Game;
EOF
command -v update-desktop-database >/dev/null && update-desktop-database "$HOME/.local/share/applications" >/dev/null 2>&1 || true

trap - ERR
echo
echo "=============================================================="
echo " ALL DONE!"
echo
echo " The Elestrals Beyond launcher is starting now."
echo " Next time, open \"Elestrals Beyond Launcher\" from your apps menu,"
echo " or run: $app/start.sh"
echo
echo " Log in, then install the game from inside the launcher."
echo
echo " Lutris (optional): Add locally installed game, runner Wine,"
echo "   Executable: $launcher"
echo "   Wine prefix: $prefix"
echo "   Wine version: GE-Proton11-7-ole32fix"
echo " Do NOT set WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS."
echo "=============================================================="
setsid -f "$app/start.sh" >/dev/null 2>&1 </dev/null
}

main "$@"
