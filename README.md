Microsoft does not support Fedora, yet I'm at it, I want KDE Plasma to be functional in the intune enrollments.

Microsoft recently released repos for RHEL10, which finally go for the updated webgtk 6.0 instead of legacy, making the process easier.


A lot of time has been spent trying to get it to work from a clean KDE install, to no avail, everytime the limitation being kdwallet which is pretty much brandished into Fedora KDE Plasma,
The new process is to install Fedora Workstation (gnome) & enforce gnome-keyring to be the uncontested owner of secrets before even installing kde workspaces

The script currently available is proven to be working.
