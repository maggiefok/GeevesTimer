# Geeves Timer

A tiny floating timer for your Mac. Start, stop, pick the client, done. Each entry lands as a new row in the Time Log tab of your Geeves sheet, with the rate pulled from your Rates tab.

There are two parts: a small script that lives in the Geeves sheet, and the Mac app.

## 1. Add the script to the Geeves sheet (about 5 minutes)

1. Open the **Geeves** sheet, then go to **Extensions › Apps Script**.
2. Click **+** next to Files, choose **Script**, and name it `Timer`.
3. Paste in everything from `AppsScript/Timer.gs`.
4. Near the top, change `TIMER_KEY` to any long phrase you'll remember, like `geeves-oct-sunflower-42`. The Mac app sends this key so nobody else can write to your sheet.
5. Check your other script files for a `function doGet` or `function doPost`. If either one already exists, stop here and let me know, because two of them will clash.
6. Click **Deploy › New deployment**. Click the gear and choose **Web app**, then set:
   - Execute as: **Me**
   - Who has access: **Anyone** (the key is what keeps it private)
7. Click **Deploy** and approve the permissions prompt, then copy the **Web app URL** (it ends in `/exec`).

If you change the script later, go to **Deploy › Manage deployments**, edit the deployment, and pick **New version**. That keeps the same URL.

## 2. Build the Mac app

You need Apple's Command Line Tools. Skip this if you already have Xcode.

```
xcode-select --install
```

Then, from this folder in Terminal:

```
chmod +x make-app.sh
./make-app.sh
```

Drag `build/Geeves.app` into Applications and open it. A "Connect to Geeves" box appears. Paste in the web app URL and your key.

You can also open `Package.swift` in Xcode and press Run.

## Using it

| | |
|---|---|
| Click ▶ | start the timer |
| Click ■ | stop, and the search card opens |
| type + return | save to that client |
| ↑ ↓ or ⌘1–9 | pick from the list |
| tab | add a note first (shift-tab goes back) |
| return on "+ New client" | name the client, pick a work type, then return to create it and log the time |
| esc | discard, with a few seconds to Undo |
| drag the numbers | move the timer anywhere |
| right-click the numbers | refresh clients, rounding, open at login, connect, quit |

**Rounding** is set to the nearest 15 minutes by default, so 1h 24m bills as 1.5. Anything shorter bills as at least one step. You can switch to 6 minutes or exact from the right-click menu.

**Undo** works because saves wait about 6 seconds before they go to the sheet. After that, fix the entry in the Time Log directly.

**Offline?** Entries stay saved on your Mac and sync once the sheet is reachable. A small orange ring next to the timer means something is still waiting.

**New clients** get added to the Clients tab (name, with Active = Yes) and the Rates tab (client and work type). Fill in the rate and the invoice details in the sheet. Until you add a rate, the time uses your Default Hourly Rate from Settings.

Quitting is safe. A running timer, or a stopped one you haven't assigned yet, picks up where you left off.
