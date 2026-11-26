# Blossom farm kit

Everything needed to turn one computer, a Windows PC or a Mac, into a phone
farm that [Blossom CRM](https://github.com/fyhcrew-art) can drive: one
installer per system, the small services that sit around the farm software,
and the guide.

Your iPhones stay at your place, plugged into your computer. The computer
runs [GADS](https://github.com/shamanec/GADS), an open-source device farm. A
Cloudflare Tunnel gives it three public https addresses. Blossom CRM shows
you one command for the farm computer; the installer it starts sets
everything up and hands the addresses and the two secrets to Blossom by
itself. You confirm the computer in Blossom, and your phones appear there.

There is no onboarding call. This repository is the whole of it.

The guide has two tracks, **Windows** and **macOS**. Hardware, phones,
network and security are the same for both; where a step differs, both are
given side by side.

## The 10-minute overview

```
   iPhones --USB--> your computer (C:\farm or /opt/farm)         the internet
                    +---------------------------------------+
                    | MongoDB            127.0.0.1:27017    |
                    | GADS hub           127.0.0.1:10000 <--+-- https://farm-hub.yourdomain.com
                    | GADS provider      127.0.0.1:10001    |
                    |   ^ provider gate  127.0.0.1:10002 <--+-- https://farm-provider.yourdomain.com
                    | restart service    127.0.0.1:19999 <--+-- https://farm-restart.yourdomain.com
                    | keep-available     (talks to the hub) |
                    | cloudflared  --- outgoing connection -+--> Cloudflare
                    +---------------------------------------+
```

* The five programs in the drawing listen on `127.0.0.1` only;
  `cloudflared` connects *outwards* to Cloudflare, and Cloudflare gives the
  three host names a valid certificate. You open no port on your router.
* One exception you should know: for each connected iPhone, GADS opens a few
  more ports on all addresses of the computer. The installer closes them to
  other computers on your network: with Windows Firewall rules on Windows,
  with a packet filter rule on macOS. Keep that firewall switched on
  ([`docs/security.md`](docs/security.md), section 1).
* **Hub**: the list of phones and the logins. Blossom signs in here.
* **Provider**: talks to the phones. It has no login of its own, so the kit
  never publishes it directly: the public address leads to the **provider
  gate**, which only lets requests through that carry a session the hub
  accepts. ([`docs/security.md`](docs/security.md) explains why this matters.)
* **Restart service**: lets the "Services" panel in Blossom show what is
  running and restart it. Protected by a random secret.
* **keep-available**: a GADS hub refuses commands ("device is not available",
  error 422) while nobody is subscribed to its device list. This script stays
  subscribed.

All of it starts with the computer, with nobody signed in:

| | Windows services | macOS launchd services |
|---|---|---|
| database | `MongoDB` | `blossom-farm.mongodb` |
| hub, provider | `GadsHub`, `GadsProvider` | `blossom-farm.hub`, `blossom-farm.provider` |
| gate, keep-available | `FarmGate`, `KeepAvailable` | `blossom-farm.gate`, `blossom-farm.keep-available` |
| restart service, tunnel | `FarmRestart`, `Cloudflared` | `blossom-farm.restart`, `blossom-farm.cloudflared` |

## What you need

| | |
|---|---|
| A computer | **Windows:** a PC with a 64-bit (x64) processor, Windows 10 version 1809 or later, or Windows 11. **macOS:** a Mac with Apple Silicon and macOS 26 or later, or an Intel Mac with macOS 15 or later. Either way: 10 GB free on the system disk, always on, wired to the internet, and used for the farm only (see `docs/security.md`). A desktop computer: a laptop with its lid closed is asleep. |
| How powerful | Neither GADS nor Blossom publishes a minimum. Each live screen that somebody is watching is one video encoder (FFmpeg) running on the computer. Start with a recent desktop processor and 16 GB of memory and watch the load. |
| On a Mac, also | [Homebrew](https://brew.sh), installed by you as your normal user before the installer runs. FFmpeg comes from it (the FFmpeg project publishes no build for macOS of its own), and on Apple Silicon the OpenSSL library that GADS needs to sign WebDriverAgent in the hub page. Everything else the installer downloads itself. On an Intel Mac, Homebrew has no ready-made packages and builds FFmpeg from its source, which takes long; a static FFmpeg for Intel Macs (the FFmpeg download page links one), named once with `sudo bash install.sh --ffmpeg <path>`, does the same job. It must include the libx264 encoder. The installer copies it into `/opt/farm/bin/tools` and uses it from there, also in later runs; the file you downloaded is not needed afterwards. |
| iPhones | iOS 16 or later is what this kit was written for. iOS 17.0 to 17.3 is not supported by GADS 6 (update the phone to 17.4 or later). No passcode, Auto-Lock "Never", Developer Mode on. |
| USB | One data cable per phone and **powered** USB hubs. This is practice, not a rule from GADS: a phone that is awake all day draws more than an unpowered port gives. |
| A domain | A domain name you own, with its DNS at Cloudflare (free plan is enough). The installer creates three sub-domains on it. |
| A Cloudflare account | Free. Needed for the tunnel. |
| An Apple Developer account | Yours. WebDriverAgent, the helper app on each phone, is downloaded from the GADS author and must be signed with your own Apple account: the paid Apple Developer Program (a signature lasts a year). The kit contains no WebDriverAgent and cannot sign for you. See [`docs/phones.md`](docs/phones.md). |
| Blossom CRM | A workspace with Phone Farm access, and somebody who may manage its farm (an admin): that person gets the command and confirms the computer. |

## Step by step

### 1. Before you start

1. Add your domain to Cloudflare and wait until Cloudflare shows it as
   "Active" ([`docs/network.md`](docs/network.md), section 1).
2. Have a password manager ready: the installer makes you choose one
   password, for the farm's own administrator page.
3. On a Mac: install [Homebrew](https://brew.sh) as your normal user.

### 2. Get the command from Blossom

In Blossom CRM open **Phone Farm → Farm setup → Connect a computer**, say
whether the farm computer is a Windows PC or a Mac, and copy the command it
shows. The command carries a **pairing code**: it works once, for 30 minutes,
and only for your workspace. Leave the page open: it follows the
installation.

If Farm setup in your Blossom has no **Connect a computer**, your Blossom
does not offer the command: set the farm up as described under "Without the
command (manual entry)" in step 4. The result is the same farm.

Copy the command yourself, from your own Blossom, signed in. Do not run a
command that somebody sent you, however genuine it looks: it connects the
farm to whoever made it (`docs/security.md`, section 9).

### 3. Run it on the farm computer

**Windows.** Press Start, type `powershell`, right-click **Windows
PowerShell**, choose **Run as administrator**, paste the command, press
Enter.

**macOS.** Signed in as an administrator of the Mac, open **Terminal**
(Applications → Utilities), paste the command, press Enter. `sudo` asks for
the password of your Mac user. Do not start from a root shell: Homebrew only
works for a normal user.

What the command does before anything is installed
([`docs/security.md`](docs/security.md), section 9, has the details):

1. It downloads one small file, `bootstrap.ps1` or `bootstrap.sh`, from this
   repository at one exact commit, and compares its SHA-256 with the value
   that is written in the command. If they differ it stops and runs nothing.
2. That file downloads the kit at the same commit, as the archive GitHub
   makes of it, and checks every file in it against the kit's list of
   checksums (`MANIFEST.sha256`), whose own SHA-256 the file carries. One
   file that is changed, missing or too many, and it stops and runs nothing.
3. The kit is put into `C:\blossom-farm-kit` (Windows) or
   `/opt/blossom-farm-kit` (macOS), and its installer starts, with the
   address of your Blossom and the pairing code.

The installer asks for three things only: the new password of the farm's
administrator (typing is hidden), your Cloudflare sign-in (in a browser
window it opens), and your domain. From the domain it proposes the three host
names `farm-hub.`, `farm-provider.` and `farm-restart.yourdomain.com`; press
Enter to take them. Read a script before you run it with full rights: these
are plain text.

What the installer does, in order (it prints each step):

| Step | Windows (`install.ps1`) | macOS (`install.sh`) |
|---|---|---|
| 1 Checks | Administrator, 64-bit Windows 10 1809+/11, 10 GB free. | Run with `sudo`, macOS version, Apple Silicon or Intel, not under Rosetta, 10 GB free. |
| 2 Folders | Creates `C:\farm`, readable by Administrators and SYSTEM only. | Creates `/opt/farm` and the hidden service account `_blossomfarm`. Root owns the folder; that account may read it; nobody else may open it. |
| | On both: a farm folder that already exists, has content and was not made by this kit stops the installer. It will not adopt a folder somebody else prepared. | |
| | On both, when started with a pairing code: tells Blossom about this computer (its name, its system, the kit version; no address and no secret yet). Blossom shows "Computer connected". A code that is wrong, used or expired is reported here, and the installation continues without pairing. | |
| 3 Programs | Installs, with `winget` and at pinned versions: NSSM, MongoDB, Node.js, FFmpeg, cloudflared. Checks for Apple's USB support (iTunes from Apple's installer, see `docs/phones.md`). | Downloads Node.js, MongoDB and cloudflared from their publishers at pinned versions into `/opt/farm/bin` and checks the SHA-256 of each. Installs FFmpeg (and OpenSSL on Apple Silicon) with Homebrew. Apple's USB support is part of macOS. |
| | On both: programs that are already installed are kept as they are. | |
| 4 GADS | On both: downloads the GADS hub from its publisher's release and the patched provider from this repository (its branch `dist`, at the commit `versions.json` names), and checks the SHA-256 of both against `versions.json`. A file with a wrong checksum is deleted, not used. | |
| 5 MongoDB | On both: starts it and checks that it listens on this computer only. | On macOS it is the kit's own MongoDB, with its data in `/opt/farm/data`. |
| 6 Hub + password | On both: starts the hub (on this computer only). GADS creates its administrator `admin` with a default password that anybody can look up; **the installer makes you replace it before anything is reachable from outside.** You choose it (14+ characters), typing is hidden. | |
| 7 Users + provider | On both: creates the hub user `blossom` (random password, for Blossom CRM), the internal user `farm-keepalive`, and the provider record (`Provider1` unless you name another). | |
| 8 Host names | On both: asks for your domain and proposes the three host names (`-Domain` / `--domain` answers the question in advance; `-HubHost`, `-ProviderHost`, `-RestartHost` / `--hub-host`, `--provider-host`, `--restart-host` name them one by one). | |
| 9 Tunnel | On both: opens the Cloudflare sign-in in a browser, creates the tunnel `blossom-farm`, creates the three DNS records, writes and validates the tunnel configuration. | |
| 10 Restart secret | On both: generates it (256 random bits). | |
| 11 Services | Adds the Windows Firewall rules for the provider's per-phone ports. Creates the Windows services (auto-start, restart on crash, rotating logs in `C:\farm\logs`) and starts them; the tunnel last. Switches off sleep on mains power. | Loads the packet filter rule for the provider's per-phone ports. Creates the launchd services (start with the Mac, restart on crash, logs in `/opt/farm/logs`, rotated at 10 MB) and starts them; the tunnel last. Switches off sleep, and switches on "start up after a power failure". |
| 12 Self-test | On both: performs the checks of Blossom's "Test connection" against your public addresses, sending its requests the way Blossom's servers do, plus five of its own: that the provider and the restart service refuse a stranger, and that the tunnel refuses the three kinds of hub path GADS leaves without a login. | |
| Blossom | On both, when paired: sends the three addresses, the provider nickname, the hub user with its password and the restart secret to your Blossom, over https, to the address the command named and to no other. Then it waits, up to ten minutes, for Blossom's own check of the farm and for your confirmation (next step). | |

When the farm was sent to Blossom, the installer shows no password and no
secret: there is nothing to copy. If pairing was not asked for, or did not
work, it prints the values for manual entry instead ("Without the command",
below).

The installer can be run again at any time. It keeps the database, the
tunnel, the secrets and the passwords, and repairs what is missing. A farm
that is running keeps running: services whose settings and files did not
change are not restarted, and if the installer stops half-way (a wrong
password, Ctrl+C, an error) it starts again whatever it had stopped.

**Appium: off unless you ask for it.** No screen of Blossom CRM needs Appium:
the phone list, Control, live video, the AI assistant, downloads to a phone
(the "Scarica farm" Shortcut) and the Services panel all work without it, and
GADS marks Appium as optional. Only one older Blossom API
route (`/api/gads/drive-download`) drives a phone through Appium on the
provider. If you call that route, or want Appium sessions for your own
automation, include it:

```
powershell -ExecutionPolicy Bypass -File .\install.ps1 -WithAppium     (Windows)
sudo bash install.sh --with-appium                                     (macOS)
```

This also installs Appium, its iOS driver and the GADS plugin under the farm
folder and lets the provider start one Appium server per phone. It can be
added later by running the installer again with the switch. Read
`docs/security.md` first, sections 3 and 8:

* with Appium on, the tunnel rule that refuses "appium" paths on the hub
  address is what stands between the internet and those servers;
* only the versions of the three packages themselves are pinned in
  `versions.json`. The hundreds of packages they depend on are chosen by npm
  on the day you install and are **not** checksum-verified by this kit,
  unlike the GADS programs.

### 4. Confirm the computer in Blossom

The page in Blossom you left open now shows the computer that used the code:
its name, its system, the country it connected from, and the three addresses
it sent. Blossom has already called the farm from its servers and shows what
it found ("3 phones found"; with no phone yet, "no phone yet", which is
expected). **Check that the name and the addresses are yours, then press
Confirm.** Until you do, Blossom does not use the site. If you do not
recognise what is shown, press Decline: somebody else used your command.

The installer notices the confirmation and ends with
`Blossom sees your farm: 3 phones.` If you confirm later, nothing is lost;
the status script shows where the pairing stands.

From then on the farm computer holds a **farm token**
(`config/pairing.json` in the farm folder). With it the scripts of this kit
send Blossom new credentials when you rotate them, and nothing else: the
token cannot read anything from Blossom and cannot touch any other site.
Blossom lists the paired computer under the site and can unpair it at any
time.

A paired computer stays with its workspace. If a command from **another**
workspace (or another Blossom) is run on it, the installer shows both and
goes on only when you type the word `replace`; without a keyboard it
refuses, unless the command ends in `-ReplacePairing` / `--replace-pairing`.
A new command from the same workspace needs no question.

#### Without the command (manual entry)

The kit also works without pairing:

1. On the farm computer, download the kit: open
   <https://github.com/fyhcrew-art/blossom-farm-kit>, press the green
   **Code** button and choose **Download ZIP** (the direct address is
   <https://github.com/fyhcrew-art/blossom-farm-kit/archive/refs/heads/main.zip>).
   The archive holds one folder, `blossom-farm-kit-main`; rename it to
   `blossom-farm-kit`. This download is protected by the https connection to
   GitHub and by nothing else; the command from Blossom checks more
   (`docs/security.md`, section 9). Where to put the folder:
   * *Windows:* to `C:\blossom-farm-kit`, directly on the drive. The scripts
     run as Administrator, so the installer locks this folder
     (Administrators and SYSTEM may change it, others may read it), and it
     refuses to run from a folder that cannot be protected that way, such as
     one inside Downloads or Documents. Keep the folder: the maintenance
     scripts are in it.
   * *macOS:* anywhere you can reach from Terminal, for example
     `blossom-farm-kit` directly in your home folder (macOS asks for an extra
     permission before Terminal may read Downloads, Documents or the
     Desktop). The scripts run as root, so the installer first copies the
     kit to `/opt/blossom-farm-kit`, which only root can change, and
     continues from there. That copy is the kit folder from then on; the one
     you unpacked can be deleted.
2. Run the installer inside it:

   ```
   powershell -ExecutionPolicy Bypass -File .\install.ps1     (Windows, in an Administrator PowerShell)
   sudo bash install.sh                                        (macOS, in Terminal)
   ```

   `-ExecutionPolicy Bypass` applies to this one command only; it is needed
   because Windows does not run downloaded scripts by default.
3. At the end it prints what to enter in Blossom:

   ```
      Hub address ............ https://farm-hub.yourdomain.com
      Provider address ....... https://farm-provider.yourdomain.com
      Provider nickname ...... Provider1
      Hub user ............... blossom
      Hub password ........... (shown once)
      Restart service address  https://farm-restart.yourdomain.com
      Restart secret ......... (shown once)
   ```

   **The hub password and the restart secret are shown once and written to
   no log.** In Blossom CRM open **Phone Farm → Farm setup** and the form
   with the addresses: it is behind **Connect a farm** (or **Connect
   another site**); where Blossom offers **Connect a computer**, it is
   behind **Advanced: enter the addresses yourself**. Paste the values (the
   restart service goes under "Restart service (optional)"), press **Test
   connection**, then **Save and connect**. With no phone yet, the step "Phones" says *Check*:
   that is expected.

A farm that was installed this way can be paired later: get the command from
Blossom (step 2) and run it on the farm computer. It keeps everything that
is set up, gives the hub user `blossom` a new password (the old one is
stored nowhere on the computer, and Blossom needs one), and replaces the
site you entered by hand once you confirm.

### 5. Add the phones

Follow [`docs/phones.md`](docs/phones.md): prepare each iPhone, download
WebDriverAgent from the GADS author and sign it with your Apple account,
switch iOS on for the provider, register the phones in the hub. Do one phone
completely before the others.

### 6. Check that it survives a restart

Restart the computer and touch nothing: do not sign in. Within a few minutes
the site in Blossom should read *Connected*. The status script shows the
state on the computer.

On a Mac, **FileVault** decides whether this works. With FileVault on, a Mac
that restarts waits for somebody to type the password before it starts
anything, the farm included; after a power cut the farm stays off until
somebody is at the keyboard. `sudo fdesetup status` says whether it is on
(System Settings → Privacy & Security → FileVault switches it). With it off,
the farm comes back by itself, and whoever takes the Mac can read its disk.
Which of the two you accept is your decision; `docs/security.md`, section 8.

## Day to day

Run these with full rights, inside the kit folder: `C:\blossom-farm-kit` on
Windows, `/opt/blossom-farm-kit` on macOS.

```
powershell -ExecutionPolicy Bypass -File .\scripts\<name>.ps1     (Windows, in an Administrator PowerShell)
sudo bash scripts/<name>.sh                                        (macOS, in Terminal)
```

Options are written `-Logs` on Windows and `--logs` on macOS.

| Script | What it is for |
|---|---|
| `status` | The pairing with Blossom, services, ports, the firewall, program checksums, disk. With `-Logs` / `--logs` it adds the last lines of every log with session tokens and your host names masked: copy **this output** when you ask for help, never a log file itself (`docs/security.md`, section 4). Changes nothing. |
| `self-test` | The connection test against the public addresses. It asks for the password of one hub user. On a paired computer that is the hub administrator `admin`, whose password you chose: the password of `blossom` went to Blossom and nobody else has it. On a computer that is not paired it is `blossom`, with the password the installer showed. `-HubUser <name>` / `--hub-user <name>` names another. |
| `rotate-secrets` | New restart secret (`-RestartSecret` / `--restart-secret`), new password for `blossom` (`-HubUser` / `--hub-user`), for `admin` (`-AdminPassword` / `--admin-password`), or all (`-All` / `--all`). Use it whenever somebody with Phone Farm access leaves. On a paired computer the new hub password and restart secret go to Blossom by themselves and are not shown; otherwise they are shown once, to be entered in Blossom. |
| `update` | Moves the farm to the versions of a newer kit: `-Check` / `--check` says whether one is released, `-Latest` / `--latest` fetches it, checks it and updates the farm; without an option it updates the farm with the kit it is in. `-Rollback` / `--rollback` goes back. On a paired computer it tells Blossom the new versions. |
| `export-farm`, `import-farm` | Move the farm to another computer without changing anything in Blossom. An archive made on Windows can be imported on a Mac, and the other way round (see below). |
| `uninstall` | Removes the services and the kit's firewall rules; with `-RemoveData` / `--remove-data` also the tunnel, the database and the farm folder. `-Unpair` / `--unpair` also gives up the pairing with Blossom (with `-RemoveData` the script asks). |

Where things are:

| Windows | macOS | What |
|---|---|---|
| `C:\farm\bin` | `/opt/farm/bin` | the hub (`GADS`) and the provider (`GADS-drag`); on Windows also `nssm.exe`; on macOS also Node.js, MongoDB and cloudflared |
| `C:\farm\services` | `/opt/farm/services` | the service scripts |
| `C:\farm\config` | `/opt/farm/config` | `farm.json` (host names, no secrets), `restart-secret.txt`, `keep-available.json`, `pairing.json` (the farm token and the address of your Blossom, on a paired computer), `cloudflared` (tunnel configuration and credentials) |
| `C:\farm\logs` | `/opt/farm/logs` | one log per service, rotated at 10 MB. Windows deletes rotated files after 30 days; macOS keeps the last ten, compressed. |
| (in `C:\farm\logs`) | `/opt/farm/logs-root` | macOS: the logs of the two services that run as root, `restart-server.log` and `firewall.log`, in a folder only root can open |
| `C:\farm\Provider1` | `/opt/farm/Provider1` | the provider's own folder: its log, per-phone logs, cached pairings |
| `C:\farm\export` | `/opt/farm/export` | archives written by `export-farm` (every secret of the farm: move them to an encrypted medium and delete them) |
| MongoDB's own folder | `/opt/farm/data` | the database |

**Moving a farm between Windows and macOS.** The archive has the same format
on both. What it carries over: the GADS database (phones, users, the uploaded
WebDriverAgent), the tunnel credentials, the host names, the restart secret
and the pairing with Blossom, so nothing changes in Blossom, and the
provider's cached phone pairings. (Because the pairing moves with the farm,
do not unpair when you uninstall the old computer.) What it does not carry: the pairing records the operating system
keeps for Apple's own software, which do not move from one system to the
other. A phone that does not accept the cached pairing asks "Trust This
Computer?" once on the new computer.

## Updating

* **GADS and the kit's services**: in the kit folder
  (`C:\blossom-farm-kit`, `/opt/blossom-farm-kit`) run the `update` script
  with `-Check` / `--check` to see whether a newer kit is released, and with
  `-Latest` / `--latest` to fetch it and update the farm with it:

  ```
  powershell -ExecutionPolicy Bypass -File .\scripts\update.ps1 -Latest     (Windows, in an Administrator PowerShell)
  sudo bash scripts/update.sh --latest                                       (macOS, in Terminal)
  ```

  The script asks this repository which kit is released, downloads exactly
  that commit from GitHub, checks every file against the kit's list of
  checksums, and refuses a kit that is not newer than the one you have or
  that names another file for a program version you already have
  (`docs/security.md`, section 9, says what this protects against and what
  it does not). Before it replaces anything it prints the commit and the
  versions of the kit, of GADS and of the provider, old and new. The kit
  that was in the folder is kept next to it, as
  `blossom-farm-kit.previous`. A kit you downloaded and unpacked yourself works too: run
  its `update` script without an option. Only versions that a kit pins are
  installed: the hub and the patched provider must match each other, and the
  patch is made against a specific GADS version. Do not replace the GADS
  programs by hand. If a kit changed the tunnel configuration or the
  services, the README of that kit says so here, and the installer has to be
  run once as well; this kit needs nothing of the kind.
* **The other programs**: `update` leaves them alone.
  * *Windows* (MongoDB, Node.js, FFmpeg, cloudflared, installed with winget):
    stop the farm services first
    (`Stop-Service Cloudflared, KeepAvailable, FarmRestart, FarmGate, GadsProvider, GadsHub`),
    run `winget upgrade --id <id>` (`versions.json` lists the ids), restart
    the PC, and run the status script.
  * *macOS* (Node.js, MongoDB, cloudflared, in `/opt/farm/bin`): remove the
    services (`sudo bash scripts/uninstall.sh`, which keeps the data), delete
    the folder of the program (`sudo rm -rf /opt/farm/bin/node`, `.../mongodb`
    or the file `.../cloudflared`), and run `sudo bash install.sh` of the
    newer kit: it installs the version that kit pins. Before a MongoDB
    update that changes the first number of its version, read MongoDB's
    upgrade notes. FFmpeg: `brew upgrade ffmpeg`, then restart the provider.
  * cloudflared runs with `--no-autoupdate` on both, so it only changes when
    you change it.
* **Windows or macOS itself**: let it update. The services start by
  themselves after the restart (on a Mac with FileVault on: after somebody
  typed the password).

## Troubleshooting

Start with the status script with logs (`status.ps1 -Logs`,
`status.sh --logs`) on the computer and "Test connection" in Blossom. The
first step that is not OK is the cause. To ask for help, copy the output of
that script (it masks session tokens and your host names). Do not post files
from the farm's `logs` folder: GADS writes request addresses into them, and
those can contain a login token.

The same on both systems (commands are given for Windows; the macOS ones
follow the table):

| What you see | Likely cause | What to do |
|---|---|---|
| The command from Blossom stops with "The downloaded file is not the one Blossom expects", or with a file or a list of files that "is not the one" expected, or that the kit "holds a file that its list does not name" | The download was changed on the way, or it is not the kit this command was made for | Nothing was run. Copy the command from Blossom again and retry on another network if you can. If it repeats, do not work around it: report it. |
| "The pairing of this computer was not changed … stays paired with …" | The command belongs to another workspace (or another Blossom) than the one this computer is paired with, and nobody typed `replace` | Nothing was changed. If you meant to move the farm to that workspace, run the command again and type `replace` when asked, or add `-ReplacePairing` / `--replace-pairing` at its end. If the command was sent to you by somebody else, do not run it. |
| "The kit folder … is not in a protected place" (Windows) | The kit was unpacked inside a user's folder (Downloads, Documents, Desktop) | Move the whole folder to `C:\blossom-farm-kit` and run the script from there. |
| "Pairing with Blossom did not work: This pairing code has expired" (or "was already used", or "does not know this pairing code") | A code works once and for 30 minutes | The installation went on without pairing. Get a new command in Blossom and run it on the farm computer; it keeps what is set up. If the code "was already used" and it was not you, decline the unknown computer in Blossom. |
| "The certificate of … could not be verified" | The clock of the computer is wrong, or something on the network intercepts https (a filtering proxy, an antivirus that opens encrypted connections) | Nothing was sent. Set the date and time, or take the farm computer off that network or product. The kit has no switch to skip this check. |
| "… answered with a redirect … not followed" or "answered, but not the way Blossom does" | The address in the command is not the one your Blossom answers at | Copy the command from Blossom again; do not type the address yourself. |
| Blossom shows "Waiting for your computer…" and the installer has finished | The pairing step failed (the installer said why), or the command was run without the code | Read the end of the installer's output, or run the status script; then a new command from Blossom. |
| The status script: "nobody has confirmed this computer in Blossom yet" | Step 4 was not done | Open Phone Farm → Farm setup in Blossom and confirm (or decline) the computer. |
| The status script or `rotate-secrets`: "Blossom no longer accepts this computer" | The computer was unpaired in Blossom, or its site was removed there | New values are shown for manual entry. To pair again, get a new command in Blossom. |
| The farm folder "already exists and cannot be used" | A folder of that name exists, has content, and was not created and locked by this kit | Rename it (`Rename-Item C:\farm C:\farm-old`; `sudo mv /opt/farm /opt/farm-old`) and run the installer again. If you do not know where the folder comes from, have the computer checked. |
| "… is not at its download address (HTTP 404)" | The file the kit pins was not published yet or was withdrawn | Look for a newer kit (`update.ps1 -Check`, `update.sh --check`) and use that. If you have the exact provider program from elsewhere: `install.ps1 -ProviderExe <path>` / `install.sh --provider-binary <path>` (its SHA-256 must be the pinned one). |
| "…its SHA-256 is wrong … The file was deleted" | Damaged or altered download | Run again. If it repeats, do not work around it: report it. |
| "The GADS hub does not start" | Port 10000 in use, or MongoDB down | The hub log (`hub.log` in the logs folder); the status script. |
| Hub administrator password refused five times | Wrong password | See "Lost hub administrator password" below. |
| "A DNS record for … already exists" | The name is in use in your zone | Choose another name, or run the installer with `-OverwriteDns` / `--overwrite-dns` to replace the record. |
| "already has a tunnel called blossom-farm" | An earlier installation on another computer | Delete the old tunnel in the Cloudflare dashboard (Zero Trust → Networks → Tunnels) or use `-TunnelName` / `--tunnel-name`. To *move* a farm use export/import. |
| Self-test, DNS: "does not resolve yet" | New DNS records | Wait a few minutes, run the self-test script. |
| Self-test, Hub sign-in: "The hub refused the password" | The password typed is not that user's | On a paired computer the test signs in as `admin`: type the hub administrator's password ("Lost hub administrator password", below, if it is gone). The password of `blossom` cannot be typed there: only Blossom has it. If Blossom itself reports a refused sign-in, `rotate-secrets` with `-HubUser` / `--hub-user` makes a new one and hands it over. |
| Self-test, Secure connection: "answers, but not the hub behind it" (502/530) | Tunnel up, hub down | The status script; start the hub. |
| Self-test, Secure connection: certificate error | Host name deeper than one level (`hub.farm.yourdomain.com`) | Use direct sub-domains: Cloudflare's free certificate covers `*.yourdomain.com` only. |
| Self-test: "Hub paths containing appium are not refused by the tunnel", or the same for `/provider-update` or the provider record | The tunnel configuration was changed by hand | Run the installer again (it rewrites the configuration). If it stays, stop the tunnel and report it. |
| Provider log: "Appium is not available" | Appium is switched on for the provider in the hub but was not installed | Run the installer with `-WithAppium` / `--with-appium`, or switch "Set up Appium servers" off for the provider in the hub page. |
| Self-test, Provider: "not the provider behind it" (502) | The provider is not running | The provider's logs (`Provider1\provider.log` and `logs\provider.log`). If it says *Could not provide WebDriverAgent.ipa file from MongoDB*: iOS was switched on for the provider before a WebDriverAgent was uploaded — `docs/phones.md`, step 3. |
| Blossom "Test connection" fails at Secure connection or Hub sign-in with an error page (HTML or 403), or the self-test says "Cloudflare blocked or challenged the request" | A login wall or a challenge in front of the host names | Cloudflare dashboard → Security → Settings: switch **Browser Integrity Check** off (it is on by default), or switch it off for the three farm names with a configuration rule. Remove Cloudflare Access applications and "Under Attack"/challenge/bot rules for the three names (`docs/network.md`, section 5). |
| Phone list or Control fails on and off with "server unreachable" / error 429 | A Cloudflare rate-limiting rule on the hub sign-in fires on normal use | Raise or remove the rule: Blossom signs in on every refresh of the phone list (`docs/network.md`, section 5). |
| A phone is connected but never becomes live; WebDriverAgent install or launch errors in the provider log | The WDA bundle ID in the provider does not match the signed app, or the provisioning profile does not cover it | `docs/phones.md`, section 2, "The bundle ID": for the pre-built file signed in the hub it is `com.facebook.WebDriverAgentRunner` and the App ID must be `*`. |
| The status script: "listens on all addresses" and not covered, or the firewall is off | The kit's firewall rule is missing, or the firewall is off | Run the installer again (it puts the rule back); on Windows switch Windows Firewall on (`docs/security.md`, section 1). |
| "Restart all" in Blossom's Services panel seems to do nothing | A program did not stop in time | `restart-server.log` names the service that did not stop (Windows: `C:\farm\logs`; macOS: `/opt/farm/logs-root`). Restart it on the computer. |
| Blossom: taps answer "device is not available" (422) | keep-available is not running | The status script; `keep-available.log`. If you created extra workspaces in the hub: `rotate-secrets` with `-KeepAvailable` / `--keep-available` makes it cover all of them. |
| A phone is Offline | Cable, hub power, phone locked, pairing lost | Unlock it, look at it in the hub's own page, "Restart Provider" in Blossom's Services panel. |
| Online but no picture in Control | FFmpeg missing from the provider's path, or the browser cannot reach the computer directly | The status script (FFmpeg must be listed); try another network. Video goes peer to peer, see `docs/network.md`. |
| Every phone stopped on the same day | The signature of WebDriverAgent expired | Sign and upload it again (`docs/phones.md`). |
| Services panel in Blossom: "Tunnel down" | cloudflared stopped or the computer is offline | Has to be fixed at the computer: start the tunnel service. A restart service cannot be reached through a tunnel that is down. |

Starting, stopping and restarting one service by hand:

```
Start-Service GadsHub        Stop-Service GadsHub -Force        Restart-Service GadsHub -Force           (Windows)
sudo launchctl bootstrap system /Library/LaunchDaemons/blossom-farm.hub.plist                            (macOS: start)
sudo launchctl bootout system/blossom-farm.hub                                                           (macOS: stop)
sudo launchctl kickstart -k system/blossom-farm.hub                                                      (macOS: restart)
```

On Windows, `GadsProvider` and `KeepAvailable` depend on `GadsHub`, so the
hub is stopped and restarted with `-Force`: without it PowerShell refuses.
`Stop-Service GadsHub -Force` stops those two as well, and `Start-Service
GadsHub` does not start them again: start them too (`Start-Service
GadsProvider, KeepAvailable`). `Restart-Service GadsHub -Force` restarts all
three.

Only on Windows:

| What you see | Likely cause | What to do |
|---|---|---|
| `install.ps1`: "must run as Administrator" | Normal PowerShell window | Start → type `powershell` → right-click → Run as administrator. |
| `install.ps1`: "running scripts is disabled on this system" | You ran `.\install.ps1` directly | Use `powershell -ExecutionPolicy Bypass -File .\install.ps1`. |
| `install.ps1`: "winget is not available" | Old Windows 10, or Windows without the Store (LTSC, Server) | Install "App Installer" from the Microsoft Store, or update Windows. On editions without the Store, install the programs named in `versions.json` yourself and run the installer again: it keeps programs it finds. |
| winget: "Argument name was not recognized", or winget fails on every program | winget on this PC is older than the installer expects | Microsoft Store → Library → Get updates, let "App Installer" update, open a new Administrator PowerShell, run the installer again. |
| winget: "No version found matching" | The pinned version was withdrawn from winget | Install the nearest newer version: `winget install --exact --id <id>`; then run the installer again. Tell us (issue) so the pin is refreshed. |
| After a restart the site is Connected but every phone is Offline until somebody signs in to Windows | Apple's USB support is the Microsoft Store version, which only runs in a signed-in session | Install iTunes from Apple's own installer (`docs/phones.md`, section 0); `Get-Service 'Apple Mobile Device Service'` must then show a service. |
| After a power cut nothing comes back | PC did not switch itself on | In the PC's BIOS/UEFI set "restore on AC power loss" to "power on". |
| Windows Security removed or blocked a farm program | False positive on an unsigned program | Check its checksum with `scripts\status.ps1` first. If it matches the pinned value, restore it and add an exclusion for that one file. The kit does not switch off any protection by itself. |

Only on macOS:

| What you see | Likely cause | What to do |
|---|---|---|
| `install.sh`: "must run as root" | Started without `sudo` | `sudo bash install.sh`. |
| `install.sh`: "FFmpeg was not found, and Homebrew is not available" | Homebrew is not installed, or the installer was started from a root shell | Install Homebrew as your normal user (<https://brew.sh> shows the one command), then `sudo bash install.sh` again. |
| `install.sh`: "runs under Rosetta" | Terminal is set to open with Rosetta | Finder → Applications → Utilities → Terminal → Get Info → untick "Open using Rosetta". |
| `install.sh`: "macOS … is too old" | The pinned programs need a newer macOS on this kind of Mac | Update macOS. An Intel Mac that cannot run macOS 15 cannot run this kit. |
| `install.sh`: "Another program already uses port 27017" | Another MongoDB runs on the Mac | Stop it (`brew services stop mongodb-community`) and run the installer again. The kit uses its own. |
| Signing WebDriverAgent in the hub page fails with "Library not loaded: /opt/homebrew/opt/openssl@3/…" | The OpenSSL library from Homebrew is missing (Apple Silicon) | `brew install openssl@3`, then sign again. |
| Signing WebDriverAgent in the hub page fails on an Intel Mac | GADS 6.0.0 carries its signing helper for Apple Silicon only | Sign outside the hub: `docs/phones.md`, "Signing outside the hub". |
| After a restart or a power cut nothing comes back until somebody is at the Mac | FileVault is on | Step 6 above. |
| A phone plugged into a MacBook is not seen | macOS asks before it lets a new USB accessory connect | System Settings → Privacy & Security → "Allow accessories to connect": *Always* (`docs/phones.md`, section 1). |
| The status script: "The kit's packet filter rule is not loaded" | Another program replaced the rules of the packet filter | `sudo bash install.sh` puts it back; the service `blossom-farm.firewall` does the same every five minutes. `/opt/farm/logs-root/firewall.log` says why when it cannot. |

**Lost hub administrator password.** GADS keeps hub users in the MongoDB
database `gads`, collection `users`, with the password as plain text (seen in
the GADS 6.0.0 source). With the MongoDB shell an administrator of the
computer can set a new one that passes the installer's rules, then restart
the hub.

* *Windows:* `winget install --exact --id MongoDB.Shell`, then in `cmd.exe`
  (not in PowerShell, which would read `$set` as a variable):
  `mongosh mongodb://127.0.0.1:27017/gads --eval "db.users.updateOne({username:'admin'},{$set:{password:'<new long password>'}})"`,
  then `Restart-Service GadsHub -Force` (`-Force` because other farm
  services depend on the hub; it restarts them too).
* *macOS:* `brew install mongosh`, then in Terminal (the single quotes
  matter):
  `mongosh mongodb://127.0.0.1:27017/gads --eval 'db.users.updateOne({username:"admin"},{$set:{password:"<new long password>"}})'`,
  then `sudo launchctl kickstart -k system/blossom-farm.hub`.

## Uninstall

```
powershell -ExecutionPolicy Bypass -File .\scripts\uninstall.ps1              (Windows: services only)
powershell -ExecutionPolicy Bypass -File .\scripts\uninstall.ps1 -RemoveData  (Windows: everything of the farm)
sudo bash scripts/uninstall.sh                                                (macOS: services only)
sudo bash scripts/uninstall.sh --remove-data                                  (macOS: everything of the farm)
```

The script lists what it leaves behind (DNS records, programs it did not
install into the farm folder, the site in Blossom) with the way to remove
each.

## What is in this repository

| Path | |
|---|---|
| `install.ps1`, `install.sh` | the installer, for Windows and for macOS |
| `bootstrap.ps1`, `bootstrap.sh` | the small file the command from Blossom downloads first; it fetches the kit and checks every file of it |
| `MANIFEST.sha256` | the SHA-256 of every file of the kit; the bootstrap files carry the SHA-256 of this list |
| `pairing.json` | which commit is the released kit, and the SHA-256 of its bootstrap files: what Blossom CRM puts into the command it shows, and what the update script reads |
| `versions.json` | every pinned version and checksum, for both systems |
| `lib/` | functions shared by the scripts: `FarmKit.psm1` (Windows), `farmkit.sh` and `json.awk` (macOS) |
| `services/` | `restart-server.js` and `provider-gate.js` (both systems); `keep-available.ps1` (Windows); `keep-available.sh`, `farm-run.sh`, `farm-firewall.sh` (macOS) |
| `launchd/` | macOS: the service descriptions the installer fills in, and the packet filter rule |
| `scripts/` | status, self-test, update, rotate-secrets, export, import, uninstall: each as `.ps1` and as `.sh` |
| `patch/` | the provider patch and what it does |
| `tools/` | for maintainers, run on their own computer: `build-provider.sh` builds the patched provider for Windows and macOS with its source and licence files; `publish-dist.sh` puts them on the branch `dist`; `make-manifest.sh` writes `MANIFEST.sha256`; `check.sh` runs every test; `release.sh` makes a kit release |
| `LICENSE`, `LICENSE-AGPL-3.0`, `NOTICE` | the licences, and what applies to which part |
| `docs/` | [`phones.md`](docs/phones.md), [`network.md`](docs/network.md), [`security.md`](docs/security.md), [`RELEASING.md`](docs/RELEASING.md) |
| `tests/` | tests of the services (Node), of the PowerShell functions (Pester) and of the shell functions and scripts (bash); `fake-blossom.js` is a stand-in for Blossom's pairing API and for the places a kit is fetched from, which the pairing, bootstrap and update tests of both systems run against |

## Licences, in short

* The files of this kit are under the MIT licence ([`LICENSE`](LICENSE)),
  **except** `patch/provider-drag.patch`, which modifies GADS and is under the
  GNU AGPL v3.0, like the GADS source
  ([`LICENSE-AGPL-3.0`](LICENSE-AGPL-3.0) is the text).
* GADS is not part of this repository. Its source is AGPL-3.0; its web
  interface (`hub-ui`) is proprietary. The installer downloads the hub from
  the GADS publisher's own release page, and the provider from the branch
  `dist` of this repository, where it is published together with its source
  archive, its build instructions and the licence notices of the libraries
  compiled into it.
* Details and the third-party programs the installer fetches:
  [`NOTICE`](NOTICE).

Blossom farm kit is not affiliated with the GADS project, Cloudflare or Apple.
