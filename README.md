# Intune Portal on Fedora KDE Plasma — Enrollment Runbook

## ⚠️ Platform status

Microsoft's officially supported platforms for the Intune Linux app are **Ubuntu Desktop 24.04/26.04 LTS** and **RHEL 8/9**, and Microsoft's own enrollment docs specify a **GNOME** graphical session. Fedora is not on the support matrix, and KDE Plasma is not the assumed desktop environment. Everything below is a community reconstruction of what the RHEL9 package + GNOME session normally provides for you automatically. Treat this as unsupported, test-in-VM-first territory — which is exactly what this doc is for.

Root cause in one sentence: `intune-portal`'s RHEL9 RPM is built against a WebKitGTK 4.0 / GNOME stack that Fedora 44 no longer ships, so both **installation** and **runtime** need shims, and the **secret storage** it expects (GNOME's Secret Service) isn't provided by KWallet.

---

## Architecture

```
┌─────────────────────────────────┐
│          intune-portal          │
└────────────────┬────────────────┘
                 │
   Loads via LD_LIBRARY_PATH
                 ▼
┌────────────────────────────────────────────────────────┐
│             /opt/intune-legacy-libs/                    │
│  (Isolated ICU 73 binaries for javascriptcoregtk4.0)     │
└────────────────────────────┬────────────────────────────┘
                 │
   Falls back to system paths
                 ▼
     ┌──────────────────────────────────────┐
     │              /usr/lib64/             │
     │  - libsoup (v2 compat, native)       │
     │  - libjxl.so.0.8 -> libjxl.so.0.11    │
     │  - libavif.so.15 -> libavif.so.16     │
     │  - webkit2gtk4.0 (force-installed)    │
     │  - woff2, libmanette (native)         │
     └──────────────────────────────────────┘
```

---

## Step 0 — Repo setup

Microsoft's repo directory URLs are directory listings, not the `.repo` file itself — you need the `config.repo` path one level deeper, or `dnf` will download an HTML page and choke with "Missing section header":

```bash
sudo rpm --import https://packages.microsoft.com/keys/microsoft.asc
sudo dnf config-manager addrepo --from-repofile=https://packages.microsoft.com/yumrepos/microsoft-rhel9.0-prod/config.repo
```

Note: this repo ships with `gpgcheck=0`, so the `rpm --import` step above doesn't actually gate anything here — harmless to run, just not load-bearing.

## Step 1 — Legacy WebKit RPMs (required before intune-portal can even install)

`dnf install intune-portal` will fail outright with `nothing provides libwebkit2gtk-4.0.so.37()(64bit)` across every version in the repo — Fedora dropped the legacy WebKitGTK 4.0 branch, so this isn't optional pre-work, it's a hard install blocker.

```bash
mkdir -p ~/Downloads/intuneinstaller && cd ~/Downloads/intuneinstaller
curl -O https://archives.fedoraproject.org/pub/archive/fedora/linux/updates/39/Everything/x86_64/Packages/w/webkit2gtk4.0-2.46.3-1.fc39.x86_64.rpm
curl -O https://archives.fedoraproject.org/pub/archive/fedora/linux/updates/39/Everything/x86_64/Packages/j/javascriptcoregtk4.0-2.46.3-1.fc39.x86_64.rpm

# --nodeps: we only need the RPM DB to register the Provides:, not a working install yet.
# A normal dnf install here would try to downgrade system libicu/libavif to satisfy these.
sudo rpm -ivh --nodeps ./webkit2gtk4.0-2.46.3-1.fc39.x86_64.rpm ./javascriptcoregtk4.0-2.46.3-1.fc39.x86_64.rpm
```

## Step 2 — Install intune-portal

```bash
sudo dnf install intune-portal
```

Pulls `gnome-keyring`, `gcr3`, `libsoup` (2.x compat), and `microsoft-identity-broker` as dependencies. The identity-broker `%post` script also creates and selects an `authselect` profile (`custom/intune-profile`) and warns that **SSSD should be configured and enabled** — check this even if you don't use SSSD for anything else yet:

```bash
sudo dnf install -y sssd-common
sudo systemctl enable --now sssd
```

## Step 3 — Font/decoder libraries

```bash
sudo dnf install -y woff2 libmanette
```

These are still normally packaged on Fedora 44 — no archive shimming needed for these two, unlike webkit/ICU below.

## Step 4 — Isolated ICU 73 binaries (symbol lookup fix)

WebKit's JS engine needs exact ICU 73 internal symbols (e.g. `ureldatefmt_formatNumeric_73`) that don't exist in Fedora 44's ICU 77+. Extract in isolation rather than exposing globally:

```bash
mkdir -p ~/Downloads/intune-icu-fix && cd ~/Downloads/intune-icu-fix
curl -O https://archives.fedoraproject.org/pub/archive/fedora/linux/releases/39/Everything/x86_64/os/Packages/l/libicu-73.2-2.fc39.x86_64.rpm
rpm2cpio libicu-73.2-2.fc39.x86_64.rpm | cpio -idmv

sudo mkdir -p /opt/intune-legacy-libs
sudo cp usr/lib64/libicui18n.so.73* /opt/intune-legacy-libs/
sudo cp usr/lib64/libicuuc.so.73* /opt/intune-legacy-libs/
sudo cp usr/lib64/libicudata.so.73* /opt/intune-legacy-libs/
```

## Step 5 — Image codec symlinks

**Before running this step, verify the actual installed versions on the VM** — don't assume the numbers below still match a future Fedora release:

```bash
ls -la /usr/lib64/libjxl.so* /usr/lib64/libavif.so*
```

On Fedora 44 (as tested), the versions are `libjxl.so.0.11.2` and `libavif.so.16.3.0`:

```bash
sudo ln -s /usr/lib64/libjxl.so.0.11.2 /usr/lib64/libjxl.so.0.8
sudo ln -s /usr/lib64/libavif.so.16.3.0 /usr/lib64/libavif.so.15
```

⚠️ This is the most fragile step in the whole chain — it assumes ABI compatibility across a version jump that isn't guaranteed. If you see intermittent WebKit crashes (not a clean symbol-lookup error, but a segfault), suspect this symlink first.

## Step 6 — Launch: console session required, not SSH

Package/file steps above are fine over SSH. **From here on, work at the actual VM console.** `intune-portal` needs a real display, and the gnome-keyring/Secret Service check below depends on the graphical session's D-Bus bus (SSH sessions typically don't have `DBUS_SESSION_BUS_ADDRESS` pointed at the right bus).

First attempt will likely hit missing shared libraries one at a time — instead of chasing them individually, dump the full list at once:

```bash
ldd /usr/lib64/libwebkit2gtk-4.0.so.37 2>&1 | grep "not found"
ldd /usr/lib64/libjavascriptcoregtk-4.0.so.18 2>&1 | grep "not found"
```

For anything reported missing, check if Fedora still packages it normally before assuming it needs archive treatment:

```bash
dnf provides '*/libwhatever.so.N'
```

(`libmanette-0.2.so.0` was the one extra dependency found in testing beyond the original webkit/ICU/jxl/avif set — it's still normally packaged, just `dnf install libmanette`.)

## Step 7 — Rendering fix (VM without GPU passthrough)

Without accelerated 3D (no virtio-gpu passthrough), WebKit's DMA-BUF renderer path fails and retries every frame (`Failed to get GBM device` spam, blank/frozen login window). Force it off:

```bash
WEBKIT_DISABLE_DMABUF_RENDERER=1 LD_LIBRARY_PATH=/opt/intune-legacy-libs /opt/microsoft/intune/bin/intune-portal
```

Confirmed working on the test VM. If it's still stuck, stack the belt-and-suspenders variant:

```bash
WEBKIT_DISABLE_DMABUF_RENDERER=1 LIBGL_ALWAYS_SOFTWARE=1 WEBKIT_DISABLE_COMPOSITING_MODE=1 LD_LIBRARY_PATH=/opt/intune-legacy-libs /opt/microsoft/intune/bin/intune-portal
```

## Step 8 — Secret Service / gnome-keyring (⚠️ UNCONFIRMED — pick up here on next run)

Intune Portal needs the freedesktop Secret Service (`org.freedesktop.secrets`) to persist the auth token and enrollment certificate. KWallet does not implement this; gnome-keyring does. This is the root cause of the `[4kv4v]` sign-in error and the later "Couldn't enroll your device / creating item in secret collection" error.

`gnome-keyring` was pulled in automatically as a dependency in Step 2, which *may* be sufficient on its own — this was not confirmed before the test VM was reset (sign-in flow was reached and in progress, but not completed).

**On the next run, check this before or right after reaching the sign-in screen:**

```bash
busctl --user list | grep -i secrets
```

- **Shows `org.freedesktop.secrets`** → proceed straight to sign-in, no further action needed.
- **Shows nothing** → apply the portal preference override, then log all the way out/in (new session required, not just app relaunch) before retrying:

```bash
sudo dnf install -y xdg-desktop-portal-gtk
sudo install -d -m 0755 /etc/xdg/xdg-desktop-portal
sudo tee /etc/xdg/xdg-desktop-portal/kde-portals.conf >/dev/null <<'EOF'
[preferred]
default=kde
org.freedesktop.impl.portal.Secret=gnome-keyring
EOF
```

Then recheck `busctl --user list | grep -i secrets`, and complete sign-in + watch specifically for what happens immediately after auth succeeds — that's where this failure mode shows up if it's still present.

## Step 9 — Persistence for end users (final packaging)

Once Steps 1–8 are fully confirmed on a clean run:

**Shell alias** (`~/.bashrc` / `~/.zshrc`):
```bash
alias intune='WEBKIT_DISABLE_DMABUF_RENDERER=1 LD_LIBRARY_PATH=/opt/intune-legacy-libs intune-portal'
```

**Desktop launcher** (`~/.local/share/applications/intune-portal.desktop` or system-wide):
```
Exec=env WEBKIT_DISABLE_DMABUF_RENDERER=1 LD_LIBRARY_PATH=/opt/intune-legacy-libs intune-portal
```

---

## Notes for future testing / future Fedora versions

- **Symbol errors** (`symbol lookup error`): don't just symlink — repeat the Step 4 extract-to-`/opt` method for the specific library.
- **Library major version bumps**: if `libjxl` moves past `0.11` or `libavif` past `16` in a future Fedora update, re-run `ls -la /usr/lib64/lib...` and update the Step 5 symlink targets accordingly.
- **Unmanaged packages**: the force-installed `webkit2gtk4.0`/`javascriptcoregtk4.0` RPMs (`--nodeps`) are not tracked by `dnf`'s normal dependency graph — don't run a blind `dnf upgrade` expecting these to move; they need manual re-verification against new intune-portal releases.
- **Step 8 is the open item** — confirm it on the next clean VM run before this is considered a finished package.
