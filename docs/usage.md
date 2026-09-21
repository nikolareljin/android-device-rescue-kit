# Usage Guide

This guide covers the three main workflows:

1. Dump diagnostic information from an Android device.
2. Preserve personal data before reset, reflash, or repair.
3. Build a focused analysis prompt from the dumped data.

Raw captures and backups are private. Keep them in ignored directories such as `captures/` and `backups/`, or write them to another mounted destination.

## Unattended runs

Every prompt has a non-interactive equivalent, so the backup can be scripted:

| Flag | Effect |
|---|---|
| `--non-interactive` | Never prompt. Requires `--select`. |
| `--select a,b,c` | Categories to back up. |
| `--credential-export PATH` | Device path of an exported credential file. Repeatable. |
| `--open-manager PKG` | Open this password manager so its own export can be run. Repeatable. |
| `--list-managers` | Print the managers installed on the attached phone and exit. |
| `--no-encrypt` | Write the recovery profile readable, build no archive. |
| `--keep-plaintext` | Keep the readable copy without asking (the default). |
| `--discard-plaintext` | Keep credentials only inside the verified archive. |

Unattended defaults are the cautious ones: anything needing a person at the
phone is skipped rather than assumed.

## Photos

```bash
./dump photos [destination]
```

Finds every photo and video through MediaStore and a filesystem sweep, copies
them preserving the device's directory layout, and verifies each one against
its size on the phone. Exits non-zero and writes `missing_photos.txt` if any
file could not be copied. Re-running resumes: whole files are skipped,
truncated ones are copied again.

## 1. Dump Device Information

Install host dependencies:

```bash
./update
```

Enable USB debugging on the phone, connect it by USB, then verify the device is visible:

```bash
adb devices
```

Collect a full diagnostic dump:

```bash
./dump log
```

The default output is:

```text
captures/<timestamp>/
```

To write to another already mounted location:

```bash
./dump log /mnt/android-dumps/s22-reboot-loop
```

The dump command also runs local triage. The triage output is:

```text
captures/<timestamp>/analysis_report.txt
```

The capture targets are configurable:

- [config/logcat_buffers.txt](../config/logcat_buffers.txt)
- [config/dropbox_tags.txt](../config/dropbox_tags.txt)
- [config/dumpsys_services.txt](../config/dumpsys_services.txt)

## 2. Preserve Personal Data

Run the backup workflow:

```bash
./dump data
```

The dialog lets you choose (including an opt-in Recovery profile item):

- Project-local backup directory
- Any custom writable destination directory visible to the computer
- Photos and videos
- Downloads and documents
- WhatsApp visible media and shared backup folders
- Snapchat exported/shared media folders
- Screenshots and screen recordings
- Music and notification media
- App inventory and device metadata
- Deprecated `adb backup` attempt, where still supported

To include the opt-in recovery profile (settings, network details, detected-app recovery guidance, and an owner-selected password-manager export):

```bash
./dump data /mnt/android-backups/s22-before-reset --recovery-profile
```

An encrypted profile archive is always created when encryption succeeds; the readable credential TXT copy is retained only after an explicit confirmation.

To pass a destination directly:

```bash
./dump data /mnt/android-backups/s22-before-reset
```

Important limits:

- ADB can usually copy shared storage under `/sdcard`.
- ADB usually cannot copy private app databases from `/data/data/<package>` on an unrooted production phone.
- Use each app's official transfer or export flow for private chats, authenticators, banking apps, and encrypted app data.

Restore shared-storage data after reset or replacement:

```bash
tools/android_restore_dialog.sh /mnt/android-backups/s22-before-reset
```

Install and sign in to apps before expecting their own cloud or transfer restores to complete.

## 3. Build An Analysis Prompt

Generate a model-ready prompt from a capture:

```bash
./prompt captures/<timestamp>
```

The output is:

```text
captures/<timestamp>/analysis_prompt.md
```

To choose the prompt path:

```bash
./prompt captures/<timestamp> /tmp/android-analysis-prompt.md
```

The prompt includes:

- A structured diagnostic task
- A file inventory
- The generated triage report
- Focused excerpts for reset reasons, kernel panics, storage failures, radio failures, battery/thermal failures, and app/system-server crashes
- A privacy reminder

Review the prompt before using a hosted service. It may include device metadata, app names, carrier details, network identifiers, file paths, crash snippets, or other personal data.

### Local Analysis

Example with Ollama:

```bash
ollama run llama3.1 < captures/<timestamp>/analysis_prompt.md
```

For larger captures, use the generated prompt first. If more evidence is needed, provide selected files from the capture directory after redaction.

### Hosted Analysis

Use the generated prompt as the input for a hosted model provider such as OpenAI or Anthropic after reviewing and redacting sensitive content.

Recommended hosted workflow:

1. Generate `analysis_prompt.md`.
2. Read it locally.
3. Remove phone numbers, serials, account identifiers, Wi-Fi identifiers, app-private content, and exact location-adjacent network details.
4. Send only the redacted prompt and the minimum extra excerpts needed.
5. Ask for evidence-based conclusions with file and line references.

Suggested instruction to prepend when using a hosted provider:

```text
Treat this as a forensic Android reliability analysis. Do not infer beyond the provided logs. Separate root cause from secondary symptoms. If evidence is insufficient, list the exact additional dumps or commands needed.
```
