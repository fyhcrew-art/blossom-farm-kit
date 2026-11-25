# Preparing the iPhones

Do this after `install.ps1` has finished and Blossom's "Test connection" is
green (with *Check* on Phones). Set up **one phone completely** before you
touch the others.

This chapter follows the GADS 6.0.0 documentation and source. The official
GADS instructions are the reference for every detail:
[provider documentation](https://github.com/shamanec/GADS/blob/v6.0.0/docs/provider.md)
and [FAQ](https://github.com/shamanec/GADS/blob/v6.0.0/docs/faq.md). The hub's
web page belongs to GADS; a button there may be worded slightly differently
from what is written here.

The hub's own page is used a lot in this chapter. Open it **on the farm PC**
at `http://127.0.0.1:10000` and sign in as `admin` with the password you chose
during installation.

## 0. What you need

* **Your own Apple Developer account.** The helper app that taps and swipes on
  the phone (WebDriverAgent, "WDA") is a development app, and iOS only runs
  development apps that are signed for that very phone. Use the paid **Apple
  Developer Program**: a signature lasts one year, and each iPhone is
  registered in the account by its UDID (Apple allows 100 iPhones per
  membership year; a removed phone keeps its slot until the yearly reset). A
  free Apple ID signs for 7 days only and needs Xcode on a Mac with the phone
  attached, so it does not carry a farm.
* **Apple's USB support on the PC: iTunes from Apple's own installer.**
  Download *iTunes for Windows* from Apple's website as an installer file
  (`iTunes64Setup.exe`; at the time of writing <https://www.apple.com/itunes/>
  offers it under "Looking for other versions", next to the button that leads
  to the Microsoft Store) and install it before plugging in a phone. It registers a
  Windows service called **Apple Mobile Device Service**, which starts with
  the PC and runs with nobody signed in. That is what a farm needs: the GADS
  provider is a Windows service too and talks to the phones through it. GADS's
  own documentation names iTunes.

  Do **not** rely on the Microsoft Store apps (*Apple Devices*, or iTunes
  from the Store). As far as we could establish, they do not install that
  Windows service; their device process runs only inside a signed-in Windows
  session. The farm would then work while you are logged in and, after a
  power cut or a Windows Update restart, show every phone as Offline until
  somebody signs in at the PC. We have not measured this on every Windows
  version; `install.ps1` tells you which of the two it found, and the check
  that settles it is simple: `Get-Service 'Apple Mobile Device Service'` must
  show the service, and README step 6 (restart, touch nothing, phones come
  back) must pass. If you must use a Store app, set the PC to sign in
  automatically, and accept what that means for a PC that holds the farm's
  secrets.
* A Mac is not needed.

## 1. On each iPhone

1. **Update iOS** if the phone is on iOS 17.0 to 17.3: GADS 6 cannot run WDA
   on those versions and says so in the provider log. 17.4 or later is fine;
   so is iOS 16.
2. **Remove the passcode** (Settings → Face ID & Passcode → Turn Passcode
   Off). GADS cannot get past a passcode screen.
3. **Auto-Lock: Never** (Settings → Display & Brightness → Auto-Lock). GADS
   marks this as required: when the screen locks, iOS drops the connection WDA
   needs and the provider loops.
4. **Developer Mode** (iOS 16 and later): Settings → Privacy & Security →
   Developer Mode → on; the phone restarts and asks to confirm.
   GADS checks this and refuses a phone without it ("developer mode is not
   enabled" in the provider log). iOS shows the Developer Mode entry only
   after the phone has been connected to developer tools. If the entry is
   missing, reveal it from the PC with the open-source tool
   [go-ios](https://github.com/danielpaulus/go-ios), which GADS is built on:
   download its Windows release, plug the phone in and run
   `ios devmode enable`. (On a Mac, plugging the phone in with Xcode open does
   the same.)
5. Plug the phone into the PC and tap **Trust** when it asks. The provider is
   started with `--use-ios-pair-cache`, which keeps the pairing so that the
   question is not asked again after a reconnect.

## 2. WebDriverAgent: download it, then sign it with your Apple account

The kit contains no WebDriverAgent and no Apple file. There are two steps, and
both are yours.

### Step 1. Download the WebDriverAgent that GADS's author publishes for GADS

GADS, and the provider patch of this kit, only work with the GADS author's own
fork of WebDriverAgent; the mainstream one uses different coordinates and
lacks endpoints GADS calls. He publishes it pre-built:

* page: <https://github.com/shamanec/WebDriverAgent/releases> (the release
  named `latest`, file `WebDriverAgent.ipa`);
* direct link:
  <https://github.com/shamanec/WebDriverAgent/releases/download/latest/WebDriverAgent.ipa>.

This is the download the GADS documentation names under
[Prebuilt custom WebDriverAgent](https://github.com/shamanec/GADS/blob/v6.0.0/docs/provider.md#prebuilt-custom-webdriveragent).
Do not take WebDriverAgent from anywhere else. The file is not signed for your
phones yet; that is step 2.

### Step 2. Sign it with your Apple account and upload it to the hub

**At Apple** (developer.apple.com → Certificates, Identifiers & Profiles):

1. *Devices*: register every iPhone (name and UDID; section 4 says where to
   find the UDID).
2. *Identifiers*: create an App ID of the **wildcard** kind whose bundle ID
   is a single star: `*`. This matters. The pre-built WebDriverAgent has the
   bundle identifier `com.facebook.WebDriverAgentRunner.xctrunner`, and the
   hub's signing keeps that identifier (see "The bundle ID" below). A profile
   for `*` covers it; a profile for `com.yourname.*` does **not**, and iOS
   then refuses to install the app. (If the Apple site does not let you
   create `*`, sign outside the hub instead: "Signing outside the hub"
   below.)
3. *Certificates*: create an **Apple Development** certificate. Apple asks for
   a certificate signing request (CSR). The hub page makes one without a Mac:
   Admin → Files → generate a signing request; it downloads a zip with the
   request and its private key. Upload the request at Apple, download the
   certificate (`.cer`), and keep the private key with it.
4. *Profiles*: create an **iOS App Development** provisioning profile for that
   App ID, that certificate and all your phones, and download it
   (`.mobileprovision`).

**In the hub page** (Admin → Files → WebDriverAgent → sign and upload), give
it:

* the `WebDriverAgent.ipa` from step 1;
* the `.mobileprovision` profile;
* the signing identity: either the certificate and its private key (what you
  have after the steps above), or a `.p12` file with its password.

The hub signs the file (with the open-source tool zsign, built into GADS) and
stores the result. **Installing it on the phones is done by GADS:** once iOS
is switched on for the provider (section 3), the provider puts the signed
WebDriverAgent on each phone and starts it by itself.

**The bundle ID. Read this, it is the usual reason a phone never goes live.**

* The pre-built `WebDriverAgent.ipa` from step 1 has the bundle identifier
  `com.facebook.WebDriverAgentRunner.xctrunner` (checked in the file's
  `Info.plist`).
* Signing in the hub page does not change it: in GADS 6.0.0 the hub runs
  zsign without a new bundle identifier (`hub/signing/signing.go`), so the
  signed app keeps `com.facebook.WebDriverAgentRunner.xctrunner`.
* The value to enter as **WDA bundle ID** in section 3 is therefore
  **`com.facebook.WebDriverAgentRunner`**. GADS adds `.xctrunner` by itself
  (`provider/config/config.go`) and starts the app under that name.
* The provisioning profile must cover that identifier, which is why the App
  ID above is `*`.

**Signing outside the hub** (alternative). GADS's documentation names zsign,
fastlane sigh and codesign. With these you can give the app an identifier of
your own, and then an App ID such as `com.yourname.*` is enough. With zsign:

```
zsign -k key.pem -c certificate.pem -m profile.mobileprovision -b com.yourname.WebDriverAgentRunner.xctrunner -o WebDriverAgent-signed.ipa WebDriverAgent.ipa
```

Upload the result under Admin → Files as a WebDriverAgent upload (without
signing), and enter `com.yourname.WebDriverAgentRunner` as WDA bundle ID in
section 3. The rule is always the same: **WDA bundle ID = the bundle
identifier inside the signed app, minus `.xctrunner`.** Building
WebDriverAgent yourself in Xcode on a Mac, where you choose the identifier in
Xcode, is described under
[Build WebDriverAgent IPA file manually using Xcode](https://github.com/shamanec/GADS/blob/v6.0.0/docs/provider.md#build-webdriveragent-ipa-file-manually-using-xcode).

Notes that save hours:

* **A new phone later** means: register its UDID at Apple, download the
  profile again, sign and upload again.
* **Expiry.** When the signature runs out, every phone stops responding on the
  same day. Put the date in a calendar and repeat step 2 before it.

## 3. Switch iOS on for the provider

`install.ps1` created the provider with iOS switched **off**, because a GADS
provider that has iOS on but no WebDriverAgent refuses to start
("Could not provide WebDriverAgent.ipa file from MongoDB").

Now that a signed WDA is uploaded, in the hub page: Admin → Providers →
your provider (`Provider1`):

* turn **Provide iOS** on;
* choose the uploaded **WebDriverAgent** build;
* enter the **WDA bundle ID**: `com.facebook.WebDriverAgentRunner` when you
  signed the pre-built file in the hub page (section 2, "The bundle ID");
  otherwise the identifier you signed with, without `.xctrunner`;
* leave the host address `127.0.0.1` and the port `10001` as they are;
* leave **Set up Appium servers** as the installer set it: off after a plain
  `install.ps1`, on after `install.ps1 -WithAppium`. Do not switch it on by
  hand without Appium installed: the provider then refuses to start ("Appium
  is not available"). With it off, GADS offers the phones for remote control,
  which is what Blossom uses (README, "Appium: off unless you ask for it");
* save.

Then restart the provider: in Blossom, Phone Farm → Services → *Restart
Provider*; or on the PC `Restart-Service GadsProvider`.

Check `C:\farm\Provider1\provider.log`: it should not end in an error.

## 4. Register each phone in the hub

Admin → Devices → add a device:

* **UDID**: the phone's identifier. In iTunes,
  click the serial number on the phone's summary page until it shows the UDID
  (25 characters with a hyphen on recent iPhones, 40 on older ones).
* **Name**: anything; Blossom shows it until you rename the phone there.
* **OS**: iOS, and the iOS version.
* **Provider**: your provider.
* **Screen width and height**: fill them in. Blossom places taps with them;
  an empty or wrong size makes taps land in the wrong place. The form's
  tooltips say which numbers GADS expects.
* **Stream type**: the iOS WebRTC type (section 5).

GADS asks for a provider restart after a device is added or changed.

The phone should now show in the hub page, and you should be able to open and
control it there. **If it does not work in the hub page, it will not work in
Blossom**: fix it here first. The GADS FAQ covers the usual WDA install loops.

A phone that is connected but never becomes live, with WebDriverAgent install
or launch errors in `C:\farm\Provider1\provider.log`: check first that the WDA
bundle ID in the provider's settings is the identifier inside the signed app
minus `.xctrunner`, and that the provisioning profile covers that identifier
and contains this phone's UDID (section 2).

## 5. Live video

Blossom's Control page opens the provider's `ios-webrtc` address for a phone.
GADS serves that address by taking the screen stream of WebDriverAgent and
encoding it to H.264 with **FFmpeg** on the PC; the installer installs FFmpeg
and puts it on the provider's path. Choose the iOS WebRTC stream type
(`ios_webrtc_ffmpeg`) for each phone.

Nothing has to be installed or started on the phone for the video. GADS also
has a **Broadcast Extension** (`gads-broadcast.ipa`, started from Control
Center), which serves a different address (`ios-webrtc-broadcast`) that
Blossom does not open; you do not need it.

No picture although the phone is Online: `scripts\status.ps1` must list FFmpeg,
and the browser must be able to reach the PC directly (`docs/network.md`,
section 4).

## 6. Optional: supervised phones

A supervised phone can be paired without the Trust question. It needs a Mac
with Apple Configurator, and **supervising a phone erases it**. GADS describes
the steps under
[Supervise devices](https://github.com/shamanec/GADS/blob/v6.0.0/docs/provider.md#supervise-devices)
(supervise every phone with the same identity, export the identity as `.p12`,
upload it under Admin → Files, enter its password in the provider's settings).
Blossom does not need supervision.

## 7. Then, in Blossom

Phones appear on the Phone Farm page under their GADS name. On **Devices**
give each one its name, market, accounts and people.

## Checklist for phone number two and onwards

- [ ] iOS not 17.0–17.3, passcode off, Auto-Lock Never, Developer Mode on
- [ ] UDID registered at Apple and included in the provisioning profile (sign and upload WDA again if you had to add it); WDA bundle ID in the provider still matches the signed app
- [ ] plugged into a powered hub, Trust tapped
- [ ] added under Admin → Devices with screen size and stream type, assigned to the provider
- [ ] provider restarted, phone controllable in the hub page
- [ ] Online in Blossom, picture in Control
