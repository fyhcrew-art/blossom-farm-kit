# Security

A phone farm reachable from the internet is a remote control for your
phones and for every account signed in on them. This page says plainly what
the kit exposes, what protects it, and where the protection ends. The
statements about GADS come from reading its 6.0.0 source code
(<https://github.com/shamanec/GADS>, tag `v6.0.0`); file names are given so
that you can check them.

## 1. What is exposed to the internet

Three https host names, through the Cloudflare Tunnel. Nothing else: no port
is open on your router.

| Host name | Leads to | What protects it |
|---|---|---|
| hub | the GADS hub: its web page and its API | the hub's own user names and passwords |
| provider | the **provider gate**, and behind it the GADS provider | a valid hub session token, checked by the gate with the hub |
| restart | the restart service | the restart secret (256 random bits) |

### What listens on the computer, and what your local network can reach

* MongoDB, the hub, the provider's own port, the provider gate and the
  restart service listen on `127.0.0.1` only: nothing outside the computer
  can connect to them. The installer and the status script check these five
  ports.
* **The per-phone ports are different.** For every connected iPhone the GADS
  provider opens three more ports (WebDriverAgent, the screen stream, the
  WebDriverAgent video), on port numbers it picks at run time, and upstream
  GADS opens them on **all** network addresses of the computer, not on
  `127.0.0.1` (`provider/devices/ios.go`, through go-ios
  `ios/forward/forward.go`). With Appium installed (`-WithAppium`,
  `--with-appium`) the same goes for one Appium server per phone
  (`provider/devices/appium.go` starts it without an address). None of these
  ports asks for a login: whoever reaches a WebDriverAgent port can take
  screenshots and tap on that phone, past the hub, the gate and the tunnel.
* What closes them **on Windows: Windows Firewall.** `install.ps1` creates
  rules named "Blossom farm - no network access to …" that refuse incoming TCP
  connections to `GADS-drag.exe`, to `GADS.exe` and, with `-WithAppium`, to
  `node.exe`. A block rule wins over any "allow" rule for the same program
  (for example one made long ago by clicking "Allow access"). Connections
  from the PC to itself are never filtered by Windows Firewall, so the farm
  is unaffected; the live video is UDP and is not touched.
* What closes them **on macOS: the packet filter (pf).** GADS takes the
  numbers of these ports from the system's range for temporary ports (49152
  to 65535 unless the Mac is set otherwise; the installer reads the range).
  `install.sh` loads one rule that drops every new TCP connection arriving
  from the network for a port of that range:
  `block drop in quick on ! lo0 proto tcp from any to any port 49152:65535 flags S/SA`.
  Connections on the Mac itself (the loopback interface), connections the
  Mac starts, and UDP (the live video) are not touched. The rule is by port
  range and not by program: pf does not filter by program. The application
  firewall of macOS (System Settings → Network → Firewall) is a separate
  thing; the kit does not configure it, and it can stay on or off as you
  have it: the farm needs no incoming connection. The rule
  sits in a pf anchor of its own (`com.apple/blossom-farm`), `/etc/pf.conf`
  is not changed, and the service `blossom-farm.firewall` loads it when the
  Mac starts and checks every five minutes that it is still there.
* On both, the status script lists every port the farm programs have open on
  a network address, says whether the rule covers it, and warns when the
  firewall is switched off or the rule is gone.
* What that means for you: **keep that firewall on.** If another security
  product replaces Windows Firewall, or rewrites the rules of pf on a Mac
  (some VPN programs do), the kit's rule does nothing until it is put back,
  and that product must block incoming connections to the computer itself.
  Either way, a farm computer belongs on a network you control, not on a
  shared office or guest Wi-Fi. The kit does not change how GADS opens these
  ports; the rule is the protection.

### Why a tunnel and not port forwarding

* With port forwarding the hub would answer at your location's own IP
  address, where automated scanners find it within hours. With a tunnel your
  IP address is not published and nothing on your router is open.
* Blossom only talks to https addresses with a certificate it can verify and
  refuses private addresses and redirects (`src/lib/farm/net.ts` in the
  product). A tunnel host name gets a valid certificate automatically; with
  port forwarding you would have to build and renew that yourself.
* A home IP address changes; a tunnel host name does not.

What a tunnel does **not** do: it does not add a login. Whoever knows a host
name reaches the program behind it. The three protections in the table are
all there is.

## 2. The provider has no login. That is why there is a gate

In GADS 6.0.0 the provider program checks no credentials at all
(`provider/router/handler.go` registers every route without any
authentication). Whoever can reach its port can list the phones
(`/devices`), take screenshots, tap, type, install and remove apps.

Blossom needs the provider on a public host name: the Control page opens the
live-video handshake there and the AI assistant sends its taps there. Simply
pointing a tunnel at the provider's port, which is what a quick setup does,
publishes all of the above to anyone who learns or guesses the host name.

The kit therefore never publishes the provider's port. The provider host name
leads to `services/provider-gate.js`, which:

* lets a request through only if it carries a hub session token, either as
  `Authorization: Bearer …` or as `?token=…` (what the browser's WebSocket
  uses). These are exactly what Blossom already sends;
* checks the token by asking the hub on the same PC (`GET /user-info`), and
  remembers the answer for 30 seconds;
* refuses when the hub cannot be asked (fails closed);
* never passes on the provider's profiling pages (`/debug/…`) or the
  endpoints the provider only serves to local helpers. The gate compares the
  path the way the provider reads it, that is after percent-decoding
  (`/%64ebug` is `/debug`), and answers 400 to a path that could be read in
  two ways (an encoded slash or backslash, `..`, a broken percent-code);
* removes the `token` parameter from the address before it passes a request
  on. The provider does not need it, and GADS writes every request address to
  its log (section 4).

Limits you should know:

* Any valid hub session passes, whatever the user's role. Do not hand out hub
  users you would not trust with every phone.
* A cancelled token keeps working at the gate for up to 30 seconds.
* The gate is part of this kit, not of GADS (`services/provider-gate.js`,
  with automated tests in `tests/provider-gate.test.js`). Read it; it is
  short.

The installer and the self-test script check from outside that the provider
host name answers **401** without a token. If that check ever fails, stop the
tunnel (`Stop-Service Cloudflared`; on macOS
`sudo launchctl bootout system/blossom-farm.cloudflared`) until you know why.

## 3. What GADS itself does not protect

Read in the 6.0.0 source. None of this is specific to this kit; it is the
state of the software the farm runs on.

* **Hub passwords are stored as plain text** in MongoDB (`common/db/user.go`)
  and compared directly. Anyone who can read the database reads every hub
  password. This is why the kit insists that MongoDB listens on `127.0.0.1`
  only and why the farm folder and the export archive are protected.
* **MongoDB has no login** in this setup. It is reachable only from the
  computer itself, but from *any* program and *any* user on that computer.
  Use the computer for the farm only; do not let other people sign in to it;
  do not install software you do not trust on it.
* **The default administrator.** GADS creates `admin` with a published default
  password and prints it at every start (`hub/hub.go`). The installer forces
  you to replace it before the tunnel is started, checks that the default no
  longer works, and stops the tunnel if it ever finds the default valid again.
  The `admin` user cannot be deleted or renamed in GADS.
* **No protection against password guessing** on the hub's sign-in
  (`hub/auth/auth.go`: no rate limit, no lock-out). The passwords the kit
  generates are 256 random bits; the one you choose for `admin` must be long.
  A Cloudflare rate-limiting rule on `/authenticate` can blunt a flood of
  guesses, within limits (`docs/network.md`, section 5).
* **Hub paths that contain the word "appium" skip the login check**
  (`hub/auth/auth.go`, `AuthMiddleware`: any path containing "appium" is let
  through). Behind such paths the hub forwards to the provider, and from there
  to the Appium server of a phone, if there is one. The kit's answer:
  * the tunnel configuration refuses every request to the hub host name whose
    path contains "appium", in any letter case, before it reaches the hub.
    Blossom never calls such a path on the hub (its Appium calls go to the
    provider host name, through the gate, with a token);
  * the installer's self-test checks from outside that these paths answer 403;
  * by default the provider is created with Appium **off**, so there is no
    Appium server behind those paths at all.

  If you install with Appium (`-WithAppium`, `--with-appium`), the first point is the only thing between
  the internet and the Appium servers of your phones for anyone who knows a
  phone's UDID. cloudflared matches the rule against the decoded request path
  (`ingress/ingress.go` in its source), the same form the hub checks, so
  spelling the word with percent-codes does not get around it. To see it for
  yourself, from any computer with curl, both of these must print **403**:
  `curl -s -o NUL -w "%{http_code}" --path-as-is https://<hub host>/device/x/appium/status`
  `curl -s -o NUL -w "%{http_code}" --path-as-is https://<hub host>/device/x/%61ppium/status`
  (on a Mac write `/dev/null` instead of `NUL`)
  Do not edit the tunnel configuration by hand, and do not put a Cloudflare
  Access rule into it. A side effect of the rule: the hub page's Appium log
  view does not load through the public address; open the hub page on the
  farm computer (`http://127.0.0.1:10000`) for that.
* **Some hub endpoints are registered outside the login check**
  (`hub/router/handler.go`: everything registered before
  `auth.AuthMiddleware()` is added). All of them, and what the kit does:

  | Hub path | What it gives without a login | The kit |
  |---|---|---|
  | `POST /provider-update` | how a provider reports to the hub; a stranger could feed it false device states | refused at the tunnel (403) |
  | `GET /admin/provider/<nickname>/info` | the provider's record from the database, sent again every second for as long as the connection stays open: operating system, port, WebDriverAgent bundle ID and, if you set one, the **supervision password** (`docs/phones.md`, section 6). Each open connection also costs the hub one database query per second | refused at the tunnel (403); the self-test checks it from outside. The hub page's provider view therefore only works on the farm computer (`http://127.0.0.1:10000`) |
  | `GET /available-devices` | the device list of a workspace, for whoever knows the workspace id | stays reachable: the hub's own page needs it |
  | `/devices/control/<udid>/in-use`, `/lock`, `/unlock`, `/release` | nothing: these handlers check the session token themselves (`hub/router/routes.go`) | passed on |
  | `POST /authenticate`, `POST /oauth/token` | the sign-in itself | passed on |
  | `GET /swagger/…` | the hub's API description; no data of yours | passed on |
* **Both programs answer any website's scripts** (CORS is open in both
  routers). This matters together with the next point.

## 4. A farmer's browser holds the hub administrator's session

Blossom's Control page sends taps to your hub and opens the video with your
provider **from the browser of the person working the phone**. For that, the
browser receives a session token of the hub user you entered in Blossom. The
connection test requires that user to have the admin role, so the token is an
**administrator session on your hub**.

In practice: Phone Farm access in Blossom is administrator access to your hub
and to every phone on it. Give it only to people you would give that to. The
product can neither recall a token a browser already holds nor see your hub's
user list.

In GADS 6.0.0 a session token is valid for **one hour** from sign-in
(`hub/auth/auth.go`) and is not cancelled by a password change. (Later GADS
versions extend sessions; check again when a kit moves to a newer GADS.)

### Session tokens end up in the hub's log

GADS writes the address of every request to its output, and the kit keeps
that output in `hub.log` and `provider.log` in the farm's logs folder
(`C:\farm\logs`, `/opt/farm/logs`). The hub accepts its
session token as part of an address (`…?token=…`, used for WebSocket
connections), so **`hub.log` can contain session tokens that are valid for up
to an hour**, and with the `blossom` user those are administrator tokens. The
kit cannot switch this off in the hub: it runs the publisher's own program.
What it does:

* the provider gate removes the token from the address before the provider
  sees it, so `provider.log` does not collect the tokens of the live-video
  connections;
* the logs folder is readable by Administrators and SYSTEM only on Windows,
  by root and the farm's service account only on macOS;
* the status script with `-Logs` / `--logs` masks tokens and your host names
  before it prints the end of a log.

What you must do: **never post, mail or upload a file from the logs folder.**
When you ask for help, copy the output of the status script with logs.

### When somebody leaves, or loses Phone Farm access

1. Remove their access in Blossom.
2. On the farm computer: the `rotate-secrets` script with `-HubUser` /
   `--hub-user`. A paired computer hands the new hub password to Blossom by
   itself (section 9); otherwise enter it in Blossom (Farm setup → Edit).
   If that person also knew the `admin` password or sat at the farm
   computer: `-All` / `--all`.
3. In the hub page (`http://127.0.0.1:10000`, Admin → Users) delete every
   user you do not recognise. A hub administrator can create further
   administrators; a leaver may have made one.
4. A token they already hold works for at most one more hour. To end all
   sessions at once, replace the signing key in the hub page (Admin → Secret
   keys).
5. If they had physical access to the phones or the computer, treat the
   accounts on the phones as exposed as well.

## 5. Do not put Cloudflare Access (or any login wall) in front

It is tempting to add a Cloudflare Access application, so that a visitor must
pass an e-mail code or a single sign-on before reaching the hub. **With
Blossom this does not work, and the kit does not set it up.** What we checked
in the product's code at the time of writing:

* its server calls to a farm send an `Authorization` header and nothing else
  that could carry an Access service token, and there is no setting for one
  (`src/lib/farm/net.ts`, `src/lib/farm/devices.ts`);
* it never follows a redirect, and an Access login *is* a redirect;
* the Control page calls the hub and the provider straight from the browser,
  from Blossom's web address, with the hub token. An Access cookie for your
  domain is not sent along with such cross-site requests.

With Access in front, "Test connection" fails at *Secure connection* or *Hub
sign-in*. The same goes for "Under Attack" mode, challenge pages and, possibly,
Browser Integrity Check (below). If a
future version of Blossom can pass an Access service token, this page and the
installer will say so; until then the protections are the ones in section 1.

One Cloudflare setting is on by default and belongs to the same family:
**Browser Integrity Check** challenges requests without a User-Agent header,
which is how Blossom's servers call a farm today. `docs/network.md`, section
5, says when and how to switch it off for the farm's host names.

What can help at Cloudflare: a generous rate-limiting rule (read
`docs/network.md`, section 5, first: Blossom signs in often, and a tight rule
breaks it), and, if your team works from known countries only, a WAF rule that blocks the hub and provider host names elsewhere. Be
aware that Blossom's own servers must stay allowed; ask Blossom support where
they call from before you restrict by country or IP address.

## 6. The secrets on the computer

The paths are below the farm folder: `C:\farm` on Windows, `/opt/farm` on
macOS.

| Secret | Where it is | Who can read it: Windows | Who can read it: macOS |
|---|---|---|---|
| restart secret | `config/restart-secret.txt` | Administrators, SYSTEM | root |
| login of the keep-available user | `config/keep-available.json` | Administrators, SYSTEM | root, the service account |
| tunnel credentials | `config/cloudflared/tunnel-credentials.json` | Administrators, SYSTEM | root, the service account |
| Cloudflare account certificate | `config/cloudflared/cert.pem` | Administrators, SYSTEM | root |
| the provider's cached phone pairings | `<nickname>/pair_records` | Administrators, SYSTEM | the service account (and root) |
| the system's own phone pairing records | Windows: `C:\ProgramData\Apple\Lockdown`; macOS: `/var/db/lockdown` | as Apple's software sets it | as macOS sets it; the kit never reads or copies them |
| every hub password | MongoDB database `gads` | any program on the computer (section 3) | the same |
| farm token (a paired computer's key to its own site in Blossom, section 9) | `config/pairing.json` | Administrators, SYSTEM | root |
| password of hub user `blossom` | **not stored by the kit**: sent to Blossom through the pairing, or shown once; then only in Blossom (encrypted there) and in the hub database | | |
| password of hub user `admin` | **not stored by the kit**: you chose it | | |

How the kit handles them:

* Nothing secret is built in. There is no default secret anywhere; the
  restart service refuses to start without a secret of at least 32
  characters, read from a file, and compares it in constant time.
* Secrets are generated with the operating system's cryptographic random
  generator.
* The kit never passes them on a command line, never writes them to a log of
  its own, and does not keep them in the services' settings, which are the
  registry entries on Windows and the property lists in
  `/Library/LaunchDaemons` on macOS (the restart service gets the *path* of
  its secret file, not the secret). The macOS scripts hand logins to `curl`
  through its standard input, where the process list does not show them. One
  thing the kit cannot prevent is GADS itself logging request addresses that
  contain a session token: section 4, "Session tokens end up in the hub's
  log".
* `install.ps1` does not adopt a `C:\farm` it did not create. On Windows any
  signed-in user may create a folder in `C:\`, and the creator of a folder
  can always change who may write to it. A folder of that name which is not
  empty, and is not owned by Administrators with access for Administrators
  and SYSTEM only, stops the installer before anything in it is read or run;
  an empty one is deleted and created anew. The Administrators group is made
  the owner of the folder and of every secret file.
* `install.sh` applies the same rule to `/opt/farm`: a folder with content
  that root does not own, that a group or everybody may write to, or that
  sits in a folder others can change, stops the installer. Root owns
  everything the services run and everything they read as configuration
  (files `600` or `640`, folders `700` or `750`); the service account can
  read what it needs and can write only to its logs (`/opt/farm/logs`), the
  database, its temporary folder and the provider's own folder. It cannot
  change its own programs, scripts or settings. A provider nickname that is
  the name of one of the kit's own folders, in any letter case, is refused:
  it would hand that folder to the service account.
* On macOS, **root never writes into a folder the service account can
  write to.** The two services that run as root keep their logs in
  `/opt/farm/logs-root`, which only root can open. The logs in
  `/opt/farm/logs` are rotated by the wrapper that starts each service
  (`services/farm-run.sh`), running as that service's own account, not by a
  system job with root's rights: in a folder another account can write to,
  a file name can be made to lead elsewhere.
* The kit's own folder is protected the same way, because its scripts run
  with full rights at every maintenance run: `C:\blossom-farm-kit` is
  locked by the installer (Administrators and SYSTEM may change it), and a
  kit in a folder that cannot be protected is refused; on macOS the kit is
  copied to `/opt/blossom-farm-kit`, owned by root, before anything else is
  done, wherever it was unpacked. A kit folder with a link in it, or with a
  file somebody else owns, is not accepted.
* Passwords you type are read hidden and are not kept in the console history.
* The two values meant for Blossom are sent to it by the installer when the
  computer is paired (section 9), and are then not printed at all. Without a
  pairing they are printed once, at the end: close the window afterwards,
  and do not run the installer inside a recording (`Start-Transcript`,
  screen sharing).
* An **export archive** (the `export-farm` script) contains all of it and is
  not encrypted. It is written to the farm's `export` folder (Administrators
  only, or root only) unless you name another place, and on a disk with file
  permissions (NTFS on Windows, APFS on a Mac) the file is restricted before
  the first secret is written into it. A USB stick formatted FAT32 or exFAT
  has no file permissions: the script says so and asks first. Handle the
  archive like a master key and delete it after the move.

## 7. The restart service

It is reachable from the internet and runs with full rights (as SYSTEM on
Windows, as root on macOS: it is the one farm program that does), so it is
deliberately small (`services/restart-server.js`, one file, no
dependencies):

* five fixed actions and one status call; a request can choose among them and
  nothing else. No part of a request ever reaches a command line: the service
  runs `sc.exe start|stop|query` on Windows and
  `/bin/launchctl print|bootstrap|kickstart|bootout` on macOS, with service
  names that are constants in the file (on macOS also `/bin/ps`, for the
  process number launchd names: a service whose start wrapper still waits
  for another service is not reported as running);
* every request needs the secret, including unknown paths (they get 401, not
  404, so a stranger learns nothing);
* it sends no CORS headers: it is called by Blossom's servers, never by a
  browser;
* it listens on `127.0.0.1` and the address is not configurable.

What the secret is worth to an attacker: stopping and starting your farm
programs. It cannot read data or control a phone. Rotate it with the
`rotate-secrets` script (`-RestartSecret`, `--restart-secret`) if it may have
leaked.

## 8. What the kit accepts as a trade-off

* **On Windows** the six services run as **LocalSystem**, as on the farm this
  kit was modelled on. A flaw in GADS, in the gate or in the restart service
  would therefore be a flaw with full rights on that PC. The kit does not set
  up a restricted service account there: the provider needs Apple's device
  service and the pairing records, and the restart service needs the right to
  start and stop services. This is one more reason to dedicate the PC to the
  farm.
* **On macOS** MongoDB, the hub, the provider, the gate, keep-available and
  the tunnel run as `_blossomfarm`, a hidden account without a password, a
  shell or a home folder that the installer creates; a flaw in one of them
  gives that account's rights, not root's. Two things run as root: the
  restart service, because only root may start and stop system services,
  and the small job that loads the packet filter rule. What the service
  account can still do is a great deal: it runs the provider, so it controls
  the phones, and it can read the database and the tunnel credentials.
* **On macOS, FFmpeg and OpenSSL come from Homebrew**, and Homebrew's folder
  belongs to the Mac user who installed it, not to root. Whoever can act as
  that user can replace FFmpeg, and the provider runs FFmpeg (as the service
  account, never as root). Everything else the farm runs is in `/opt/farm`
  and belongs to root; so does an FFmpeg of your own that you name with
  `--ffmpeg`, which the installer copies there. Nothing pins that file: the
  kit has no checksum for an FFmpeg you bring. This is one more reason not to use the farm Mac, or
  that user, for anything else.
* **On macOS, an unattended restart needs FileVault off** (README, step 6).
  With FileVault off, the disk is readable by whoever takes the Mac: the
  restart secret, the tunnel credentials and every hub password are on it.
  With FileVault on, they are protected and the farm does not come back by
  itself after a power cut. The installer changes neither; it tells you
  which one it found.
* The hub and provider binaries are **not code-signed** by a publisher's
  certificate (on Apple Silicon they carry the signature without an
  identity that macOS requires of every program, which says nothing about
  who made them). Their integrity rests on the SHA-256 values pinned in
  `versions.json`, which the installer and the status script check. The
  provider is rebuilt by this repository's workflow from public source and
  must reproduce the pinned value bit for bit. On macOS the same goes for
  Node.js, MongoDB and cloudflared, which the installer downloads from their
  publishers and checks against pinned SHA-256 values; a file fetched by the
  installer carries no "quarantine" mark, so Gatekeeper is not asked about
  it. A file you bring yourself (`--provider-binary`, `--ffmpeg`) carries
  that mark when it came through a browser, and a service could not start
  it; the installer takes the mark off its own copy in `/opt/farm/bin`, for
  the provider only after the pinned checksum matched. The checksum is the
  check.
* **With Appium (`-WithAppium`, `--with-appium`), npm packages are not checksum-pinned.** The kit pins
  the *versions* of three packages (`appium`, `appium-xcuitest-driver`,
  `appium-gads`, in `versions.json`). Each of them pulls in hundreds of other
  packages, whose versions npm chooses on the day of installation, and npm
  runs the install scripts of all of them: as Administrator on Windows, as
  the service account on macOS. That is how every Appium installation works,
  GADS's own instructions included, and it means: a compromised package
  anywhere in that tree would run with those rights on the farm computer.
  The kit installs the GADS plugin itself during installation, so that the
  provider service finds it in place and does not fetch it by itself when it
  starts; if the plugin is ever missing
  or of another version, GADS installs it at start (`provider/provider.go`).
  Appium is off by default for these reasons; add it only if you use it.
* **Updates are manual.** Nothing here updates itself: you decide when to move
  to a newer kit. Watch this repository's releases.

## 9. Pairing with Blossom

Pairing is how the farm's addresses and its two secrets reach Blossom without
anybody copying them. It adds one new thing to protect, the **farm token**,
and one new connection, from the farm computer **to** Blossom. This section
says what is sent, what each party can do, and what can go wrong.

### What happens, in order

1. An admin of your workspace opens *Connect a computer* in Blossom. Blossom
   makes a **pairing code** and shows a command that contains it, together
   with Blossom's own https address.
2. The command downloads a small bootstrap file from a release of this
   repository and compares its SHA-256 with the value in the command; the
   bootstrap file checks the kit it downloads the same way (below, "The
   command").
3. At its start the installer makes a random **farm token** on the farm
   computer, stores it in the protected farm folder, and sends Blossom the
   pairing code, the token, the computer's name, its system and the kit
   version. Nothing about the farm itself yet: there are no addresses and no
   secrets at that point.
4. At its end the installer sends, with the farm token, the three addresses,
   the provider nickname, the hub user with its password, and the restart
   secret.
5. Blossom calls the farm from its servers (the same check as "Test
   connection") and shows the admin what it found, next to the computer's
   name, its system, the country it connected from and the addresses it
   sent. **The site is not used for anything until the admin presses
   Confirm.**

### The pairing code

* 20 characters from an alphabet of 32 (digits and capital letters without
  I, L, O and U), shown in five groups of four: **100 random bits**. It cannot
  be guessed; Blossom limits attempts all the same.
* It works **once**. The first computer that presents it binds it to that
  computer's farm token; anybody presenting it afterwards is refused.
* It is valid for **30 minutes**, and only for the workspace of the admin who
  made it. Blossom stores its SHA-256, not the code.
* The installer uses the code within the first minute and then forgets it. It
  is not written to disk; a hash of it is, so that running the same command a
  second time is recognised as the same pairing.
* While it is valid, the code is in the command you pasted: in the window, in
  the shell's history, and for a moment in the list of running programs. On a
  computer used for the farm only, that is nobody but you. After its one use
  it is worth nothing.

### The farm token

* Made on the farm computer from the operating system's random generator:
  `bft_` and 256 random bits. Blossom receives it once, in step 3, and keeps
  only its SHA-256.
* Stored in `config/pairing.json` in the farm folder, readable by
  Administrators and SYSTEM (Windows) or root (macOS) only, next to the
  address of the Blossom it belongs to. It is sent to that address and to no
  other; the scripts take the address from this file, never from an option.
* **What it can do:** read the state of its own pairing; replace the
  connection details of its own site (addresses, nickname, hub user, hub
  password, restart secret); report the versions the computer runs; give
  itself up (unpair). **What it cannot do:** read anything from Blossom, not
  even the credentials it sent; see or touch another site or another
  workspace; sign in to Blossom; delete the site.
* New **credentials** for the addresses an admin confirmed are accepted at
  once: this is how `rotate-secrets` works without anybody typing. New
  **addresses** are not: a changed host name waits until an admin has looked
  at the new addresses and confirmed them. Until then Blossom goes on using
  the addresses that were confirmed; the token cannot switch a site off or
  point it elsewhere by itself. If the admin declines, the new addresses are
  dropped and the computer stays paired.
* What an admin confirms is exactly what was on the page: a confirmation
  names the description it was given for, and Blossom refuses it when the
  computer has sent another one in the meantime, and shows the new one.
* It does not expire by itself. It ends when an admin unpairs the computer or
  removes the site in Blossom, when the computer unpairs itself
  (`uninstall` with `-Unpair` / `--unpair`), or when a new pairing code is
  used on the same computer (the old token is given up). For a code of
  another workspace that takes a typed yes: "A genuine command from another
  workspace", below.
* It travels with an export archive (`export-farm`), so that a farm moved to
  another computer keeps its pairing. That is one more reason to treat the
  archive like a master key.

### The connection to Blossom

* **https only, to one address.** The address comes from the command Blossom
  printed and is stored with the token. The scripts refuse an address that
  is not `https://host` (no path, no user name, no `http://`) before anything
  is sent.
* **The certificate is verified** against the certificates the operating
  system trusts, with TLS 1.2 or later. There is no option to skip this. If
  it fails, nothing is sent and the message says so. A network that opens
  encrypted connections (some company proxies and antivirus products do)
  will fail here: that is intended.
* **A redirect is refused, not followed.** If the address answers "go
  elsewhere", the scripts stop. Credentials never follow a redirect to
  another address.
* A request that did not arrive, or that Blossom answered with "busy", is
  repeated a few times with growing pauses. A refusal is not repeated.
* Nothing secret is put on a command line, written to a log, or printed. On
  macOS the request body goes to `curl` through its standard input.
* Blossom's answers contain no secret: the token was made on the farm
  computer, so there is none to send back.

### What can go wrong, and what stops it

* **Somebody else gets your command** (over your shoulder, from a
  screenshot, from a chat it was pasted into). If they run it first, *their*
  computer is the one that appears in Blossom. Your own run then fails with
  "this pairing code was already used", which tells you. Their computer does
  not become a site of yours unless an admin confirms it, and the page shows
  its name, its system, the country it connected from and its addresses
  beforehand. **Decline what you do not recognise.** If they run it after
  you, the code is used up. If nobody runs it, it is dead after 30 minutes.
* **Somebody talks an admin into pairing a farm that is not yours** ("paste
  this code request for me", or a command that looks like Blossom's but
  carries another address). What Blossom would gain is a farm that the other
  person controls: your team would work on, and sign in to accounts on,
  phones somebody else can watch. The confirmation page is the stop: a
  computer name, a country and a domain that are not yours. Confirm only a
  computer you set up yourself, with host names under your own domain.
* **A command that carries another address than your Blossom's.** The
  installer would send the farm's credentials to that address. Take the
  command from Blossom itself, signed in, and not from a message, a document
  or a helpful stranger. The installer prints the address it is about to
  talk to, and shows it again at the end.
* **A genuine command from another workspace.** Anybody can open a
  workspace in Blossom, give it your agency's name, make a command there and
  send it to you ("run this to repair your farm"). The command is real: the
  address is Blossom's, every checksum matches. Run on your paired farm
  computer it would move the farm: a new password for the hub login, and
  the addresses, that password and the restart secret sent to *their*
  workspace, where they confirm and control your phones. So a paired
  computer does not follow such a command by itself. The installer compares
  the address of Blossom and the **identifier** of the workspace (which
  Blossom assigns and nobody chooses; the name is not compared) with the
  pairing it holds. When they differ it shows both, says what moving means,
  and goes on only when the word `replace` is typed at the keyboard, or the
  command carries `-ReplacePairing` / `--replace-pairing`. With no keyboard
  and no switch it stops and changes nothing; a claim it had already made in
  the other workspace is given up again, and that workspace has received the
  computer's name and nothing else. This stops the command, not you: do not
  type `replace` for a command you did not take from your own Blossom.
* **The command is swapped under the admin's eyes.** Whoever used a leaked
  command could send addresses the admin recognises, wait for the confirm
  page to open, and send their own. A confirmation is therefore bound to
  the description the page showed: when the computer has sent another one
  since, Blossom refuses the confirmation and shows the new addresses.
* **Somebody uses a leaked command to push your own site aside.** A computer
  that sends the addresses of a site you already have does not replace that
  site unless the admin says so on the confirm page, and only when
  Blossom's check of what it sent passed, which takes the hub's real login.
  Until then the existing site and its paired computer are untouched.
* **The farm token is stolen** (somebody had Administrator or root on the
  farm computer). With it they can propose another hub for your site, which
  waits for an admin while Blossom goes on using the confirmed addresses, or
  replace the stored hub password with a wrong one, which breaks the site
  until you rotate. They can read nothing from Blossom. But somebody with those rights
  on the farm computer already controls the farm itself; unpair the computer
  in Blossom, then deal with the computer.
* **Blossom is unreachable or says no** at the end of the installation. The
  farm is installed all the same, and the values are printed for manual
  entry.

### The command

The command Blossom shows does not pipe a download into a shell. It:

1. downloads `bootstrap.ps1` (Windows) or `bootstrap.sh` (macOS) from a
   named release of this repository into a file;
2. computes the file's SHA-256 and compares it with the value written in the
   command itself. Blossom's maintainers copy that value from the kit release
   into Blossom when they adopt a release, so it does not come from the same
   place as the file;
3. runs the file only if the two are equal.

The bootstrap file carries the SHA-256 of the release's `SHA256SUMS`, and
`SHA256SUMS` carries the SHA-256 of the kit archive. So each download is
checked against a value that was fixed before it: the command pins the
bootstrap file, the bootstrap file pins the list, the list pins the kit. A
file that fails is deleted; nothing of it is unpacked or run. The kit then
checks every program it downloads against `versions.json`, as before.

The kit is unpacked to `C:\blossom-farm-kit` or `/opt/blossom-farm-kit`,
writable by Administrators or root only: these scripts run with full rights
later, so nobody else may change them. A kit you download and unpack by hand
ends up protected in the same way: the installer and every script check the
kit folder before they do anything else (section 6).

What this chain does not do: it does not prove that the release itself is
good. That rests on this repository, as it does for a kit you download by
hand. Read the scripts; they are plain text.

## 10. Reporting a problem

If you find a way around any of the protections above, please do not open a
public issue. Use the repository's private vulnerability reporting
(Security → Report a vulnerability). Problems in GADS itself belong to the
GADS project.
