# Background Changer

An Omarchy 4 ("Quattro") shell plugin that changes the desktop background on a
timer, pulling fresh images from an HTTP endpoint you configure and keeping the
last few locally so rotation keeps working with no internet.

- Changes the background immediately when installed, then every `N` minutes.
- Endpoint returns JSON like `{"url": "https://.../image.jpg"}`.
- Downloaded images are cached; if the endpoint or the network fails, the
  plugin rotates the cache instead of leaving the wallpaper stuck.
- Retries with exponential backoff on failed requests.
- With no endpoint configured and nothing cached yet, it draws the setup
  instructions onto the background itself instead of doing nothing visible.
- No user action required after install. Configuration is optional.

## Install

```sh
omarchy plugin add https://github.com/WinCisky/omarchy-bkg-changer.git --enable --yes
```

From a local checkout (`omarchy plugin add` clones, and a filesystem path is a
valid git URL):

```sh
git init && git add -A && git commit -m "init"
omarchy plugin add "$PWD" --enable --yes
```

Or fully manually:

```sh
cp -r . ~/.config/omarchy/plugins/ssimo.bkg-changer
omarchy-shell shell rescanPlugins
omarchy plugin enable ssimo.bkg-changer
```

The background changes within a second or two of enabling. Then set your
endpoint and pull the first image without waiting for the next tick:

```sh
$EDITOR ~/.config/omarchy-bkg-changer/config.env
omarchy-shell bkgchanger next
```

## Configuration

`~/.config/omarchy-bkg-changer/config.env`, created with defaults on first run.

| Key | Default | Meaning |
| --- | --- | --- |
| `BG_ENDPOINT` | `""` | JSON endpoint. Empty = rotate the local cache only. |
| `BG_INTERVAL_MINUTES` | `60` | How often to change the background. |
| `BG_KEEP_IMAGES` | `10` | How many downloaded images to keep. |
| `BG_TIMEOUT_SECONDS` | `20` | Per-request network timeout. |
| `BG_MAX_RETRIES` | `4` | Attempts per network call before falling back. |
| `BG_RETRY_BASE_SECONDS` | `2` | Backoff base: waits 2s, 4s, 8s ... between attempts. |

`BG_INTERVAL_MINUTES` is applied live: the config is re-read within 30 seconds
of being saved and the schedule re-arms itself. The other keys are read by the
worker on its next run.

## Commands

```sh
omarchy-shell bkgchanger next      # fetch a fresh image now, restart the clock
omarchy-shell bkgchanger rotate    # next cached image, no network
omarchy-shell bkgchanger status    # scheduler state as JSON

omarchy-toggle bkg-changer-off     # pause rotation without disabling the plugin
```

The worker is also runnable directly, which is the fastest way to see what is
going wrong:

```sh
~/.config/omarchy/plugins/ssimo.bkg-changer/bin/bkg-changer run
~/.config/omarchy/plugins/ssimo.bkg-changer/bin/bkg-changer status
```

## How it works

- `Service.qml` is a `kind: "service"` plugin — a headless singleton loaded by
  `omarchy-shell` at startup and destroyed when the plugin is disabled. It owns
  a `Timer` with `triggeredOnStart: true` (hence the immediate first change)
  and a second, single-shot timer that backs off after a failed run: 1, 2, 4,
  8 ... minutes, capped at the normal interval.
- `bin/bkg-changer` does all the work: fetches the JSON, extracts `.url`,
  downloads the image, verifies the downloaded bytes really are an image (an
  HTML error page served with a `200` never becomes your wallpaper), stores it
  under a content hash, applies it, and prunes the pool.
- Applying goes through `omarchy-theme-bg-set`, so the symlink Omarchy uses
  stays authoritative and the change is instant.
- Runs are serialised with `flock`, so a timer tick and a manual
  `omarchy-shell bkgchanger next` cannot race.

## Files

| Path | Purpose |
| --- | --- |
| `~/.config/omarchy-bkg-changer/config.env` | your settings |
| `~/.local/share/omarchy-bkg-changer/images/` | the downloaded image pool |
| `~/.local/state/omarchy-bkg-changer/setup-required.png` | generated "configure me" background |
| `~/.local/state/omarchy-bkg-changer/bkg-changer.log` | one line per run, self-truncating |
| `~/.local/state/omarchy/current/background` | Omarchy's symlink to the active image |

## Troubleshooting

Check the log first: `tail ~/.local/state/omarchy-bkg-changer/bkg-changer.log`.

- **Nothing happens on install** — `omarchy plugin list` should show
  `ssimo.bkg-changer` enabled. If not: `omarchy plugin enable ssimo.bkg-changer`.
- **`endpoint response has no usable .url field`** — the endpoint must return a
  top-level `url` key. Verify with
  `curl -s "$BG_ENDPOINT" | jq .`.
- **`downloaded content is not a supported image`** — the URL served something
  that is not JPEG/PNG/WebP/GIF/BMP, usually an error page or a redirect to a
  login form.
- **Background never changes offline** — the pool is still empty. It fills up
  one image per successful run.
- **A black background telling you to configure an endpoint** — exactly what it
  says: `BG_ENDPOINT` is empty and nothing has been downloaded yet. Set the
  endpoint, then `omarchy-shell bkgchanger next`. It is rendered at your largest
  monitor's resolution with ImageMagick, in the system's `sans-serif` font as
  resolved by `fc-match`. Without `magick` the plugin just logs and leaves the
  background alone.

## Uninstall

```sh
omarchy plugin remove ssimo.bkg-changer
```

The image pool, config and log are left in place on purpose. Remove them with:

```sh
rm -rf ~/.config/omarchy-bkg-changer \
       ~/.local/share/omarchy-bkg-changer \
       ~/.local/state/omarchy-bkg-changer
```

Note that if the wallpaper in use came from the pool, delete it only after
picking another background (`omarchy theme bg next`).
