# Arduino UNO Q: MAX98357A I2S installer

**WARNING:** This operation could potentially break the bootloader. 

If that happens, use a USB-C connection and the Arduino Flash CLI to restore the device.

**Make sure to back up your data before proceeding!**

`install-i2s-max98357a.sh` installs a custom device tree for the MAX98357A I2S amplifier and makes it the default boot configuration on Arduino UNO Q.

Use it to restore the configuration after an Arduino system update. The script rebuilds the custom DTB from the stock DTB on the board and copies the kernel, initrd, and boot parameters from the latest stock boot entry. It does not depend on the kernel version used during the original installation.

The overlay and the Python code needed to process the DTB are embedded in the script. No separate overlay or prebuilt DTB is required.

## Requirements

- Arduino UNO Q with the existing Debian and systemd-boot layout.
- The EFI System Partition mounted at `/boot/efi`.
- The stock DTB at `/boot/efi/dtb/qcom/qrb2210-arduino-imola.dtb`.
- A stock boot entry named `<machine-id>-*.conf` in `/boot/efi/loader/entries`.
- `device-tree-compiler` and `python3`.
- Root access for installation.

Install the required tools if they are missing:

```sh
sudo apt-get update
sudo apt-get install device-tree-compiler python3
```

## Usage

On the board, change to the directory containing the script:

```sh
cd /path/to/arduino_uno_q/i2s
```

First, check that the DTB and boot configuration can be generated:

```sh
sh install-i2s-max98357a.sh --check
```

This builds and validates the files in a temporary directory, then removes them. It does not modify the installed DTB or boot configuration and does not require root access.

Apply the configuration:

```sh
sudo sh install-i2s-max98357a.sh
```

Reboot when ready:

```sh
sudo systemctl reboot
```

After a system update, run the same check and installation commands again before rebooting into the custom configuration.

## What the script does

1. Selects the latest stock boot entry using version sorting of filenames matching the current machine ID. It checks that the referenced kernel and initrd files exist.
2. Compiles an embedded device-tree overlay and applies it to the stock DTB.
3. Adds a `maxim,max98357a` codec and a playback link named `Skull I2S Playback`, connecting `PRIMARY_MI2S_RX` to the codec through `q6routing`. The AFE DAI uses ID 16 and SD line 0.
4. Configures LPASS GPIO6 for I2S1 clock, GPIO7 for word select, and GPIO8 for data. It also assigns TLMM GPIO98–100 to `egpio` and retains the existing I2S2 pin state.
5. Moves `skull-i2s-dai-link` to the end of the sound node's children, leaving `mm1-dai-link` through `mm4-dai-link` first. It verifies that this reordering changes no DTB properties.
6. Generates a separate boot entry using the selected stock entry's kernel, initrd, and boot parameters.
7. Backs up the existing files, installs the generated DTB and boot entry, and selects the new entry in `loader.conf`.

The DAI-link order matters on the tested system. Placing the new backend before the MultiMedia frontend links caused `q6routing` to initialize before the required MultiMedia widgets existed. ASoC then reported failed routes and `failed to instantiate card -19`. Keeping the frontend links first resolved that registration failure.

## Installed files

| File | Purpose |
| --- | --- |
| `/boot/efi/dtb/qcom/qrb2210-arduino-imola-skull-ordered.dtb` | Generated DTB with the MAX98357A link and corrected node order |
| `/boot/efi/loader/entries/servo-skull-i2s-ordered.conf` | Boot entry referencing the generated DTB |
| `/boot/efi/loader/loader.conf` | Updated to select `servo-skull-i2s-ordered.conf` by default |

The stock DTB and stock boot entry are preserved. Repeated installations rebuild the custom files from the stock inputs and create a new backup directory each time.

## Verification after reboot

```sh
bootctl status --no-pager
aplay -l
readlink -f /sys/bus/platform/devices/sound/driver
readlink -f /sys/bus/platform/devices/max98357a/driver
```

The current boot entry should be `servo-skull-i2s-ordered.conf`. On the tested board, ALSA registered `Arduino-Imola-HPH-LOUT` with four MultiMedia playback devices. The sound and amplifier devices were bound to `snd-sm8250` and `max98357a`, respectively.

Check registration errors with:

```sh
journalctl -k -b --no-pager | grep -E 'failed to instantiate card|Failed to add route'
```

No matching lines are expected after successful registration. A registered sound card confirms software initialization; physical amplifier output still needs a separate playback test.

## Backups and rollback

Each installation prints its backup directory:

```text
/boot/efi/loader/servo-skull-backup-YYYYMMDD-HHMMSS-XXXXXX
```

It contains `loader.conf`, `base.dtb`, and `base-entry.conf`, plus the previous `ordered.dtb` and `ordered.conf` if they existed.

To return to stock boot, find the stock entry using:

```sh
bootctl list --no-pager
```

Edit `/boot/efi/loader/loader.conf` and set `default` to that stock entry's filename, then reboot. Restoring a backup of `loader.conf` does not necessarily select stock boot: the saved configuration may already have selected the custom entry.

## Optional input overrides

To use a specific stock boot entry or another compatible stock DTB, pass explicit paths:

```sh
sudo env \
  BASE_ENTRY=/boot/efi/loader/entries/YOUR-STOCK-ENTRY.conf \
  BASE_DTB=/boot/efi/dtb/qcom/YOUR-STOCK-DTB.dtb \
  sh install-i2s-max98357a.sh --check
```

Remove `--check` to install using those inputs. Use a stock DTB as the base, rather than an already patched Skull DTB.

## Scope

The script installs the device tree and boot configuration. It does not reboot automatically, enable the ALSA mixer route to the amplifier, configure application audio output, or restart ADSP. Those settings and runtime operations are separate from this installer.
