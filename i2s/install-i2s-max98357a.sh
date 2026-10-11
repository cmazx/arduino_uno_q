#!/bin/sh
set -eu

check_only=0
case "${1:-}" in
    '') ;;
    --check) check_only=1 ;;
    *) printf 'Usage: sudo sh %s [--check]\n' "$0" >&2; exit 1 ;;
esac
[ "$#" -le 1 ] || exit 1
[ "$check_only" -eq 1 ] || [ "$(id -u)" -eq 0 ] || {
    printf 'Run this installer with sudo.\n' >&2
    exit 1
}

for tool in dtc fdtoverlay fdtget python3; do
    command -v "$tool" >/dev/null 2>&1 || {
        printf 'Missing %s. Install dependencies: sudo apt-get install device-tree-compiler python3\n' "$tool" >&2
        exit 1
    }
done

esp=/boot/efi
base_dtb=${BASE_DTB:-$esp/dtb/qcom/qrb2210-arduino-imola.dtb}
base_entry=${BASE_ENTRY:-}
if [ -z "$base_entry" ]; then
    machine_id=$(cat /etc/machine-id)
    base_entry=$(find "$esp/loader/entries" -maxdepth 1 -type f -name "$machine_id-*.conf" | sort -V | tail -n 1)
fi
[ -f "$base_dtb" ] && [ -f "$base_entry" ] && [ -f "$esp/loader/loader.conf" ] || {
    printf 'Stock DTB or boot configuration is missing. Set BASE_DTB and BASE_ENTRY if necessary.\n' >&2
    exit 1
}

work=$(mktemp -d)
trap 'rm -rf "$work"' EXIT
trap 'exit 130' INT
trap 'exit 143' TERM

cat > "$work/skull-i2s.dts" <<'DTS'
/dts-v1/;
/plugin/;

/ {
    fragment@0 {
        target-path = "/";
        __overlay__ {
            skull_amp: max98357a {
                compatible = "maxim,max98357a";
                #sound-dai-cells = <0>;
                status = "okay";
            };
        };
    };

    fragment@1 {
        target = <&q6afedai>;
        __overlay__ {
            #address-cells = <1>;
            #size-cells = <0>;
            dai@16 {
                reg = <16>;
                qcom,sd-lines = <0>;
            };
        };
    };

    fragment@2 {
        target = <&tlmm>;
        __overlay__ {
            skull_egpio: skull-i2s-egpio-state {
                pins = "gpio98", "gpio99", "gpio100";
                function = "egpio";
                bias-disable;
            };
        };
    };

    fragment@3 {
        target = <&lpass_tlmm>;
        __overlay__ {
            skull_i2s: skull-i2s1-state {
                clk-pins {
                    pins = "gpio6";
                    function = "i2s1_clk";
                    drive-strength = <8>;
                    bias-disable;
                };
                ws-pins {
                    pins = "gpio7";
                    function = "i2s1_ws";
                    drive-strength = <8>;
                    bias-disable;
                };
                data-pins {
                    pins = "gpio8";
                    function = "i2s1_data";
                    drive-strength = <8>;
                    bias-disable;
                };
            };
        };
    };

    fragment@4 {
        target-path = "/sound";
        __overlay__ {
            pinctrl-names = "default";
            pinctrl-0 = <&lpi_i2s2_active &skull_egpio &skull_i2s>;
            skull-i2s-dai-link {
                link-name = "Skull I2S Playback";
                cpu {
                    sound-dai = <&q6afedai 16>;
                };
                codec {
                    sound-dai = <&skull_amp>;
                };
                platform {
                    sound-dai = <&q6routing>;
                };
            };
        };
    };
};
DTS

dtc -q -@ -I dts -O dtb -o "$work/skull-i2s.dtbo" "$work/skull-i2s.dts"
fdtoverlay -i "$base_dtb" -o "$work/merged.dtb" "$work/skull-i2s.dtbo"

python3 - "$work" "$base_entry" "$esp" <<'PY'
import pathlib
import struct
import subprocess
import sys

work, entry, esp = map(pathlib.Path, sys.argv[1:])
blob = (work / 'merged.dtb').read_bytes()
header = struct.unpack_from('>10I', blob)
assert header[0] == 0xd00dfeed
position = header[2]
limit = position + header[9]
stack = []
children = []

while position < limit:
    token_start = position
    token = struct.unpack_from('>I', blob, position)[0]
    position += 4
    if token == 1:
        end = blob.index(b'\0', position)
        name = blob[position:end].decode()
        position = (end + 4) & ~3
        if stack == ['', 'sound']:
            child_start, child_name = token_start, name
        stack.append(name)
    elif token == 2:
        if len(stack) == 3 and stack[:2] == ['', 'sound']:
            children.append((child_name, child_start, position))
        stack.pop()
    elif token == 3:
        size = struct.unpack_from('>I', blob, position)[0]
        position = (position + 8 + size + 3) & ~3
    elif token == 4:
        pass
    elif token == 9:
        break
    else:
        raise ValueError(f'Unexpected FDT token {token}')

assert sum(name == 'skull-i2s-dai-link' for name, _, _ in children) == 1
ordered = [item for item in children if item[0] != 'skull-i2s-dai-link']
ordered += [item for item in children if item[0] == 'skull-i2s-dai-link']
assert [item[0] for item in ordered[:4]] == [f'mm{i}-dai-link' for i in range(1, 5)]
assert all(a[2] == b[1] for a, b in zip(children, children[1:]))
start, end = children[0][1], children[-1][2]
result = blob[:start] + b''.join(blob[a:b] for _, a, b in ordered) + blob[end:]
assert len(result) == len(blob)
candidate = work / 'ordered.dtb'
candidate.write_bytes(result)

def canonical(path):
    return subprocess.run(['dtc', '-q', '-s', '-I', 'dtb', '-O', 'dts', str(path)], check=True, capture_output=True).stdout

assert canonical(work / 'merged.dtb') == canonical(candidate)
installed = esp / 'dtb/qcom/qrb2210-arduino-imola-skull-ordered.dtb'
if installed.is_file() and canonical(installed) == canonical(candidate):
    print('Generated DTB matches the installed DTB, including all properties.')

lines = entry.read_text().splitlines()
fields = [line.split(None, 1) for line in lines if line.strip() and not line.lstrip().startswith('#')]
linux = [value for key, value in fields if key == 'linux']
assert len(linux) == 1, 'Expected one linux entry'
for key, value in fields:
    if key in ('linux', 'initrd'):
        assert (esp / value.lstrip('/')).is_file(), f'Missing boot file: {value}'

lines = [line for line in lines if not line.split() or line.split()[0] not in ('title', 'devicetree')]
lines.insert(0, 'title      Servo-Skull I2S ordered')
lines.append('devicetree /dtb/qcom/qrb2210-arduino-imola-skull-ordered.dtb')
(work / 'entry.conf').write_text('\n'.join(lines) + '\n')
loader = (esp / 'loader/loader.conf').read_text().splitlines()
loader = [line for line in loader if not line.split() or line.split()[0] != 'default']
loader.append('default servo-skull-i2s-ordered.conf')
(work / 'loader.conf').write_text('\n'.join(loader) + '\n')
print('DAI order:', ', '.join(name for name, _, _ in ordered))
PY

printf 'Stock DTB: %s\nBoot entry: %s\n' "$base_dtb" "$base_entry"
if [ "$check_only" -eq 1 ]; then
    printf 'Check passed. No system files changed.\n'
    exit 0
fi

backup=$(mktemp -d "$esp/loader/servo-skull-backup-$(date +%Y%m%d-%H%M%S)-XXXXXX")
cp "$esp/loader/loader.conf" "$backup/loader.conf"
cp "$base_entry" "$backup/base-entry.conf"
cp "$base_dtb" "$backup/base.dtb"
target_dtb=$esp/dtb/qcom/qrb2210-arduino-imola-skull-ordered.dtb
target_entry=$esp/loader/entries/servo-skull-i2s-ordered.conf
[ ! -f "$target_dtb" ] || cp "$target_dtb" "$backup/ordered.dtb"
[ ! -f "$target_entry" ] || cp "$target_entry" "$backup/ordered.conf"
install -m 0644 "$work/ordered.dtb" "$target_dtb.new"
install -m 0644 "$work/entry.conf" "$target_entry.new"
install -m 0644 "$work/loader.conf" "$esp/loader/loader.conf.new"
mv "$target_dtb.new" "$target_dtb"
mv "$target_entry.new" "$target_entry"
mv "$esp/loader/loader.conf.new" "$esp/loader/loader.conf"
sync
printf 'Installed. Backup: %s\nDefault: servo-skull-i2s-ordered.conf\nReboot manually when ready.\n' "$backup"
