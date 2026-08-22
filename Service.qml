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

  // config.env is a file a person edits, so its size is not this service's to
  // assume: a stray `>>`, a mis-aimed redirect, a paste that went wrong can all
  // leave a file far bigger than the handful of lines expected here. A FileView
  // would hand back whatever it found, whole — and this service is long-lived
  // and re-reads on a timer, so that would be an unbounded allocation repeated
  // every 30 s. Bound the read at the source instead: only the capped prefix is
  // ever parsed, and nothing larger is held even briefly.
  //
  // 64 KiB is ~40x the config the worker writes, and both keys read here sit in
  // its first lines, so the cap cannot cut off a file this plugin produced.
  readonly property int configReadLimit: 65536
  property bool configTruncated: false

  // A re-read that arrives while one is in flight is remembered rather than
  // dropped: the read after `enable` is what starts the schedule, and it must
  // not be the one that loses a race with the 30 s poll.
  property bool configReloadPending: false

  function reloadConfig() {
    if (configReader.running) {
      root.configReloadPending = true
      return
    }
    root.configReloadPending = false
    configReader.command = ["head", "-c", String(root.configReadLimit),
                            "--", root.configPath]
    configReader.running = true
  }

  Process {
    id: configReader
    onExited: if (root.configReloadPending) root.reloadConfig()
    // Collected and dropped: before the worker's first run there is no config
    // to read, and "head: cannot open" every 30 s is not worth logging. This is
    // what printErrors: false bought on the FileView this replaced.
    stderr: StdioCollector { waitForEnd: true }
    stdout: StdioCollector {
      waitForEnd: true
      onStreamFinished: {
        // No config yet, or one that could not be read, reads as empty — which
        // parses as the switch being off, the safe way to be wrong.
        var body = String(text || "")
        // Measured on the bytes, not the string: the cap head was given is in
        // bytes, and one em dash in a comment is enough to make a full read
        // look short of it.
        var truncated = (data ? data.byteLength : 0) >= root.configReadLimit
        if (truncated !== root.configTruncated) {
          root.configTruncated = truncated
          if (truncated)
            console.warn("bg-pasticcio: " + root.configPath + " is larger than "
                         + root.configReadLimit + " bytes; only that much is read,"
                         + " settings past it are ignored")
        }
        root.applyConfigText(body)
      }
    }
  }

  // Polled rather than watched. A file watch would have to keep the file loaded
  // to notice it change, which is the read just bounded above, and it misses the
  // case that matters most anyway: a file replaced by rename — what `sed -i`,
  // most editors, and the worker's own set-config all do. Every write this
  // plugin makes re-reads explicitly (see the Process handlers below), so the
  // poll only has to catch a hand edit; applyConfigText reacts only when a value
  // actually changed, so a poll that finds nothing new costs nothing.
  Timer {
    interval: 30000
    repeat: true
    running: true
    onTriggered: root.reloadConfig()
  }

  // ------------------------------------------------------------------ status
  //
  // The full picture — kept images, ratings, what is on screen — is whatever
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
      // Whatever the outcome, the images and the wallpaper may have moved — and
      // `enable`/`disable` rewrote config.env, so re-read it now rather than
      // waiting out the 30s poll.
      root.reloadConfig()
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
  // download that can take a minute, and `set-config` never touches the images
  // so it does not take the worker's lock either.

  signal configApplied(string key, bool ok)

  property string pendingConfigKey: ""
  // Held only between starting the worker and writing the value to it, then
  // cleared: BG_ENDPOINT can carry a token and this object is reachable from
  // every panel in the bar.
  property string pendingConfigValue: ""
  readonly property bool savingConfig: configProc.running

  function setConfig(key, value) {
    if (configProc.running)
      return false
    var text = String(value)
    // The worker reads one line, and refuses a value carrying a newline in any
    // case. Caught here so a pasted value is rejected rather than silently
    // saved cut in half.
    if (text.indexOf("\n") >= 0 || text.indexOf("\r") >= 0)
      return false
    root.pendingConfigKey = String(key)
    root.pendingConfigValue = text
    // Key in the argument list, value on stdin. An argument is visible in
    // /proc/<pid>/cmdline to every local user unless /proc was mounted with
    // hidepid, and the endpoint is the one setting here that can be a secret.
    configProc.command = [root.workerPath, "set-config", String(key)]
    configProc.stdinEnabled = true
    configProc.running = true
    return true
  }

  Process {
    id: configProc

    // On started rather than straight after `running = true`, so there is
    // certainly a process to write to. The newline is what ends the worker's
    // read, so stdin never has to be closed for it to get on with it — and not
    // closing it here is what keeps the write from racing the close.
    onStarted: {
      configProc.write(root.pendingConfigValue + "\n")
      root.pendingConfigValue = ""
    }

    onExited: function (exitCode) {
      var key = root.pendingConfigKey
      root.pendingConfigKey = ""
      // The worker rewrites the file; re-read it now rather than waiting out
      // the 30s poll, so the interval re-arms as soon as it is saved.
      root.reloadConfig()
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
    root.reloadConfig()
    root.refreshStatus()
  }
}
