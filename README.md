# Monitorswitch

A small Bash script that flips all your monitors to their other video input
in one command — e.g. switch every monitor from DisplayPort to HDMI (or back)
when you dock/undock a laptop, swap between two PCs, or reconnect a KVM.

It uses [`ddcutil`](https://www.ddcutil.com/) (DDC/CI over I2C) to control
monitors directly, so it works independent of your desktop environment or
window manager.

## Features

- **Auto-detects everything.** No hardcoded input codes — each monitor's
  actual supported inputs are read from `ddcutil capabilities` at runtime,
  since different models report different VCP values for the same port.
- **Works with DisplayPort, HDMI, DVI, and VGA**, in any combination. A
  monitor currently on DVI-1 with only VGA-1 as its other input will switch
  to VGA, no configuration needed.
- **Switches all monitors together.** Detection runs first for every
  monitor, then all switches are fired off in parallel at the end, so every
  screen flips over at roughly the same moment instead of one by one.
- **Safe by default on ambiguous monitors.** A monitor whose current input
  isn't recognized, or that doesn't advertise another recognized input, is
  left untouched with a warning instead of guessing.

## Requirements

- Linux with I2C access to your monitors (typical on desktop GPUs with
  DDC/CI-capable displays).
- [`ddcutil`](https://www.ddcutil.com/) installed and able to see your
  monitors (`ddcutil detect` should list them).
  - You may need the `i2c-dev` kernel module loaded and your user in the
    `i2c` group — see the [ddcutil installation
    guide](https://www.ddcutil.com/install/) for distro-specific steps.
- Bash 4+.

## Installation

Clone the repo and make the script executable:

```sh
git clone https://github.com/<your-username>/Monitorswitch.git
cd Monitorswitch
chmod +x monitor-switch.sh
```

Optionally symlink it onto your `$PATH`:

```sh
ln -s "$(pwd)/monitor-switch.sh" ~/.local/bin/monitor-switch
```

## Usage

```sh
./monitor-switch.sh
```

Switches every detected monitor to its other input.

```
=== Display 1 ===
  Current input: 0x11 (HDMI) -> will switch to DisplayPort-1 (DisplayPort, 0x0f)
=== Display 2 ===
  Current input: 0x0f (DisplayPort) -> will switch to HDMI-1 (HDMI, 0x11)

=== Switching ===
  Display 1 -> DisplayPort-1 (0x0f)
  Display 2 -> HDMI-1 (0x11)
```

### Options

| Flag | Description |
| --- | --- |
| `-n`, `--dry-run` | Show what would change without actually switching anything. |
| `--display N` | Only operate on ddcutil display number `N`. Repeatable to target several specific displays. Defaults to all detected displays. |
| `-h`, `--help` | Show a short usage summary. |

### Examples

Preview what would happen without changing anything:

```sh
./monitor-switch.sh --dry-run
```

Only switch monitor 2 (find display numbers via `ddcutil detect`):

```sh
./monitor-switch.sh --display 2
```

## How it works

For every monitor `ddcutil detect` reports:

1. Read its supported input sources from `ddcutil --display N capabilities`
   (VCP feature `0x60`).
2. Classify each advertised input by name as DisplayPort, HDMI, DVI, or VGA
   (other input types, e.g. USB-C, are ignored).
3. Read the currently active input via `ddcutil --display N getvcp 60`.
4. Queue a switch to the first other advertised input of a *different*
   recognized type (e.g. DisplayPort &rarr; HDMI, or DVI &rarr; VGA).

Once every monitor has been inspected, all queued `setvcp` calls are run in
parallel and the script waits for them to finish, so the switch happens as
close to simultaneously as possible across all monitors.

If a monitor's current input isn't a recognized type, or it only advertises
one recognized input, it's skipped with a warning rather than switched
blindly.

## Troubleshooting

- **`ddcutil: command not found`** — install `ddcutil` from your distro's
  package manager (`apt install ddcutil`, `pacman -S ddcutil`, etc.).
- **No displays found / permission errors** — make sure the `i2c-dev` kernel
  module is loaded (`sudo modprobe i2c-dev`) and your user can access
  `/dev/i2c-*` (typically via the `i2c` group). See the [ddcutil
  troubleshooting guide](https://www.ddcutil.com/userguide_reference/).
- **A monitor gets skipped with "doesn't advertise another recognized
  input"** — run `ddcutil --display N capabilities` and check what inputs it
  actually reports under `Feature: 60`; some monitors only expose one input
  over DDC/CI even if more are physically connected.

## License

0BSD
