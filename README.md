# Blossom farm kit

Everything needed to turn one Windows PC into a phone farm that
[Blossom CRM](https://github.com/fyhcrew-art) can drive: one installer, the
small services that sit around the farm software, and the guide.

Your iPhones stay at your place, plugged into your PC. The PC runs
[GADS](https://github.com/shamanec/GADS), an open-source device farm. A
Cloudflare Tunnel gives it three public https addresses. You paste those
addresses and two secrets into Blossom CRM, and your phones appear there.

There is no onboarding call. This repository is the whole of it.

> **Status of this kit: read this first.** The services
> (`services/restart-server.js`, `services/provider-gate.js`) are covered by
> automated tests, and the GADS build is reproduced by CI. The PowerShell
> scripts were written for Windows PowerShell 5.1 but **have not yet been run
> on a Windows PC by the authors of this version**; the first releases are
> being tested on the vendor's own farm. If `install.ps1` stops with an error
> that its "what to do" line does not resolve, please open an issue with the
> PROBLEM line (remove host names and passwords first).
> [`docs/TESTING.md`](docs/TESTING.md) lists exactly what was and was not tested.

## The 10-minute overview

```
   iPhones --USB--> your Windows PC (C:\farm)                    the internet
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

* Nothing on the PC listens on your network. Every program listens on
  `127.0.0.1` only; `cloudflared` connects *outwards* to Cloudflare, and
  Cloudflare gives the three host names a valid certificate. You open no port
  on your router.
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

All of it runs as Windows services that start with the PC:
`MongoDB`, `GadsHub`, `GadsProvider`, `FarmGate`, `KeepAvailable`,
`FarmRestart`, `Cloudflared`.

## What you need

| | |
|---|---|
| A PC | 64-bit (x64) Windows 10 version 1809 or later, or Windows 11. 10 GB free on `C:`. It stays on, wired to the internet. Use it for the farm only (see `docs/security.md`). |
| How powerful | Neither GADS nor Blossom publishes a minimum. Each live screen that somebody is watching is one video encoder (FFmpeg) running on the PC. Start with a recent desktop processor and 16 GB of memory and watch the load. |
| iPhones | iOS 16 or later is what this kit was written for. iOS 17.0 to 17.3 is not supported by GADS 6 (update the phone to 17.4 or later). No passcode, Auto-Lock "Never", Developer Mode on. |
| USB | One data cable per phone and **powered** USB hubs. This is practice, not a rule from GADS: a phone that is awake all day draws more than an unpowered port gives. |
| A domain | A domain name you own, with its DNS at Cloudflare (free plan is enough). The installer creates three sub-domains on it. |
| A Cloudflare account | Free. Needed for the tunnel. |
| An Apple Developer account | Needed to sign WebDriverAgent, the helper app on each phone. Paid (signature lasts a year) or free (lasts 7 days, impractical for a farm). See [`docs/phones.md`](docs/phones.md). |
| Blossom CRM | A workspace with Phone Farm access. |

## Step by step

### 1. Before you start

1. Add your domain to Cloudflare and wait until Cloudflare shows it as
   "Active" ([`docs/network.md`](docs/network.md), section 1).
2. Decide three host names, direct sub-domains of your domain, for example
   `farm-hub.yourdomain.com`, `farm-provider.yourdomain.com`,
   `farm-restart.yourdomain.com`.
3. Have a password manager ready. The installer shows two secrets once.

### 2. Download the kit

On the farm PC, download the latest kit from
<https://github.com/fyhcrew-art/blossom-farm-kit/releases> ("Source code
(zip)" of the newest `kit-v…` release), and unpack it, for example to
`C:\blossom-farm-kit`. Keep the folder: the maintenance scripts are in it.

### 3. Run the installer

Press Start, type `powershell`, right-click **Windows PowerShell**, choose
**Run as administrator**, then:

```powershell
cd C:\blossom-farm-kit
powershell -ExecutionPolicy Bypass -File .\install.ps1
```

`-ExecutionPolicy Bypass` applies to this one command only; it is needed
because Windows does not run downloaded scripts by default. Read a script
before you run it as Administrator: these are plain text.

What the installer does, in order (it prints each step):

| Step | What happens |
|---|---|
| 1 Checks | Administrator, 64-bit Windows 10 1809+/11, 10 GB free. |
| 2 Folders | Creates `C:\farm` and makes it readable by Administrators and SYSTEM only. |
| 3 Programs | Installs, with `winget` and at pinned versions: NSSM, MongoDB, Node.js, FFmpeg, cloudflared. Programs that are already installed are kept as they are. |
| 4 GADS | Downloads the GADS hub from its publisher's release and the patched provider from this repository's release, and checks the SHA-256 of both against `versions.json`. A file with a wrong checksum is deleted, not used. |
| 5 MongoDB | Starts it and checks that it listens on this PC only. |
| 6 Hub + password | Starts the hub (on this PC only). GADS creates its administrator `admin` with a default password that anybody can look up; **the installer makes you replace it before anything is reachable from outside.** You choose it (14+ characters), typing is hidden. |
| 7 Users + provider | Creates the hub user `blossom` (random password, for Blossom CRM), the internal user `farm-keepalive`, and the provider record (`Provider1` unless you pass `-Nickname`). |
| 8 Host names | Asks for the three host names. |
| 9 Tunnel | Opens the Cloudflare sign-in in a browser, creates the tunnel `blossom-farm`, creates the three DNS records, writes and validates the tunnel configuration. |
| 10 Restart secret | Generates it (256 random bits). |
| 11 Services | Creates the Windows services (auto-start, restart on crash, rotating logs in `C:\farm\logs`) and starts them; the tunnel last. Switches off sleep on mains power. |
| 12 Self-test | Performs the checks of Blossom's "Test connection" against your public addresses, plus two of its own: that the provider and the restart service refuse a stranger. |

At the end it prints what to paste into Blossom:

```
   Hub address ............ https://farm-hub.yourdomain.com
   Provider address ....... https://farm-provider.yourdomain.com
   Provider nickname ...... Provider1
   Hub user ............... blossom
   Hub password ........... (shown once)
   Restart service address  https://farm-restart.yourdomain.com
   Restart secret ......... (shown once)
```

**The hub password and the restart secret are shown once and written to no
log.** Copy them straight into Blossom or a password manager.

The installer can be run again at any time. It keeps the database, the
tunnel, the secrets and the passwords, and repairs what is missing.

### 4. Connect it to Blossom

In Blossom CRM open **Phone Farm → Farm setup → Connect a farm**, paste the
values (the restart service goes under "Restart service (optional)"), press
**Test connection**, then **Save and connect**. With no phone yet, the step
"Phones" says *Check*: that is expected.

### 5. Add the phones

Follow [`docs/phones.md`](docs/phones.md): prepare each iPhone, sign and
upload WebDriverAgent, switch iOS on for the provider, register the phones in
the hub. Do one phone completely before the others.

### 6. Check that it survives a restart

Restart the PC and touch nothing. Within a few minutes the site in Blossom
should read *Connected*. `scripts\status.ps1` shows the state on the PC.

## Day to day

Run these from an Administrator PowerShell inside the kit folder
(`powershell -ExecutionPolicy Bypass -File .\scripts\<name>.ps1`).

| Script | What it is for |
|---|---|
| `scripts\status.ps1` | Services, ports, program checksums, disk. `-Logs` adds the last lines of every log. Changes nothing. |
| `scripts\self-test.ps1` | The connection test against the public addresses. |
| `scripts\rotate-secrets.ps1` | New restart secret (`-RestartSecret`), new password for `blossom` (`-HubUser`), for `admin` (`-AdminPassword`), or `-All`. Use it whenever somebody with Phone Farm access leaves. |
| `scripts\update.ps1` | Moves the farm to the versions of a newer kit; `-Rollback` goes back. |
| `scripts\export-farm.ps1`, `scripts\import-farm.ps1` | Move the farm to another PC without changing anything in Blossom. |
| `scripts\uninstall.ps1` | Removes the services; with `-RemoveData` also the tunnel, the database and `C:\farm`. |

Where things are:

| Path | What |
|---|---|
| `C:\farm\bin` | `GADS.exe` (hub), `GADS-drag.exe` (provider), `nssm.exe` |
| `C:\farm\services` | the three service scripts |
| `C:\farm\config` | `farm.json` (host names, no secrets), `restart-secret.txt`, `keep-available.json`, `cloudflared\` (tunnel configuration and credentials) |
| `C:\farm\logs` | one log per service, rotated at 10 MB, rotated files deleted after 30 days |
| `C:\farm\Provider1` | the provider's own folder: its log, per-phone logs, cached pairings |

## Updating

* **GADS and the kit's services**: download the newer kit and run its
  `scripts\update.ps1`. Only versions that a kit pins are installed: the hub
  and the patched provider must match each other, and the patch is made
  against a specific GADS version. Do not replace `GADS.exe` by hand.
* **MongoDB, Node.js, FFmpeg, cloudflared**: `update.ps1` leaves them alone.
  Update them with `winget upgrade --id <id>` when you choose to
  (`versions.json` lists the ids): stop the farm services first
  (`Stop-Service Cloudflared, KeepAvailable, FarmRestart, FarmGate, GadsProvider, GadsHub`),
  upgrade, restart the PC, and run `scripts\status.ps1`. cloudflared runs
  with `--no-autoupdate`, so it too only changes when you change it.
* **Windows**: let it update. The services start by themselves after the
  restart.

## Troubleshooting

Start with `scripts\status.ps1 -Logs` on the PC and "Test connection" in
Blossom. The first step that is not OK is the cause.

| What you see | Likely cause | What to do |
|---|---|---|
| `install.ps1`: "must run as Administrator" | Normal PowerShell window | Start → type `powershell` → right-click → Run as administrator. |
| `install.ps1`: "running scripts is disabled on this system" | You ran `.\install.ps1` directly | Use `powershell -ExecutionPolicy Bypass -File .\install.ps1`. |
| `install.ps1`: "winget is not available" | Old Windows 10, or Windows without the Store (LTSC, Server) | Install "App Installer" from the Microsoft Store, or update Windows. On editions without the Store, install the programs named in `versions.json` yourself and run the installer again: it keeps programs it finds. |
| winget: "No version found matching" | The pinned version was withdrawn from winget | Install the nearest newer version: `winget install --exact --id <id>`; then run the installer again. Tell us (issue) so the pin is refreshed. |
| "…its SHA-256 is wrong … The file was deleted" | Damaged or altered download | Run again. If it repeats, do not work around it: report it. |
| "The GADS hub does not start" | Port 10000 in use, or MongoDB down | `C:\farm\logs\hub.log`; `Get-Service MongoDB`. |
| Hub administrator password refused five times | Wrong password | See "Lost hub administrator password" below. |
| "A DNS record for … already exists" | The name is in use in your zone | Choose another name, or `install.ps1 -OverwriteDns` to replace the record. |
| "already has a tunnel called blossom-farm" | An earlier installation on another PC | Delete the old tunnel in the Cloudflare dashboard (Zero Trust → Networks → Tunnels) or use `-TunnelName`. To *move* a farm use export/import. |
| Self-test, DNS: "does not resolve yet" | New DNS records | Wait a few minutes, `scripts\self-test.ps1`. |
| Self-test, Secure connection: "answers, but not the hub behind it" (502/530) | Tunnel up, hub down | `scripts\status.ps1`; `Start-Service GadsHub`. |
| Self-test, Secure connection: certificate error | Host name deeper than one level (`hub.farm.yourdomain.com`) | Use direct sub-domains: Cloudflare's free certificate covers `*.yourdomain.com` only. |
| Self-test, Provider: "not the provider behind it" (502) | `GadsProvider` is not running | `C:\farm\Provider1\provider.log` and `C:\farm\logs\provider.log`. If it says *Could not provide WebDriverAgent.ipa file from MongoDB*: iOS was switched on for the provider before a WebDriverAgent was uploaded — `docs/phones.md`, step 3. |
| Blossom "Test connection" fails at Hub sign-in although the self-test passes | A login wall or a challenge in front of the host names | Remove Cloudflare Access applications and "Under Attack"/challenge rules for the three names (`docs/security.md`). |
| Blossom: taps answer "device is not available" (422) | keep-available is not running | `Get-Service KeepAvailable`, `C:\farm\logs\keep-available.log`. If you created extra workspaces in the hub: `scripts\rotate-secrets.ps1 -KeepAvailable` makes it cover all of them. |
| A phone is Offline | Cable, hub power, phone locked, pairing lost | Unlock it, look at it in the hub's own page, "Restart Provider" in Blossom's Services panel. |
| Online but no picture in Control | FFmpeg missing from the provider's path, or the browser cannot reach the PC directly | `scripts\status.ps1` (FFmpeg must be listed); try another network. Video goes peer to peer, see `docs/network.md`. |
| Every phone stopped on the same day | The signature of WebDriverAgent expired | Sign and upload it again (`docs/phones.md`). |
| Services panel in Blossom: "Tunnel down" | cloudflared stopped or the PC is offline | Has to be fixed at the PC: `Start-Service Cloudflared`. A restart service cannot be reached through a tunnel that is down. |
| After a power cut nothing comes back | PC did not switch itself on | In the PC's BIOS/UEFI set "restore on AC power loss" to "power on". |
| Windows Security removed or blocked a farm program | False positive on an unsigned program | Check its checksum with `scripts\status.ps1` first. If it matches the pinned value, restore it and add an exclusion for that one file. The kit does not switch off any protection by itself. |

**Lost hub administrator password.** GADS keeps hub users in the MongoDB
database `gads`, collection `users`, with the password as plain text (seen in
the GADS 6.0.0 source). With the MongoDB shell
(`winget install --exact --id MongoDB.Shell`) an Administrator of the PC can
set a new one:
`mongosh mongodb://127.0.0.1:27017/gads --eval "db.users.updateOne({username:'admin'},{$set:{password:'<new long password>'}})"`.
We have not run this recovery ourselves; treat it as a last resort and choose
a password that passes the installer's rules.

## Uninstall

```powershell
powershell -ExecutionPolicy Bypass -File .\scripts\uninstall.ps1              # services only
powershell -ExecutionPolicy Bypass -File .\scripts\uninstall.ps1 -RemoveData  # everything of the farm
```

The script lists what it leaves behind (DNS records, programs installed with
winget, the site in Blossom) with the way to remove each.

## What is in this repository

| Path | |
|---|---|
| `install.ps1` | the one entry point |
| `versions.json` | every pinned version and checksum |
| `lib/FarmKit.psm1` | functions shared by the scripts |
| `services/` | `restart-server.js`, `provider-gate.js`, `keep-available.ps1` |
| `scripts/` | status, self-test, update, rotate-secrets, export, import, uninstall |
| `patch/` | the provider patch and what it does |
| `.github/workflows/` | `build-gads.yml` builds the patched provider and publishes it; `ci.yml` tests the kit |
| `docs/` | [`phones.md`](docs/phones.md), [`network.md`](docs/network.md), [`security.md`](docs/security.md), [`TESTING.md`](docs/TESTING.md), [`RELEASING.md`](docs/RELEASING.md) |
| `tests/` | tests of the services (Node) and of the pure PowerShell functions (Pester) |

## Licences, in short

* The files of this kit are under the MIT licence ([`LICENSE`](LICENSE)),
  **except** `patch/provider-drag.patch`, which modifies GADS and is under the
  GNU AGPL v3.0, like the GADS source.
* GADS is not part of this repository. Its source is AGPL-3.0; its web
  interface (`hub-ui`) is proprietary. The installer downloads the hub from
  the GADS publisher's own release page, and the provider from this
  repository's release, where it is published with its complete source.
* Details and the third-party programs the installer fetches:
  [`NOTICE`](NOTICE).

Blossom farm kit is not affiliated with the GADS project, Cloudflare or Apple.
