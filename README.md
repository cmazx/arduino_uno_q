# Arduino Uno Q

This repository contains the Arduino Uno Q setup and the I2S audio configuration used to enable a MAX98357A amplifier on the device.

## Included files

- `i2s/install-i2s-max98357a.sh` — installs the custom device-tree overlay and boot entry for the MAX98357A I2S amplifier.
- `i2s/Readme.md` — installation notes, requirements, verification steps, and rollback guidance.

## Project structure

```text
arduino_uno_q/
├── README.md
└── i2s/
    ├── Readme.md
    └── install-i2s-max98357a.sh
```

Use the I2S installer from the `i2s` directory when preparing the board for audio output.
