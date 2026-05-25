# Android Dumping

The collection workflow is intended for unstable devices that still answer ADB commands long enough to collect data.

## Basic Capture

```bash
./update
./dump log
```

The output goes to `captures/<timestamp>/` by default.

To write to a specific mounted destination:

```bash
./dump log /mnt/android-dumps/s22-reboot-loop
```

## What To Capture

The script collects:

- `bugreport.zip`
- `getprop.txt`
- logcat buffers listed in [config/logcat_buffers.txt](../config/logcat_buffers.txt)
- Dropbox tags listed in [config/dropbox_tags.txt](../config/dropbox_tags.txt)
- dumpsys services listed in [config/dumpsys_services.txt](../config/dumpsys_services.txt)

Edit those config files to add or remove capture targets.

## Reboot Loop Tips

- Start with `adb wait-for-device` behavior. If the phone appears only briefly, run the collection script before unlocking or launching apps.
- Preserve `bugreport.zip`; it often contains recovery logs, last-kernel logs, tombstones, and reset summaries.
- Look for repeated reset causes across several boots, not just the last visible app crash.
- If storage errors appear before filesystem panics, prioritize backup and service over repeated factory resets.
