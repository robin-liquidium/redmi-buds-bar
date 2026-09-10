# MediaRemote Adapter

Unmodified source from https://github.com/ungive/mediaremote-adapter,
commit `73f14ab1568371e6e3c44063f21c34c5e2712c4d` (BSD-3-Clause).

The app packages the framework and Perl loader to read system Now Playing
notifications and send playback commands on macOS 14 and later. It does not
link the framework into the app. `script/build_media_bridge.sh` builds the
adapter sources; the upstream test-client executable is not shipped or run.

This uses Apple's private MediaRemote framework through the system Perl
interpreter. Future macOS updates may break this integration. All media data
stays local; the helper runs only while the app's controls are visible.
