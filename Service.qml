import QtQuick
import Quickshell
import Quickshell.Io

// Headless service plugin: owns the schedule, the bash worker owns the work.
//
// Everything that can fail (network, disk, applying the wallpaper) lives in
// bin/bg-pasticcio. This file only decides *when* to call it and how long to
// wait after a failure.
//
// It is also the plugin's single backend. A bar widget is built once per
// monitor, so the panel keeps no state of its own: it calls the functions
// below and binds to `workerStatus`, and every copy of it agrees.
Item {
  id: root

  // Injected by omarchy-shell's service loader.
  property var shell: null
  property var manifest: null

  readonly property string home: Quickshell.env("HOME") || ""
  readonly property string configPath: home + "/.config/bg-pasticcio/config.env"

  // Qt.resolvedUrl gives a file:// URL; Process needs a plain path.
  readonly property string pluginDir: {
    var url = Qt.resolvedUrl(".").toString()
    if (url.indexOf("file://") === 0)
      url = url.substring(7)
    while (url.length > 1 && url.charAt(url.length - 1) === "/")
      url = url.substring(0, url.length - 1)
    return decodeURIComponent(url)
  }
  readonly property string workerPath: pluginDir + "/bin/bg-pasticcio"

  readonly property int defaultIntervalMinutes: 60
  property int intervalMinutes: defaultIntervalMinutes

  property int consecutiveFailures: 0
  property string lastResult: "never-run"

  // Off until the user says otherwise. Everything below is arranged so that a
  // freshly installed plugin loads, draws its panel, and changes nothing: the
  // schedule does not run, and the worker refuses every command that would
  // touch the wallpaper. `BG_ENABLED` in config.env is the one switch.
  property bool rotationOn: false

  // ------------------------------------------------------------------ config
  //
  // The worker is the source of truth for the config file; the shell only
  // needs the interval and the switch, so parse those two keys rather than a
  // full env parser.
  function applyConfigText(text) {
    var body = text || ""

    var on = false
    var enabledMatch = /^[ \t]*(?:export[ \t]+)?BG_ENABLED[ \t]*=[ \t]*["']?([A-Za-z0-9]+)["']?/m.exec(body)
    if (enabledMatch)
      on = ["1", "true", "yes", "on"].indexOf(String(enabledMatch[1]).toLowerCase()) >= 0
    if (on !== root.rotationOn) {
      root.rotationOn = on
      console.log("bg-pasticcio: rotation is now " + (on ? "on" : "off"))
    }

    var minutes = root.defaultIntervalMinutes
    var match = /^[ \t]*(?:export[ \t]+)?BG_INTERVAL_MINUTES[ \t]*=[ \t]*["']?([0-9]+)["']?/m.exec(body)
    if (match)
      minutes = parseInt(match[1], 10)
    if (!isFinite(minutes) || minutes < 1)
      minutes = root.defaultIntervalMinutes
    if (minutes !== root.intervalMinutes) {
      root.intervalMinutes = minutes
      console.log("bg-pasticcio: interval is now " + minutes + " minute(s)")
    }
  }

  FileView {
    id: configFile
    path: root.configPath
    watchChanges: true
    printErrors: false
    onLoaded: root.applyConfigText(text())
    onLoadFailed: root.applyConfigText("")
    onFileChanged: reload()
  }

  // watchChanges misses the file being replaced by a rename (which is what
  // `sed -i` and most editors do) and cannot watch a config that does not
  // exist yet — the worker creates it on its first run. A cheap re-read closes
  // both gaps; applyConfigText only reacts when the value actually changed.
  Timer {
    interval: 30000
    repeat: true
    running: true
    onTriggered: configFile.reload()
  }

  // ------------------------------------------------------------------ status
  //
  // The full picture — pool counts, ratings, what is on screen — is whatever
  // `bg-pasticcio status` last said. Panels read this rather than shelling out
  // themselves, so N monitors still means one process.
  property var workerStatus: ({})

  // Panels raise this while they are open; nothing polls when nobody is looking.
  property int uiWatchers: 0
  function watch() { root.uiWatchers++ }
  function unwatch() { if (root.uiWatchers > 0) root.uiWatchers-- }

  function refreshStatus() {
    if (statusProc.running)
      return
    statusProc.command = [root.workerPath, "status"]
    statusProc.running = true
  }

  Process {
    id: statusProc
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        var raw = String(text || "").trim()
        if (raw === "")
          return
        try {
          root.workerStatus = JSON.parse(raw)
        } catch (e) {
          console.warn("bg-pasticcio: could not parse status: " + e)
        }
      }
    }
  }

  Timer {
    interval: 5000
    repeat: true
    running: root.uiWatchers > 0
    triggeredOnStart: true
    onTriggered: root.refreshStatus()
  }

  // ------------------------------------------------------------------ worker

  readonly property bool busy: worker.running

  function runWorker(command) {
    if (worker.running) {
      console.log("bg-pasticcio: worker already running, skipping " + command)
      return false
    }
    worker.command = [root.workerPath, command]
    worker.running = true
    return true
  }

  function like() { return runWorker("like") }
  function dislike() { return runWorker("dislike") }
  function rotate() { return runWorker("rotate") }

  // Consent, and the undo for it. `disable` also puts the original background
  // back, which is why both go through the worker rather than through
  // setConfig: only the worker takes the lock that makes that safe.
  function setEnabled(value) { return runWorker(value ? "enable" : "disable") }
  function restore() { return runWorker("restore") }

  // The one place the switch is acted on. Turning it on is a request to see
  // something new now, not in an hour, so the first change is started here
  // rather than left to a timer's side effect. It also covers the shell
  // starting with the switch already on, and a config.env edited by hand.
  //
  // Turning it off: nothing is in flight any more, so a failure recorded
  // before the switch was flipped must not keep the panel saying "not
  // working".
  onRotationOnChanged: {
    if (root.rotationOn) {
      // runNow() only declines while the worker is busy with something else,
      // and runWorker drops what it declines without a trace — so come back
      // for it rather than waiting out a whole interval.
      if (!root.runNow()) {
        retryTimer.interval = 5000
        retryTimer.restart()
      }
      return
    }
    retryTimer.stop()
    root.consecutiveFailures = 0
    root.lastTickMs = 0
  }

  function runNow() {
    retryTimer.stop()
    var started = runWorker("run")
    cycleTimer.restart()
    root.lastTickMs = Date.now()
    return started
  }

  Process {
    id: worker
    onExited: function (exitCode) {
      // Whatever the outcome, the pool and the wallpaper may have moved — and
      // `enable`/`disable` rewrote config.env, so re-read it now rather than
      // waiting out the 30s poll.
      configFile.reload()
      root.refreshStatus()

      if (exitCode === 0) {
        root.consecutiveFailures = 0
        root.lastResult = "ok"
        retryTimer.stop()
        return
      }

      root.lastResult = "failed (exit " + exitCode + ")"
      root.consecutiveFailures++

      // Cross-tick backoff on top of the worker's own per-request backoff:
      // 1, 2, 4, 8 ... minutes, never longer than the normal interval.
      var delay = 60000 * Math.pow(2, Math.min(root.consecutiveFailures - 1, 6))
      var ceiling = root.intervalMinutes * 60000
      retryTimer.interval = Math.max(60000, Math.min(delay, ceiling))
      retryTimer.restart()
      console.warn("bg-pasticcio: run failed (exit " + exitCode + "), retrying in "
                   + Math.round(retryTimer.interval / 60000) + " minute(s)")
    }
  }

  // ------------------------------------------------------------------ config writes
  //
  // Separate from the worker above: editing a setting must not queue behind a
  // download that can take a minute, and `set-config` never touches the pool
  // so it does not take the worker's lock either.

  signal configApplied(string key, bool ok)

  property string pendingConfigKey: ""
  readonly property bool savingConfig: configProc.running

  function setConfig(key, value) {
    if (configProc.running)
      return false
    root.pendingConfigKey = String(key)
    configProc.command = [root.workerPath, "set-config", String(key), String(value)]
    configProc.running = true
    return true
  }

  Process {
    id: configProc
    onExited: function (exitCode) {
      var key = root.pendingConfigKey
      root.pendingConfigKey = ""
      // The worker rewrites the file; re-read it now rather than waiting out
      // the 30s poll, so the interval re-arms as soon as it is saved.
      configFile.reload()
      root.refreshStatus()
      root.configApplied(key, exitCode === 0)
      if (exitCode !== 0)
        console.warn("bg-pasticcio: could not set " + key + " (exit " + exitCode + ")")
    }
  }

  // ------------------------------------------------------------------ timers

  // A QML Timer does not expose its remaining time, so record when the clock
  // last started and let readers work out the rest.
  property double lastTickMs: 0
  readonly property double nextRunMs: lastTickMs > 0
    ? lastTickMs + Math.max(60000, root.intervalMinutes * 60000) : 0

  // Only runs while the switch is on, so an installed-but-untouched plugin has
  // no schedule at all. Deliberately without triggeredOnStart: Qt only honours
  // that flag on a Timer's very first tick, so it cannot be relied on to change
  // the background every time the switch is flipped on. onRotationOnChanged
  // above does that, once, whatever started the timer.
  Timer {
    id: cycleTimer
    interval: Math.max(60000, root.intervalMinutes * 60000)
    repeat: true
    running: root.rotationOn
    onTriggered: {
      root.lastTickMs = Date.now()
      root.runWorker("run")
    }
  }

  Timer {
    id: retryTimer
    repeat: false
    onTriggered: root.runWorker("run")
  }

  // ------------------------------------------------------------------- ipc

  IpcHandler {
    target: "bgpasticcio"

    // Fetch a fresh image now and restart the clock from this moment.
    function next(): string {
      return root.runNow() ? "running" : "busy"
    }

    // Rotate within the images already on disk, no network.
    function rotate(): string {
      return root.rotate() ? "running" : "busy"
    }

    // Keep the image on screen for good; it stops being prunable.
    function like(): string {
      return root.like() ? "running" : "busy"
    }

    // Remove the image on screen, never show it again, replace it now.
    function dislike(): string {
      return root.dislike() ? "running" : "busy"
    }

    // Let the plugin change the background, from now on.
    function enable(): string {
      return root.setEnabled(true) ? "running" : "busy"
    }

    // Stop it, and put the original background back if it is still there.
    function disable(): string {
      return root.setEnabled(false) ? "running" : "busy"
    }

    // Put the background from before the first change back, without changing
    // the switch.
    function restore(): string {
      return root.restore() ? "running" : "busy"
    }

    function status(): string {
      var merged = {
        enabled: root.rotationOn,
        intervalMinutes: root.intervalMinutes,
        running: root.busy,
        lastResult: root.lastResult,
        consecutiveFailures: root.consecutiveFailures,
        nextRun: root.nextRunMs > 0 ? Math.round(root.nextRunMs / 1000) : null,
        worker: root.workerPath,
        configFile: root.configPath
      }
      var extra = root.workerStatus || ({})
      for (var key in extra)
        if (!(key in merged))
          merged[key] = extra[key]
      return JSON.stringify(merged)
    }
  }

  Component.onCompleted: {
    console.log("bg-pasticcio: service loaded, worker=" + root.workerPath)
    configFile.reload()
    root.refreshStatus()
  }
}
