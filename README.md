# Background Changer

An Omarchy 4 ("Quattro") shell plugin that changes the desktop background on a
timer, pulling fresh images from an HTTP endpoint you configure and keeping the
last few locally so rotation keeps working with no internet.

- Changes the background immediately when installed, then every `N` minutes.
- Endpoint returns JSON like `{"url": "https://.../image.jpg"}`.
- An icon next to the clock opens a panel: what the service is doing, the
  endpoint, and **Keep** / **Not this** for the image on screen.
- Kept images are safe from pruning forever. Discarded ones are deleted, never
  shown again, and replaced on the spot.
- Downloaded images are cached; if the endpoint or the network fails, the
  plugin rotates the cache instead of leaving the wallpaper stuck.
- Retries with exponential backoff on failed requests.
- With no endpoint configured and nothing cached yet, it draws the setup
  instructions onto the background itself instead of doing nothing visible.
- No user action required after install. Configuration is optional.

## Install

```sh
omarchy plugin add https://github.com/WinCisky/omarchy-bkg-changer.git --enable --yes
omarchy bar put ssimo.bkg-changer --after omarchy.clock
```

From a local checkout (`omarchy plugin add` clones, and a filesystem path is a
valid git URL):

```sh
git init && git add -A && git commit -m "init"
omarchy plugin add "$PWD" --enable --yes
omarchy bar put ssimo.bkg-changer --after omarchy.clock
```

Or fully manually:

```sh
cp -r . ~/.config/omarchy/plugins/ssimo.bkg-changer
omarchy-shell shell rescanPlugins
omarchy plugin enable ssimo.bkg-changer --after omarchy.clock
```

The background changes within a second or two of enabling. Click the icon by
the clock, paste your endpoint into the field, and press Enter.

### Upgrading from 1.0.x

1.0 was a headless service, so it is recorded in `plugins[]` in `shell.json`
rather than in the bar layout, and enabling it again is a no-op. Move it across
once:

```sh
omarchy plugin disable ssimo.bkg-changer
omarchy plugin enable ssimo.bkg-changer --after omarchy.clock
```

## The panel

Left-click the icon to open the panel, right-click to fetch a new image, and
middle-click to rotate to the next cached one. Inside:

| Control | What it does |
| --- | --- |
| **Keep** (`f`) | Moves the image on screen into `liked/`, where pruning can never reach it. It stays in the rotation. |
| **Not this** (`d`, or `x`) | Deletes the image, records it so it is never shown again, and fetches a replacement immediately. |
| **Next** (`n`) | Fetches a fresh image now and restarts the clock. |
| **Endpoint** | Writes `BG_ENDPOINT`. Enter saves, Escape reverts. Empty means "only rotate what is already downloaded". |
| **Change every / Keep** | `BG_INTERVAL_MINUTES` and `BG_KEEP_IMAGES`. The interval re-arms without a restart. |
| **Pause rotation** (`p`) | The same flag as `omarchy-toggle bkg-changer-off`. |

The top line says whether the plugin is running, paused or failing, when the
last change happened and what came of it; the bottom line counts what is
cached, kept and blocked. Buttons that cannot apply are greyed out — a
wallpaper the plugin did not download is not one it will offer to rate.

The panel can also be summoned from a keybinding:

```sh
omarchy-shell shell toggle ssimo.bkg-changer
```

## Configuration

`~/.config/omarchy-bkg-changer/config.env`, created with defaults on first run.
The panel edits this file for you; editing it by hand works just as well.

| Key | Default | Meaning |
| --- | --- | --- |
| `BG_ENDPOINT` | `""` | JSON endpoint. Empty = rotate the local cache only. |
| `BG_INTERVAL_MINUTES` | `60` | How often to change the background. |
| `BG_KEEP_IMAGES` | `10` | How many downloaded images to keep. Kept images are not counted. |
| `BG_TIMEOUT_SECONDS` | `20` | Per-request network timeout. |
| `BG_MAX_RETRIES` | `4` | Attempts per network call before falling back. |
| `BG_RETRY_BASE_SECONDS` | `2` | Backoff base: waits 2s, 4s, 8s ... between attempts. |
| `BG_BLOCKED_RETRIES` | `3` | Times to re-ask an endpoint that answers with an image you discarded. |

`BG_INTERVAL_MINUTES` is applied live: the config is re-read within 30 seconds
of being saved and the schedule re-arms itself. The other keys are read by the
worker on its next run.

## Commands

```sh
omarchy-shell bkgchanger next      # fetch a fresh image now, restart the clock
omarchy-shell bkgchanger rotate    # next cached image, no network
omarchy-shell bkgchanger like      # keep the image on screen for good
omarchy-shell bkgchanger dislike   # discard it, and never show it again
omarchy-shell bkgchanger status    # scheduler and worker state as JSON

omarchy-toggle bkg-changer-off     # pause rotation without disabling the plugin
```

The worker is also runnable directly, which is the fastest way to see what is
going wrong:

```sh
P=~/.config/omarchy/plugins/ssimo.bkg-changer/bin/bkg-changer
$P run
$P status
$P like
$P dislike
$P set-config BG_ENDPOINT https://example.com/wallpaper.json
```

## How it works

- The manifest declares two kinds. `Service.qml` is the `service`: a headless
  singleton loaded by `omarchy-shell` at startup that owns the schedule and the
  `bkgchanger` IPC target. `BarPanel.qml` is the `bar-widget`: the icon and its
  popup. A bar widget is built once per monitor, so the widget keeps no state —
  it calls the service, which owns the one worker process, and every copy of
  the panel therefore agrees with every other.
- The service owns a `Timer` with `triggeredOnStart: true` (hence the immediate
  first change) and a second, single-shot timer that backs off after a failed
  run: 1, 2, 4, 8 ... minutes, capped at the normal interval.
- `bin/bkg-changer` does all the work: fetches the JSON, extracts `.url`,
  downloads the image, verifies the downloaded bytes really are an image (an
  HTML error page served with a `200` never becomes your wallpaper), stores it
  under a content hash, applies it, and prunes the pool. It is also the only
  writer of `config.env`, so nothing else has to know how to quote a shell
  variable safely.
- Applying goes through `omarchy-theme-bg-set`, so the symlink Omarchy uses
  stays authoritative and the change is instant.
- Discarding an image records its content hash and source URL in a blocklist.
  Both are checked on the next fetch, so a blocked image is rejected before it
  is downloaded when possible, and thrown away after hashing when not.
- Runs are serialised with `flock`, so a timer tick and a manual
  `omarchy-shell bkgchanger next` cannot race. `status` and `set-config` do not
  take the lock, so the panel stays responsive during a download.

## Files

| Path | Purpose |
| --- | --- |
| `~/.config/omarchy-bkg-changer/config.env` | your settings |
| `~/.local/share/omarchy-bkg-changer/images/` | the downloaded image pool, pruned to `BG_KEEP_IMAGES` |
| `~/.local/share/omarchy-bkg-changer/liked/` | images you kept; never pruned |
| `~/.local/state/omarchy-bkg-changer/blocklist` | `<sha256>` + source URL of every image you discarded |
| `~/.local/state/omarchy-bkg-changer/setup-required.png` | generated "configure me" background |
| `~/.local/state/omarchy-bkg-changer/bkg-changer.log` | one line per run, self-truncating |
| `~/.local/state/omarchy/current/background` | Omarchy's symlink to the active image |

Each image in the pool has a small `.src` sidecar next to it holding the URL it
came from, so discarding it can block that URL too.

## Troubleshooting

Check the log first: `tail ~/.local/state/omarchy-bkg-changer/bkg-changer.log`.

- **Nothing happens on install** — `omarchy plugin list` should show
  `ssimo.bkg-changer` enabled. If not: `omarchy plugin enable ssimo.bkg-changer`.
- **The plugin works but there is no icon** — the widget has to be in the bar
  layout: `omarchy bar put ssimo.bkg-changer --after omarchy.clock`.
- **"Not this" says the endpoint only had that same image** — exactly that. Many
  wallpaper endpoints cache one answer for everybody for an hour or more, so
  there is nothing else to hand out yet. The discarded image is still gone and
  still blocked; the plugin shows a cached one until the endpoint moves on.
- **The buttons are greyed out** — the wallpaper on screen did not come from
  this plugin (a theme background, or the setup notice), so there is nothing to
  keep or discard.
- **`endpoint response has no usable .url field`** — the endpoint must return a
  top-level `url` key. Verify with `curl -s "$BG_ENDPOINT" | jq .`.
- **`downloaded content is not a supported image`** — the URL served something
  that is not JPEG/PNG/WebP/GIF/BMP, usually an error page or a redirect to a
  login form.
- **Background never changes offline** — the pool is still empty. It fills up
  one image per successful run.
- **A black background telling you to configure an endpoint** — exactly what it
  says: `BG_ENDPOINT` is empty and nothing has been downloaded yet. Set the
  endpoint in the panel. It is rendered at your largest monitor's resolution
  with ImageMagick, in the system's `sans-serif` font as resolved by
  `fc-match`. Without `magick` the plugin just logs and leaves the background
  alone.
- **Editing the QML changes nothing** — the shell caches compiled QML per file
  URL, so a `rescanPlugins` can hand you the previous version. Run
  `omarchy-restart-shell` while developing.

## Uninstall

```sh
omarchy plugin remove ssimo.bkg-changer
```

The image pool, kept images, config and log are left in place on purpose.
Remove them with:

```sh
rm -rf ~/.config/omarchy-bkg-changer \
       ~/.local/share/omarchy-bkg-changer \
       ~/.local/state/omarchy-bkg-changer
```

Note that if the wallpaper in use came from the pool, delete it only after
picking another background (`omarchy theme bg next`).
