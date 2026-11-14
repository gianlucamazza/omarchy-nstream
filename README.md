# omarchy-nstream

A remote for [nstream](https://github.com/gianlucamazza/nstream) in the
[Omarchy](https://omarchy.org/) bar.

- **On the TV:** play/pause, back/forward 30 s, a seek bar, Cast volume, live subtitle
  timing (±0.5 s) and stop for the cast nstream started.
- **Continue watching:** your nstream history, one click to resume on the TV or in mpv on
  this computer. A finished episode continues with the next one.

The bar icon lights up while a cast is live. Everything else stays in nstream itself; the
**Open nstream** button opens its TUI.

## Requirements

- Omarchy with shell plugin support
- nstream 1.46.0 or newer with desktop protocol v1 (`--json --watch` and
  `--session-id`), on `PATH` or in `~/.local/bin`.
- `catt` for casting (`uv tool install catt`), `mpv` for local playback

## Install

Install nstream, then add this plugin:

```sh
uv tool install 'nstream>=1.46.0'
omarchy plugin add https://github.com/gianlucamazza/omarchy-nstream.git --enable
```

Or on its own, from its published repository:

```sh
omarchy plugin add https://github.com/gianlucamazza/omarchy-nstream.git --enable
```

Toggle the panel from a keybinding with
`omarchy-shell gianlucamazza.nstream toggle`.

## Settings

| Key | Default | Meaning |
| --- | ------- | ------- |
| `historyLimit` | `8` | Continue-watching rows shown (1–30) |

The default target (TV or this computer) follows nstream's `prefer_cast`; the toggle in
the panel overrides it until the shell restarts.

## How it works

`Panel.qml` starts one persistent `helper.py watch` process. The adapter replaces itself
with `nstream --json --watch`, whose versioned JSONL snapshots combine cast presence,
continue-watching and timestamped receiver telemetry. Quickshell reads each complete line;
no shell command interpolation is used. The CLI owns the domain model and protocol;
the plugin does not read nstream config files for its watch state or contact castbridge.

The stream declares its API major version and capabilities before controls are enabled.
It emits a heartbeat every second, reads local presence each tick and refreshes history
every five seconds. Receiver requests require explicit interest: the plugin enables them
while its panel is open and disables them when closed. At most one receiver request is
in flight, with a minimum three-second sampling interval. Losing telemetry preserves the
last reading with a visible stale label; it never means playback ended. Stream loss uses
reconnect delays of 5, 10, 20 and at most 30 seconds. Older protocols show a compatibility
error instead of silently guessing fields.

Control invocations carry the displayed session ID and device address. nstream rejects
stale generations; the panel ignores late command responses after a session replacement.
A successful command acknowledges backend acceptance; the next telemetry sample reports
the receiver's observed state. Receiver and HLS delivery errors remain visible separately.
All text is rendered as plain text and stream URLs/tokens never enter the public protocol.

Playback runs independently from observation. Closing or reloading the widget closes the
watcher's stdin and ends only observation. It never stops the TV, mpv or the detached
HLS server. Local playback runs in a separate process; the helper waits for its final
result while cast controls remain available. A shell reload ends that local observation.

## Development

```sh
python3 -B -m unittest discover -s tests
NSTREAM_CONTRACT_TEST=1 python3 -B -m unittest discover -s tests
omarchy plugin validate .
omarchy-shell gianlucamazza.nstream status  # protocol health; no media URLs or tokens
```

Saving a file under `~/.config/omarchy/plugins/gianlucamazza.nstream/` reloads the widget.
For local development, copy this repository's plugin files there after testing.

## Source

The plugin is developed in this repository. Its data interface is provided by
[nstream](https://github.com/gianlucamazza/nstream) (`--json --history` and lifecycle flags).
Keep both interfaces compatible when changing either project.

## License

MIT
