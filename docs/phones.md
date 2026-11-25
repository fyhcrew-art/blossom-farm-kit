# Preparing the iPhones

Do this after `install.ps1` has finished and Blossom's "Test connection" is
green (with *Check* on Phones). Set up **one phone completely** before you
touch the others.

What is written here comes from the GADS 6.0.0 documentation and source, and
from the inventory of the farm this kit was modelled on. Where we could not
verify something on hardware it says so. The hub's web page is proprietary
and we cannot quote its labels exactly: a button may be called slightly
differently from what is written here.

The hub's own page is used a lot in this chapter. Open it **on the farm PC**
at `http://127.0.0.1:10000` and sign in as `admin` with the password you chose
during installation.

## 0. What you need, honestly

* **An Apple Developer account.** The helper app that taps and swipes on the
  phone (WebDriverAgent, "WDA") is a development app, and iOS only runs
  development apps that are signed for that very phone.
  * With the paid **Apple Developer Program** (99 USD a year at the time of
    writing) a signature lasts one year. Each iPhone must be registered in the
    account by its UDID; Apple allows 100 iPhones per membership year, and a
    removed phone keeps its slot until the yearly reset.
  * With a **free** Apple ID a signature lasts 7 days and can only be made
    with Xcode on a Mac with the phone attached. That is not workable for a
    farm.
* **A Mac is not strictly required**, but it makes two things easier:
  building WDA yourself in Xcode, and supervising phones. Both are optional
  and described by GADS in its
  [provider documentation](https://github.com/shamanec/GADS/blob/v6.0.0/docs/provider.md).
* **Apple's USB support on the PC.** GADS's documentation asks for iTunes on
  Windows. The farm this kit was modelled on uses the **Apple Devices** app
  from the Microsoft Store instead, which brings the same device service.
  Install one of them (not both) before plugging in a phone. `install.ps1`
  warns when it finds neither.

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
   *If the Developer Mode entry is not there:* iOS only shows it after the
   phone has been used with developer tools. On a Mac, plugging it in with
   Xcode open is enough. On Windows, the open-source tool
   [go-ios](https://github.com/danielpaulus/go-ios) has a command for it
   (`ios devmode enable`); the reference farm had go-ios on disk for this
   purpose. go-ios is not installed by this kit and we have not verified that
   step ourselves.
5. Plug the phone into the PC and tap **Trust** when it asks. The provider is
   started with `--use-ios-pair-cache`, which keeps the pairing so that the
   question is not asked again after a reconnect.

## 2. A signed WebDriverAgent

GADS only works with its author's fork of WebDriverAgent
(<https://github.com/shamanec/WebDriverAgent>); the mainstream one uses
different coordinates.

You need one signed `.ipa` file. Three ways to get it:

**A. Sign the pre-built file in the hub page (no Mac needed).**
This is the route we expect most farms to use. GADS 6.0.0 has signing built
in (it runs the open-source tool zsign on the hub).

1. In your Apple Developer account (developer.apple.com → Certificates,
   Identifiers & Profiles):
   * register every iPhone (Devices → +, name and UDID);
   * create an App ID for WDA, or a wildcard App ID such as
     `com.yourname.*`;
   * create an *Apple Development* certificate. Apple asks for a certificate
     signing request (CSR): the hub page can generate one (Admin → Files), or
     use any other tool; keep the private key that belongs to it;
   * create an *iOS App Development* provisioning profile for that App ID,
     that certificate and all your phones, and download it
     (`.mobileprovision`).
2. Download the pre-built `WebDriverAgent.ipa` that the GADS author offers in
   his fork, <https://github.com/shamanec/WebDriverAgent> (the GADS
   documentation points there; look at that repository's releases and
   README).
3. In the hub page: Admin → Files → WebDriverAgent → *sign and upload*: give
   it the `.ipa`, the `.mobileprovision`, and either a `.p12` with its
   password or the certificate plus private key.

**B. Sign it yourself, then upload.** Any tool that re-signs an `.ipa` works
(GADS names zsign, fastlane sigh, codesign). Then Admin → Files → upload the
signed WebDriverAgent.

**C. Build it in Xcode on a Mac.** Follow "Build WebDriverAgent IPA file
manually using Xcode" in the GADS provider documentation, then upload the
result under Admin → Files.

Notes that save hours:

* **The bundle ID.** Write down the bundle identifier WDA was signed with, for
  example `com.yourname.WebDriverAgentRunner`. GADS adds `.xctrunner` to it by
  itself when it starts the app, so your provisioning profile must cover
  `com.yourname.WebDriverAgentRunner.xctrunner` too. A wildcard App ID
  (`com.yourname.*`) does.
* **A new phone later** means: register its UDID at Apple, download the
  profile again, sign and upload again.
* **Expiry.** When the signature runs out, every phone stops responding on the
  same day. Put the date in a calendar.
* This kit does not contain WebDriverAgent or any Apple file, and cannot sign
  for you: the signature has to be yours.

## 3. Switch iOS on for the provider

`install.ps1` created the provider with iOS switched **off**, because a GADS
provider that has iOS on but no WebDriverAgent refuses to start
("Could not provide WebDriverAgent.ipa file from MongoDB").

Now that a signed WDA is uploaded, in the hub page: Admin → Providers →
your provider (`Provider1`):

* turn **Provide iOS** on;
* choose the uploaded **WebDriverAgent** build;
* enter the **WDA bundle ID** (without `.xctrunner`);
* leave the host address `127.0.0.1` and the port `10001` as they are;
* leave **Set up Appium servers** off (Blossom does not use Appium; with it
  off, GADS needs neither Appium nor Java on the PC, and phones are offered
  for remote control only);
* save.

Then restart the provider: in Blossom, Phone Farm → Services → *Restart
Provider*; or on the PC `Restart-Service GadsProvider`.

Check `C:\farm\Provider1\provider.log`: it should not end in an error.

## 4. Register each phone in the hub

Admin → Devices → add a device:

* **UDID**: the phone's identifier. In iTunes or the Apple Devices app, click
  the serial number on the phone's summary page until it shows the UDID
  (25 characters with a hyphen on recent iPhones, 40 on older ones).
* **Name**: anything; Blossom shows it until you rename the phone there.
* **OS**: iOS, and the iOS version.
* **Provider**: your provider.
* **Screen width and height**: fill them in. Blossom places taps with them;
  an empty or wrong size makes taps land in the wrong place. The form's
  tooltips say which numbers GADS expects.
* **Stream type**: see the next section.

GADS asks for a provider restart after a device is added or changed.

The phone should now show in the hub page, and you should be able to open and
control it there. **If it does not work in the hub page, it will not work in
Blossom**: fix it here first. The GADS FAQ
(<https://github.com/shamanec/GADS/blob/v6.0.0/docs/faq.md>) covers the usual
WDA install loops.

## 5. Live video: what we know and what we do not

Blossom's Control page opens the provider's `ios-webrtc` address for a phone.
In the GADS 6.0.0 source, that address takes the screen stream of
WebDriverAgent and encodes it to H.264 with **FFmpeg** on the PC (this is why
the installer installs FFmpeg and puts it on the provider's path).

GADS also has a second iPhone video method, the **Broadcast Extension**
(`gads-broadcast.ipa`, started from Control Center on the phone). Blossom's
in-app guide describes it as required. From the source, the address Blossom
opens does not use it. We could not check on hardware which statement holds
for your phones, so:

1. start **without** the Broadcast Extension and open a phone in Blossom's
   Control page;
2. if there is no picture although the phone is Online, follow the Broadcast
   Extension steps of Blossom's in-app guide (Setup guide 4) and tell us which
   one worked, so this page can be made definite.

## 6. Optional: supervised phones

A supervised phone can be paired without the Trust question. It needs a Mac
with Apple Configurator, and **supervising a phone erases it**. GADS describes
the steps (supervise every phone with the same identity, export the identity
as `.p12`, upload it under Admin → Files, enter its password in the provider's
settings). Blossom does not need supervision.

## 7. Then, in Blossom

Phones appear on the Phone Farm page under their GADS name. On **Devices**
give each one its name, market, accounts and people.

## Checklist for phone number two and onwards

- [ ] iOS not 17.0–17.3, passcode off, Auto-Lock Never, Developer Mode on
- [ ] UDID registered at Apple and included in the provisioning profile (re-sign and re-upload WDA if you had to add it)
- [ ] plugged into a powered hub, Trust tapped
- [ ] added under Admin → Devices with screen size, assigned to the provider
- [ ] provider restarted, phone controllable in the hub page
- [ ] Online in Blossom, picture in Control
