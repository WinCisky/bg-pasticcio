import QtQuick
import Quickshell
import Quickshell.Io

// Headless service plugin: owns the schedule, the bash worker owns the work.
//
// Everything that can fail (network, disk, applying the wallpaper) lives in
// bin/bkg-changer. This file only decides *when* to call it and how long to
// wait after a failure.
Item {
  id: root

  // Injected by omarchy-shell's service loader.
  property var shell: null
  property var manifest: null

  readonly property string home: Quickshell.env("HOME") || ""
  readonly property string configPath: home + "/.config/omarchy-bkg-changer/config.env"

  // Qt.resolvedUrl gives a file:// URL; Process needs a plain path.
  readonly property string pluginDir: {
    var url = Qt.resolvedUrl(".").toString()
    if (url.indexOf("file://") === 0)
      url = url.substring(7)
    while (url.length > 1 && url.charAt(url.length - 1) === "/")
      url = url.substring(0, url.length - 1)
    return decodeURIComponent(url)
  }
  readonly property string workerPath: pluginDir + "/bin/bkg-changer"

  readonly property int defaultIntervalMinutes: 60
  property int intervalMinutes: defaultIntervalMinutes

  property int consecutiveFailures: 0
  property string lastResult: "never-run"

  // ------------------------------------------------------------------ config
  //
  // The worker is the source of truth for the config file; the shell only
  // needs the interval, so parse that one key rather than a full env parser.
  function applyConfigText(text) {
    var minutes = root.defaultIntervalMinutes
    var match = /^[ \t]*(?:export[ \t]+)?BG_INTERVAL_MINUTES[ \t]*=[ \t]*["']?([0-9]+)["']?/m.exec(text || "")
    if (match)
      minutes = parseInt(match[1], 10)
    if (!isFinite(minutes) || minutes < 1)
      minutes = root.defaultIntervalMinutes
    if (minutes !== root.intervalMinutes) {
      root.intervalMinutes = minutes
      console.log("bkg-changer: interval is now " + minutes + " minute(s)")
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

  // ------------------------------------------------------------------ worker

  function runWorker(command) {
    if (worker.running) {
      console.log("bkg-changer: worker already running, skipping " + command)
      return false
    }
    worker.command = [root.workerPath, command]
    worker.running = true
    return true
  }

  Process {
    id: worker
    onExited: function (exitCode) {
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
      console.warn("bkg-changer: run failed (exit " + exitCode + "), retrying in "
                   + Math.round(retryTimer.interval / 60000) + " minute(s)")
    }
  }

  // ------------------------------------------------------------------ timers

  // triggeredOnStart is what makes the background change the moment the plugin
  // is installed and enabled — no user action, no waiting for the first hour.
  Timer {
    id: cycleTimer
    interval: Math.max(60000, root.intervalMinutes * 60000)
    repeat: true
    running: true
    triggeredOnStart: true
    onTriggered: root.runWorker("run")
  }

  Timer {
    id: retryTimer
    repeat: false
    onTriggered: root.runWorker("run")
  }

  // ------------------------------------------------------------------- ipc

  IpcHandler {
    target: "bkgchanger"

    // Fetch a fresh image now and restart the clock from this moment.
    function next(): string {
      retryTimer.stop()
      var started = root.runWorker("run")
      cycleTimer.restart()
      return started ? "running" : "busy"
    }

    // Rotate within the already-downloaded pool, no network.
    function rotate(): string {
      return root.runWorker("rotate") ? "running" : "busy"
    }

    function status(): string {
      return JSON.stringify({
        intervalMinutes: root.intervalMinutes,
        running: worker.running,
        lastResult: root.lastResult,
        consecutiveFailures: root.consecutiveFailures,
        worker: root.workerPath,
        configFile: root.configPath
      })
    }
  }

  Component.onCompleted: console.log("bkg-changer: service loaded, worker=" + root.workerPath)
}
