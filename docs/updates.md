# Automatic updates

Settings → Updates controls updates for MacVR, WineXR and SiliconXR. Automatic
Updates defaults to On. The app checks stable releases 30 seconds after startup
and every 15 minutes while no game is open; Check for updates runs a check immediately. With automatic
updates off, checking only reports availability; Install available updates is an
explicit action.

Release sources are the `shlingusjambo-glitch/MacVR`, `WineXR`, and `SiliconXR`
GitHub repositories. Drafts and prereleases are excluded. Every downloaded asset
must have a GitHub SHA-256 digest and pass verification. MacVR also validates the
archive paths, bundle identifier/version and code signature before staging it.

Runtime downloads are committed as a complete component in Application Support /
VR4Mac / Updates / Installed. Wine setup and SiliconXR installation resolve these
files before bundled resources, except when the app bundles a newer runtime.
The build records bundled runtime versions in Info.plist. SiliconXR updates also
refresh the OpenVR native libraries inside the bundled Vivecraft adapter jar.
Existing game processes retain their loaded runtime; updates are used on the next
launch/registration.

MacVR is staged as Pending-MacVR.app. A helper waits for the running app to exit,
backs up its bundle, copies the verified replacement, relaunches MacVR and restores the backup if
copying fails. After installing an update, MacVR automatically exits and relaunches while idle. A game launching during a download defers the restart until it closes. An unwritable installation
folder or a missing digest is reported in the Updates section.

Validation: app build, dashboard category/update-control interaction tests,
version ordering tests, offline category/pointer renders, and a read-only live
release check. No newer release was available during validation, so automatic
replacement of the installed application was not exercised.
