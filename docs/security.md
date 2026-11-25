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

### What listens on the PC, and what your local network can reach

* MongoDB, the hub, the provider's own port, the provider gate and the
  restart service listen on `127.0.0.1` only: nothing outside the PC can
  connect to them. `install.ps1` and `scripts\status.ps1` check these five
  ports.
* **The per-phone ports are different.** For every connected iPhone the GADS
  provider opens three more ports (WebDriverAgent, the screen stream, the
  WebDriverAgent video), on port numbers it picks at run time, and upstream
  GADS opens them on **all** network addresses of the PC, not on `127.0.0.1`
  (`provider/devices/ios.go`, through go-ios `ios/forward/forward.go`). With
  `-WithAppium` the same goes for one Appium server per phone
  (`provider/devices/appium.go` starts it without an address). None of these
  ports asks for a login: whoever reaches a WebDriverAgent port can take
  screenshots and tap on that phone, past the hub, the gate and the tunnel.
* What closes them: **Windows Firewall.** `install.ps1` creates rules named
  "Blossom farm - no network access to …" that refuse incoming TCP connections
  to `GADS-drag.exe`, to `GADS.exe` and, with `-WithAppium`, to `node.exe`.
  A block rule wins over any "allow" rule for the same program (for example
  one made long ago by clicking "Allow access"). Connections from the PC to
  itself are never filtered by Windows Firewall, so the farm is unaffected;
  the live video is UDP and is not touched. `scripts\status.ps1` lists every
  port the farm programs have open, says whether a rule covers it, and warns
  when Windows Firewall is switched off.
* What that means for you: **keep Windows Firewall on.** If another security
  product replaces it, the kit's rules do nothing, and that product must
  block incoming connections to the PC itself. Either way, a farm PC belongs
  on a network you control, not on a shared office or guest Wi-Fi. The kit
  does not change how GADS opens these ports; the rule is the protection.

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

`install.ps1` and `scripts\self-test.ps1` check from outside that the provider
host name answers **401** without a token. If that check ever fails, stop the
tunnel (`Stop-Service Cloudflared`) until you know why.

## 3. What GADS itself does not protect

Read in the 6.0.0 source. None of this is specific to this kit; it is the
state of the software the farm runs on.

* **Hub passwords are stored as plain text** in MongoDB (`common/db/user.go`)
  and compared directly. Anyone who can read the database reads every hub
  password. This is why the kit insists that MongoDB listens on `127.0.0.1`
  only and why `C:\farm` and the export archive are protected.
* **MongoDB has no login** in this setup. It is reachable only from the PC
  itself, but from *any* program and *any* Windows user on that PC. Use the
  PC for the farm only; do not let other people sign in to it; do not install
  software you do not trust on it.
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

  If you install with `-WithAppium`, the first point is the only thing between
  the internet and the Appium servers of your phones for anyone who knows a
  phone's UDID. cloudflared matches the rule against the decoded request path
  (`ingress/ingress.go` in its source), the same form the hub checks, so
  spelling the word with percent-codes does not get around it. To see it for
  yourself, from any computer with curl, both of these must print **403**:
  `curl -s -o NUL -w "%{http_code}" --path-as-is https://<hub host>/device/x/appium/status`
  `curl -s -o NUL -w "%{http_code}" --path-as-is https://<hub host>/device/x/%61ppium/status`
  Do not edit the tunnel configuration by hand, and do not put a Cloudflare
  Access rule into it. A side effect of the rule: the hub page's Appium log
  view does not load through the public address; open the hub page on the PC
  (`http://127.0.0.1:10000`) for that.
* **Some hub endpoints are registered outside the login check**
  (`hub/router/handler.go`: everything registered before
  `auth.AuthMiddleware()` is added). All of them, and what the kit does:

  | Hub path | What it gives without a login | The kit |
  |---|---|---|
  | `POST /provider-update` | how a provider reports to the hub; a stranger could feed it false device states | refused at the tunnel (403) |
  | `GET /admin/provider/<nickname>/info` | the provider's record from the database, sent again every second for as long as the connection stays open: operating system, port, WebDriverAgent bundle ID and, if you set one, the **supervision password** (`docs/phones.md`, section 6). Each open connection also costs the hub one database query per second | refused at the tunnel (403); the self-test checks it from outside. The hub page's provider view therefore only works on the PC (`http://127.0.0.1:10000`) |
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
that output in `C:\farm\logs\hub.log` and `provider.log`. The hub accepts its
session token as part of an address (`…?token=…`, used for WebSocket
connections), so **`hub.log` can contain session tokens that are valid for up
to an hour**, and with the `blossom` user those are administrator tokens. The
kit cannot switch this off in the hub: it runs the publisher's own program.
What it does:

* the provider gate removes the token from the address before the provider
  sees it, so `provider.log` does not collect the tokens of the live-video
  connections;
* `C:\farm\logs` is readable by Administrators and SYSTEM only;
* `scripts\status.ps1 -Logs` masks tokens and your host names before it
  prints the end of a log.

What you must do: **never post, mail or upload a file from `C:\farm\logs`.**
When you ask for help, copy the output of `scripts\status.ps1 -Logs`.

### When somebody leaves, or loses Phone Farm access

1. Remove their access in Blossom.
2. On the farm PC: `scripts\rotate-secrets.ps1 -HubUser` and enter the new
   hub password in Blossom (Farm setup → Edit). If that person also knew the
   `admin` password or sat at the farm PC: `-All`.
3. In the hub page (`http://127.0.0.1:10000`, Admin → Users) delete every
   user you do not recognise. A hub administrator can create further
   administrators; a leaver may have made one.
4. A token they already hold works for at most one more hour. To end all
   sessions at once, replace the signing key in the hub page (Admin → Secret
   keys).
5. If they had physical access to the phones or the PC, treat the accounts on
   the phones as exposed as well.

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

## 6. The secrets on the PC

| Secret | Where it is | Who can read it |
|---|---|---|
| restart secret | `C:\farm\config\restart-secret.txt` | Administrators, SYSTEM |
| login of the keep-available user | `C:\farm\config\keep-available.json` | Administrators, SYSTEM |
| tunnel credentials, Cloudflare account certificate | `C:\farm\config\cloudflared\` | Administrators, SYSTEM |
| phone pairing records | `C:\farm\<nickname>\pair_records`, `C:\ProgramData\Apple\Lockdown` | the first: Administrators, SYSTEM; the second: as Apple's software sets it |
| every hub password | MongoDB database `gads` | any program on the PC (section 3) |
| password of hub user `blossom` | **not stored by the kit**: shown once, then only in Blossom (encrypted there) and in the hub database | |
| password of hub user `admin` | **not stored by the kit**: you chose it | |

How the kit handles them:

* Nothing secret is built in. There is no default secret anywhere; the
  restart service refuses to start without a secret of at least 32
  characters, read from a file, and compares it in constant time.
* Secrets are generated with the operating system's cryptographic random
  generator.
* The kit never passes them on a command line, never writes them to a log of
  its own, and does not keep them in the services' registry entries (the
  restart service gets the *path* of its secret file, not the secret). One
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
* Passwords you type are read hidden and are not kept in the console history.
* The two values meant for Blossom are printed once, at the end. Close the
  window afterwards. Do not run the installer inside a recording
  (`Start-Transcript`, screen sharing).
* An **export archive** (`scripts\export-farm.ps1`) contains all of it and is
  not encrypted. It is written to `C:\farm\export\` (Administrators only)
  unless you name another place, and on an NTFS drive the file is restricted
  before the first secret is written into it. A USB stick formatted FAT32 or
  exFAT has no file permissions: the script says so and asks first. Handle
  the archive like a master key and delete it after the move.

## 7. The restart service

It is reachable from the internet and runs as SYSTEM, so it is deliberately
small (`services/restart-server.js`, under 300 lines, no dependencies):

* five fixed actions and one status call; a request can choose among them and
  nothing else. No part of a request ever reaches a command line: the service
  runs `sc.exe start|stop|query` with service names that are constants in the
  file;
* every request needs the secret, including unknown paths (they get 401, not
  404, so a stranger learns nothing);
* it sends no CORS headers: it is called by Blossom's servers, never by a
  browser;
* it listens on `127.0.0.1` and the address is not configurable.

What the secret is worth to an attacker: stopping and starting your farm
programs. It cannot read data or control a phone. Rotate it with
`scripts\rotate-secrets.ps1 -RestartSecret` if it may have leaked.

## 8. What the kit accepts as a trade-off

* The six services run as **LocalSystem**, as on the farm this kit was
  modelled on. A flaw in GADS, in the gate or in the restart service would
  therefore be a flaw with full rights on that PC. The kit does not set up a
  restricted service account: the provider needs Apple's device service and
  the pairing records, and the restart service needs the right to start and
  stop services. This is one more reason to dedicate the PC to the farm.
* The hub and provider binaries are **not code-signed**. Their integrity
  rests on the SHA-256 values pinned in `versions.json`, which the installer
  and `scripts\status.ps1` check. The provider is rebuilt by this repository's
  workflow from public source and must reproduce the pinned value bit for bit.
* **With `-WithAppium`, npm packages are not checksum-pinned.** The kit pins
  the *versions* of three packages (`appium`, `appium-xcuitest-driver`,
  `appium-gads`, in `versions.json`). Each of them pulls in hundreds of other
  packages, whose versions npm chooses on the day of installation, and npm
  runs the install scripts of all of them, as Administrator. That is how
  every Appium installation works, GADS's own instructions included, and it
  means: a compromised package anywhere in that tree would run with full
  rights on the farm PC. The kit installs the GADS plugin itself during
  `install.ps1`, so that the provider service (SYSTEM) finds it in place and
  does not fetch it by itself when it starts; if the plugin is ever missing
  or of another version, GADS installs it at start (`provider/provider.go`).
  Appium is off by default for these reasons; add it only if you use it.
* **Updates are manual.** Nothing here updates itself: you decide when to move
  to a newer kit. Watch this repository's releases.

## 9. Reporting a problem

If you find a way around any of the protections above, please do not open a
public issue. Use the repository's private vulnerability reporting
(Security → Report a vulnerability). Problems in GADS itself belong to the
GADS project.
