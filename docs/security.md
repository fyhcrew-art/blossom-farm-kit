# Security

A phone farm reachable from the internet is a remote control for your
phones and for every account signed in on them. This page says plainly what
the kit exposes, what protects it, and where the protection ends. The
statements about GADS come from reading its 6.0.0 source code
(<https://github.com/shamanec/GADS>, tag `v6.0.0`); file names are given so
that you can check them.

## 1. What is exposed to the internet

Three https host names, through the Cloudflare Tunnel. Nothing else: no port
is open on your router, and every farm program listens on `127.0.0.1` only
(`install.ps1` and `scripts\status.ps1` verify it).

| Host name | Leads to | What protects it |
|---|---|---|
| hub | the GADS hub: its web page and its API | the hub's own user names and passwords |
| provider | the **provider gate**, and behind it the GADS provider | a valid hub session token, checked by the gate with the hub |
| restart | the restart service | the restart secret (256 random bits) |

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
  endpoints the provider only serves to local helpers.

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
  A Cloudflare rate-limiting rule on `/authenticate` is worth adding
  (`docs/network.md`, section 5).
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
  (`hub/router/handler.go`), among them `/available-devices` (the device list
  of a workspace, for whoever knows the workspace id) and `/provider-update`
  (how a provider reports to the hub). The kit refuses `/provider-update` at
  the tunnel; `/available-devices` stays reachable because the hub's own page
  needs it.
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
sign-in*. The same goes for "Under Attack" mode and challenge pages. If a
future version of Blossom can pass an Access service token, this page and the
installer will say so; until then the protections are the ones in section 1.

What does help at Cloudflare without breaking anything: the rate-limiting
rule from `docs/network.md`, and, if your team works from known countries
only, a WAF rule that blocks the hub and provider host names elsewhere. Be
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
* They are never passed on a command line, never written to a log, and not
  kept in the services' registry entries (the restart service gets the *path*
  of its secret file, not the secret).
* Passwords you type are read hidden and are not kept in the console history.
* The two values meant for Blossom are printed once, at the end. Close the
  window afterwards. Do not run the installer inside a recording
  (`Start-Transcript`, screen sharing).
* An **export archive** (`scripts\export-farm.ps1`) contains all of it and is
  not encrypted. Handle it like a master key and delete it after the move.

## 7. The restart service

It is reachable from the internet and runs as SYSTEM, so it is deliberately
small (`services/restart-server.js`, about 250 lines, no dependencies):

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
* **Updates are manual.** Nothing here updates itself: you decide when to move
  to a newer kit. Watch this repository's releases.

## 9. Reporting a problem

If you find a way around any of the protections above, please do not open a
public issue. Use the repository's private vulnerability reporting
(Security → Report a vulnerability). Problems in GADS itself belong to the
GADS project.
