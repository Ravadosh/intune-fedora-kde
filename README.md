Microsoft does not support Fedora, yet I'm at it, I want KDE Plasma to be functional in the intune enrollments.

Microsoft recently released repos for RHEL10, which finally go for the updated webgtk 6.0 instead of legacy, making the process easier.


A lot of time has been spent trying to get it to work from a clean KDE install, to no avail, everytime the limitation being kdwallet which is pretty much brandished into Fedora KDE Plasma,
The new process is to install Fedora Workstation (gnome) & enforce gnome-keyring to be the uncontested owner of secrets before even installing kde workspaces

The script currently available is proven to be working for initial install of intune, edge and dependencies, testing of the rest of the process is the current situation.

Current procedure

1.Fresh Fedora Workstation (GNOME) install
2.enforce-gnome-keyring.sh — lock in the baseline before anything else touches the secret service. Order relative to step 3 doesn't technically matter (neither script depends on the other's packages), but doing it first means if something looks wrong later, you know it's not this script fighting for the same territory as the Intune/Edge install.
3.Intune/Edge script
4.Sanity check: busctl --user list | grep -i secrets — confirm gnome-keyring, nothing's regressed yet
5.Actual sign-in + enrollment test, still on pure GNOME (once your admin clears it) — this is the step that matters most and is easy to skip past in the rush to get to KDE. You want a confirmed-working enrollment on GNOME as your known-good baseline, not just "the app launched."
6.Only then, dnf environment install kde-desktop-environment
7.Reboot into KDE specifically, recheck busctl — confirm gnome-keyring still owns the name post-KDE-install
8.Relaunch intune-portal in the KDE session and confirm the already-enrolled state holds — no re-prompt, no [4kv4v], no broken token
