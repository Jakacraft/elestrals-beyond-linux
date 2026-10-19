# Elestrals Beyond on Linux (Wine / Proton)

One-command installer that gets the **Elestrals Beyond** launcher running on Linux.

The launcher crashes on startup under stock Wine/Proton, and even after that is fixed its network requests stall ("Couldn't load game information... could not securely load this game"). This script builds a patched copy of GE-Proton11-7 that fixes both problems, then installs WebView2 and the launcher into a fresh Wine prefix.

> **Unofficial.** Not affiliated with Elestrals, Piton Labs, NetDeck.gg, Wine, GE-Proton or Valve. Elestrals does not officially support Linux, so please don't ask their support for help with this. Use at your own risk and check the game's terms of service yourself.

## Status

- Tested on **one machine**: Garuda Linux (Arch-based), KDE Plasma on Wayland (XWayland), AMD GPU, launcher version 0.0.62. On that machine the launcher opens, logs in, loads the game details, and the game installs and launches.
- Other distros and setups are untested. Reports are welcome (see [Troubleshooting](#troubleshooting)).
- This is a **temporary workaround**. See [When you won't need this](#when-you-wont-need-this).

## Quick start

```bash
git clone https://github.com/YOUR-USERNAME/elestrals-beyond-linux.git
cd elestrals-beyond-linux
bash install-elestrals-beyond.sh
```

- Run it with `bash` (not `sh`), as your normal user. **Do not use `sudo`.**
- It takes about 5 to 10 minutes and downloads roughly 800 MB the first time.
- When it finishes, the launcher starts. Log in and install the game from inside the launcher.
- Next time, start it from your apps menu ("Elestrals Beyond Launcher") or run `~/.local/share/elestrals-beyond-linux/start.sh`.

The script is safe to re-run: finished steps are skipped.

### Requirements

- 64-bit Linux (x86_64)
- `curl`, `tar`, `sha256sum`, `sha512sum`, `python3` (3.10 or newer), `timeout`, `find`
- About 5 GB free for setup, plus space for the game itself
- Internet access
- `umu-run` (umu-launcher) is used if installed; otherwise the script downloads a copy

## What the script does

1. Finds `umu-run`, or downloads umu-launcher 1.4.4.
2. Makes `GE-Proton11-7-ole32fix`, a **separate copy** of GE-Proton11-7 (copied from your existing one if you have it, otherwise downloaded and checksum-verified) with two fixed DLLs:
   - a patched `ole32.dll` (fixes the startup crash)
   - a patched `secur32.dll` (fixes the stalled network requests)
3. Creates a new Wine prefix at `~/Games/elestrals-beyond`, set to Windows 11.
4. Installs the Microsoft WebView2 runtime into it.
5. Downloads and installs the Elestrals Beyond launcher from the official link (`https://elestra.ls/DLBeyondWin`).
6. Adds an apps-menu entry and a `start.sh`, then starts the launcher.

Nothing outside your home folder is changed.

| Path | What it is |
| --- | --- |
| `~/Games/elestrals-beyond` | Wine prefix (the launcher and the game live here) |
| `~/.local/share/Steam/compatibilitytools.d/GE-Proton11-7-ole32fix` | Patched Proton copy |
| `~/.local/share/elestrals-beyond-linux` | `start.sh`, setup log, temporary downloads |
| `~/.local/share/applications/elestrals-beyond-launcher.desktop` | Apps-menu entry |

Set `ELESTRALS_PREFIX=/some/dir` to put the prefix somewhere else. The script refuses to touch an existing folder at that path unless it created it.

### Using it from Lutris (optional)

1. **+**, then **Add locally installed game**.
2. Runner: **Wine**. Wine version: `GE-Proton11-7-ole32fix` (restart Lutris if it isn't listed).
3. Executable: the `pitonlabs-game-launcher.exe` path printed at the end of the script
   (usually `~/Games/elestrals-beyond/drive_c/users/steamuser/AppData/Local/elestrals-launcher/pitonlabs-game-launcher.exe`).
4. Wine prefix: `~/Games/elestrals-beyond`.
5. Don't set `WEBVIEW2_ADDITIONAL_BROWSER_ARGUMENTS`: it overrides the launcher's own WebView2 flags and can crash its GPU process.

### Uninstall

This also deletes the game once the launcher has downloaded it:

```bash
rm -rf ~/Games/elestrals-beyond ~/.local/share/elestrals-beyond-linux \
  ~/.local/share/Steam/compatibilitytools.d/GE-Proton11-7-ole32fix \
  ~/.local/share/applications/elestrals-beyond-launcher.desktop
```

## The two bugs

### 1. Startup crash in `ole32` (Wine bug 60225)

The launcher is a Tauri 2 app that embeds WebView2. Tauri's webview layer calls `RevokeDragDrop` on every child window of the webview, including windows owned by WebView2's *separate* browser process. Wine's `RevokeDragDrop` doesn't check which process owns the window, and tries to release a drop-target pointer that only exists in the other process. The launcher's main thread dies with a page fault in `ole32`:

```
=> 0 ole32 (+0x34d7d)
   1 pitonlabs-game-launcher (+0x286a86)
   2 pitonlabs-game-launcher (+0x95e9d3)
   3 user32 ...
```

This is [Wine bug 60225](https://bugs.winehq.org/show_bug.cgi?id=60225), and it affects Tauri/WebView2 apps in general. The fix is a small process-ownership check in `RevokeDragDrop`. This script downloads a patched `ole32.dll` built for GE-Proton11-7 by [s1aai/firestorm-wine-fix](https://github.com/s1aai/firestorm-wine-fix).

### 2. Stalled network requests in `secur32` (fixed upstream in Wine 11.6)

After the launcher starts, the game details never load. The launcher's requests go through Wine's TLS layer (`secur32`). When a secure message arrives in two pieces, Wine tells the app how many bytes are still missing. In the Wine that GE-Proton11-7 is built from, the second buffer gets the **whole message size** instead of the missing byte count: 5,874 instead of 82 in the case that was traced.

The launcher's network library believes that number, reads the 82 bytes that exist, and waits for another 5,792 that never arrive. After about 9 seconds it gives up and retries, three times, then shows the error. Login worked because those responses arrived as several complete messages, and Windows works because it reports the right number.

How this was pinned down: a packet capture showed the full response reached the machine, a Wine `+secur32,+winsock` trace showed the read pattern, and comparing Wine's release tags showed the bug present in 11.5 and fixed in 11.6.

**The patch** changes 10 bytes in GE-Proton11-7's `secur32.dll` so the missing-byte count is computed once and used for both buffers, like the upstream fix. Before (x86-64, offsets in the file):

```
E196  mov eax, ebx
E198  sub eax, edx
E19A  mov [r12], eax        ; first buffer = missing bytes (82)
...
E1DB  sub ebx, [rax]        ; second buffer = whole size minus 0  <-- the bug (5,874)
E1DD  mov dword [rax+4], 4
E1E4  mov [rax], ebx
```

After:

```
E196  sub ebx, edx          ; ebx = missing bytes
E198  mov [r12], ebx        ; first buffer = missing bytes
E19C  nop / nop
...
E1DB  nop / nop             ; ebx still holds the missing bytes
E1DD  mov dword [rax+4], 4
E1E4  mov [rax], ebx        ; second buffer = missing bytes too
```

| File | SHA-256 |
| --- | --- |
| original `secur32.dll` (GE-Proton11-7) | `4bce50164d7cd97b5c750a3a7709980445ded5ea0f2c36516585fed013ce4138` |
| patched `secur32.dll` | `07407f3f46c9089602470e8120d152ece30c4b2f85b7323396f6e5003d7bae73` |
| patched `ole32.dll` | `a8477943f5cfaa2fdd939d1938d474e1cb637722b875a679c407e40a9243dfc3` |

The script only patches a file that matches the original hash, verifies the result against the patched hash, and keeps a backup as `secur32.dll.orig`. The original and patched code paths were also run in an emulator to confirm that the patched code stores the correct count in both buffers. To restore the original, copy `secur32.dll.orig` (or `ole32.dll.orig`) back over the patched file, or delete the `GE-Proton11-7-ole32fix` folder.

## Trust and security

- The `ole32.dll` is a **third-party build** (from the project linked above), verified by SHA-256, but it does not come from Wine or GloriousEggroll. Read the script before running it, and check the linked repository if you want to rebuild it yourself.
- The `secur32.dll` patch is derived from the GE-Proton11-7 binary itself and is small enough to inspect (table above).
- The GE-Proton11-7 download is verified by SHA-512. WebView2 comes from Microsoft's download link. The launcher comes from the official Elestrals link and is **not** checksum-verified, because the vendor can change it at any time.
- This repository does not redistribute any Elestrals or Microsoft software.
- Nothing runs as root.

## Troubleshooting

- **Setup log:** `~/.local/share/elestrals-beyond-linux/setup.log`. If a step fails, re-running the script resumes from where it stopped.
- **Launcher won't start or closes immediately:** run `~/.local/share/elestrals-beyond-linux/start.sh` in a terminal and read the output. To capture Wine errors, run it as `WINEDEBUG=err+all,fixme-all ~/.local/share/elestrals-beyond-linux/start.sh`. Note that some shells (such as fish) don't accept bash-only syntax, so wrap multi-line helper commands in `bash -c '...'`.
- **"secur32.dll is not the expected GE-Proton11-7 file":** the DLL in your `GE-Proton11-7-ole32fix` folder was modified or came from a different build. The script refuses to patch it. Delete that folder and re-run.
- **"WebView2 did not install":** check the setup log, make sure you have free disk space, and re-run.
- **Harmless messages:** `Proton: Error: unable to use parent for game drive, path /home` and `Xalia ... TaskCanceledException` warnings can be ignored.
- **Game details still don't load:** open an issue and include the output of `start.sh` and the setup log. Please mention your distro, desktop/session type, and GPU.

## When you won't need this

- The `ole32` fix is needed until Wine fixes bug 60225 and GE-Proton ships it.
- The `secur32` fix is needed only for Wine older than 11.6. GE-Proton11-7 is based on Wine 11.0.

Once a GE-Proton release includes both, a normal GE-Proton plus a plain Wine prefix should work. Check the Wine bug and the GE-Proton release notes before assuming so.

## Credits

- [s1aai/firestorm-wine-fix](https://github.com/s1aai/firestorm-wine-fix): the patched `ole32.dll` and the structure this script is adapted from (LGPL-2.1-or-later).
- The reporter and commenters on [Wine bug 60225](https://bugs.winehq.org/show_bug.cgi?id=60225), who identified the root cause of the `ole32` crash.
- [GloriousEggroll](https://github.com/GloriousEggroll/proton-ge-custom) (GE-Proton), [Wine](https://www.winehq.org/), and [umu-launcher](https://github.com/Open-Wine-Components/umu-launcher).
- Written with help from an AI assistant (Claude) and tested by the author on one machine.

## License

This script is adapted from the project above, so it is released under the same license: **LGPL-2.1-or-later**. See [LICENSE](LICENSE).

Elestrals and Elestrals Beyond are trademarks of their respective owners.
