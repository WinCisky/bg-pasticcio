import QtQuick
import QtQuick.Controls
import QtQuick.Layouts
import Quickshell
import Quickshell.Io
import qs.Commons
import qs.Ui

// Bar icon plus its popup: the whole UI for the plugin.
//
// Named BarPanel rather than Panel on purpose. A plugin directory is an
// implicit QML import, so a file called Panel.qml here would shadow qs.Ui's
// Panel with itself and the widget would refuse to load. First-party plugins
// get away with the name because they live inside the shell's import root.
//
// It owns no state. A bar widget is built once per monitor, so anything
// remembered here would exist N times and disagree with itself; the service
// singleton holds the worker, the status and the config writes, and this file
// only renders them. Reached through `bar.shell.serviceFor`, the same way
// omarchy.media's widget reaches its own service.
Panel {
  id: root

  moduleName: "ssimo.bkg-changer"
  // No ipcTarget either: the service already answers on `bkgchanger`, and a
  // handler declared here would register once per monitor. The shell can still
  // summon this panel, because it routes on open()/close()/opened.
  manageIpc: false

  readonly property var service: bar?.shell?.serviceFor("ssimo.bkg-changer")
  readonly property var status: service ? (service.workerStatus || ({})) : ({})

  readonly property color foreground: bar ? bar.foreground : Color.foreground
  readonly property color urgent: bar ? bar.urgent : Color.urgent
  readonly property color dim: Qt.darker(foreground, 1.55)
  readonly property string fontFamily: bar ? bar.fontFamily : Style.font.family

  readonly property bool paused: status.paused === true
  readonly property bool failing: service ? service.consecutiveFailures > 0 : false
  readonly property bool busy: service ? service.busy : false
  readonly property bool ours: status.currentIsOurs === true
  readonly property bool liked: status.currentLiked === true
  readonly property string endpoint: String(status.endpoint || "")

  property string endpointError: ""
  property bool endpointSaved: false

  // Relative times are re-derived from this rather than Date.now(), so an open
  // panel keeps telling the truth instead of freezing at the moment it opened.
  property double nowMs: Date.now()

  implicitWidth: button.implicitWidth
  implicitHeight: button.implicitHeight

  // ------------------------------------------------------------------ helpers

  function ago(epochSeconds) {
    if (!epochSeconds)
      return "never"
    var seconds = Math.max(0, Math.round(root.nowMs / 1000 - epochSeconds))
    if (seconds < 60)
      return "just now"
    var minutes = Math.round(seconds / 60)
    if (minutes < 60)
      return minutes + "m ago"
    var hours = Math.round(minutes / 60)
    if (hours < 48)
      return hours + "h ago"
    return Math.round(hours / 24) + "d ago"
  }

  function untilNextRun() {
    if (!service || service.nextRunMs <= 0)
      return ""
    var minutes = Math.round((service.nextRunMs - root.nowMs) / 60000)
    if (minutes <= 0)
      return "any moment"
    if (minutes < 60)
      return "in " + minutes + "m"
    return "in " + Math.round(minutes / 60) + "h"
  }

  readonly property string headline: {
    if (root.busy)
      return "Working…"
    if (root.paused)
      return "Paused"
    if (root.failing)
      return "Not working"
    if (root.endpoint === "")
      return "No endpoint set"
    return "Running"
  }

  readonly property color headlineColor: root.failing ? root.urgent
    : (root.paused || root.endpoint === "" ? root.dim : root.foreground)

  readonly property string detailLine: {
    var message = String(root.status.lastMessage || "")
    var when = root.ago(root.status.lastRun)
    if (message === "")
      return "Last change " + when
    return message + " · " + when
  }

  function resetEndpointField() {
    endpointField.text = root.endpoint
    root.endpointError = ""
    root.endpointSaved = false
  }

  // The first status of an open panel arrives after it is already on screen,
  // so the field has to follow the value in rather than only be seeded once.
  // Never while it has focus: that would overwrite what is being typed.
  onEndpointChanged: if (!endpointField.activeFocus) endpointField.text = root.endpoint

  function commitEndpoint() {
    if (!root.service)
      return
    var value = endpointField.text.trim()
    if (value === root.endpoint) {
      root.endpointError = ""
      return
    }
    root.endpointError = ""
    root.service.setConfig("BG_ENDPOINT", value)
  }

  function setPaused(value) {
    if (!root.bar)
      return
    root.bar.run("omarchy-toggle bkg-changer-off " + (value ? "on" : "off"))
    pauseSettleTimer.restart()
  }

  // omarchy-toggle is fire-and-forget, so there is nothing to wait on; give
  // the flag a moment to land before asking the worker what it sees.
  Timer {
    id: pauseSettleTimer
    interval: 250
    onTriggered: if (root.service) root.service.refreshStatus()
  }

  Timer {
    interval: 30000
    repeat: true
    running: root.opened
    triggeredOnStart: true
    onTriggered: root.nowMs = Date.now()
  }

  onOpenedChanged: {
    if (!root.service)
      return
    if (root.opened) {
      root.nowMs = Date.now()
      root.service.watch()
      root.service.refreshStatus()
      root.resetEndpointField()
      if (panelFlick)
        panelFlick.contentY = 0
      Qt.callLater(function () { keyCatcher.forceActiveFocus() })
    } else {
      root.service.unwatch()
    }
  }

  // Connected by hand rather than with Connections: the service is resolved
  // through the bar, so it is still null when this element is created, and a
  // declarative handler on a null target only warns about a signal it cannot
  // see yet.
  property var connectedService: null

  function onConfigApplied(key, ok) {
    if (key !== "BG_ENDPOINT")
      return
    root.endpointError = ok ? "" : "Needs to be empty or an http(s) URL"
    root.endpointSaved = ok
    if (ok)
      endpointSavedTimer.restart()
  }

  function bindService() {
    if (root.connectedService === root.service)
      return
    if (root.connectedService)
      root.connectedService.configApplied.disconnect(root.onConfigApplied)
    root.connectedService = root.service
    if (root.connectedService)
      root.connectedService.configApplied.connect(root.onConfigApplied)
  }

  onServiceChanged: root.bindService()
  Component.onCompleted: root.bindService()

  Timer {
    id: endpointSavedTimer
    interval: 2000
    onTriggered: root.endpointSaved = false
  }

  // ------------------------------------------------------------------ bar icon

  BarIconButton {
    id: button
    anchors.fill: parent
    bar: root.bar
    text: "󰸉"
    active: root.failing
    dimmed: root.paused && !root.failing
    tooltipText: root.headline + " · " + root.detailLine
    onPressed: function (mouseButton) {
      if (!root.service) {
        root.toggle()
        return
      }
      if (mouseButton === Qt.RightButton)
        root.service.runNow()
      else if (mouseButton === Qt.MiddleButton)
        root.service.rotate()
      else
        root.toggle()
    }
  }

  // ------------------------------------------------------------------ panel

  KeyboardPanel {
    id: panel
    anchorItem: button
    owner: root
    bar: root.bar
    open: root.opened
    focusTarget: keyCatcher
    contentWidth: panel.fittedContentWidth(Style.space(360))
    contentHeight: panel.fittedContentHeight(column.implicitHeight, Style.space(720))

    PanelKeyCatcher {
      id: keyCatcher
      anchors.fill: parent
      // While a field owns the keys, the panel's own shortcuts must not eat
      // what is being typed into it.
      blocked: endpointField.activeFocus || intervalField.field.activeFocus
               || keepField.field.activeFocus

      onCloseRequested: root.close()
      onTabRequested: function (direction) { root.switchPanel(direction) }
      onDeleteRequested: if (root.ours && !root.busy && root.service) root.service.dislike()
      onTextKey: function (character) {
        if (!root.service || root.busy)
          return
        if (character === "f" || character === "F") {
          if (root.ours && !root.liked)
            root.service.like()
        } else if (character === "d" || character === "D") {
          if (root.ours)
            root.service.dislike()
        } else if (character === "n" || character === "N") {
          root.service.runNow()
        } else if (character === "p" || character === "P") {
          root.setPaused(!root.paused)
        }
      }

      Flickable {
        id: panelFlick
        anchors.fill: parent
        contentWidth: width
        contentHeight: column.implicitHeight
        clip: true
        boundsBehavior: Flickable.StopAtBounds
        flickableDirection: Flickable.VerticalFlick
        interactive: contentHeight > height
        ScrollBar.vertical: ScrollBar { policy: ScrollBar.AsNeeded }

        Column {
          id: column
          width: panelFlick.width
          spacing: Style.space(12)

          // ------------------------------------------------------- preview

          Rectangle {
            id: preview
            width: parent.width
            height: Math.min(Style.space(150), Math.round(width * 9 / 16))
            radius: Style.cornerRadius
            clip: true
            color: Qt.rgba(root.foreground.r, root.foreground.g, root.foreground.b, 0.06)

            Image {
              id: previewImage
              anchors.fill: parent
              // Util.fileUrl percent-encodes each segment; a hand-built
              // "file://" + path breaks on spaces in a user's home.
              source: root.status.currentBackground
                ? Util.fileUrl(String(root.status.currentBackground)) : ""
              sourceSize.width: Math.round(preview.width * Screen.devicePixelRatio)
              fillMode: Image.PreserveAspectCrop
              asynchronous: true
              cache: false
              smooth: true
              visible: status === Image.Ready
            }

            Text {
              anchors.centerIn: parent
              visible: previewImage.status !== Image.Ready
              text: previewImage.status === Image.Loading ? "Loading…" : "No wallpaper yet"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
            }

            // A liked image says so on the image, so the state is readable
            // without hunting for a disabled button.
            Rectangle {
              visible: root.liked
              anchors.top: parent.top
              anchors.right: parent.right
              anchors.margins: Style.space(8)
              width: badge.implicitWidth + Style.space(12)
              height: badge.implicitHeight + Style.space(6)
              radius: Style.cornerRadius
              color: Qt.rgba(0, 0, 0, 0.55)

              Text {
                id: badge
                anchors.centerIn: parent
                text: "󰋑  Kept"
                color: "white"
                font.family: root.fontFamily
                font.pixelSize: Style.font.caption
              }
            }
          }

          // -------------------------------------------------------- status

          Column {
            width: parent.width
            spacing: Style.space(2)

            Row {
              width: parent.width
              spacing: Style.space(8)

              Text {
                id: headlineText
                text: root.headline
                color: root.headlineColor
                font.family: root.fontFamily
                font.pixelSize: Style.font.subtitle
              }

              Text {
                anchors.baseline: headlineText.baseline
                visible: !root.paused && root.untilNextRun() !== ""
                text: "· next " + root.untilNextRun()
                color: root.dim
                font.family: root.fontFamily
                font.pixelSize: Style.font.bodySmall
              }
            }

            Text {
              width: parent.width
              text: root.detailLine
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.bodySmall
              wrapMode: Text.WordWrap
            }
          }

          // ------------------------------------------------------- verdict

          Row {
            width: parent.width
            spacing: Style.space(8)

            Button {
              text: root.liked ? "Kept" : "Keep"
              iconText: root.liked ? "󰋑" : "󰋕"
              tooltipText: root.liked
                ? "Already kept — it will not be pruned"
                : "Keep this one for good (f)"
              enabled: root.ours && !root.liked && !root.busy
              opacity: enabled ? 1.0 : 0.4
              foreground: root.foreground
              fontFamily: root.fontFamily
              bordered: true
              onClicked: if (root.service) root.service.like()
            }

            Button {
              text: "Not this"
              iconText: "󰩹"
              tooltipText: "Delete it, never show it again, fetch another (d)"
              enabled: root.ours && !root.busy
              opacity: enabled ? 1.0 : 0.4
              foreground: root.foreground
              accent: root.urgent
              fontFamily: root.fontFamily
              bordered: true
              onClicked: if (root.service) root.service.dislike()
            }

            Button {
              text: "Next"
              iconText: "󰑐"
              tooltipText: "Fetch a new image now and restart the clock (n)"
              enabled: !root.busy
              opacity: enabled ? 1.0 : 0.4
              foreground: root.foreground
              fontFamily: root.fontFamily
              bordered: true
              onClicked: if (root.service) root.service.runNow()
            }
          }

          Text {
            width: parent.width
            visible: !root.ours && !!root.status.currentBackground
            text: "The wallpaper on screen did not come from here, so there is nothing to rate."
            color: root.dim
            font.family: root.fontFamily
            font.pixelSize: Style.font.caption
            wrapMode: Text.WordWrap
          }

          PanelSeparator { foreground: root.foreground }

          // ------------------------------------------------------ endpoint

          Column {
            width: parent.width
            spacing: Style.space(6)

            PanelSectionHeader {
              text: "ENDPOINT"
              foreground: root.foreground
              fontFamily: root.fontFamily
            }

            Item {
              width: parent.width
              implicitHeight: Math.max(endpointField.implicitHeight, saveEndpoint.implicitHeight)

              TextField {
                id: endpointField
                anchors.left: parent.left
                anchors.right: saveEndpoint.left
                anchors.rightMargin: Style.space(6)
                anchors.verticalCenter: parent.verticalCenter
                enabled: !!root.service && !root.service.savingConfig
                placeholderText: "https://example.com/wallpaper.json"
                foreground: root.foreground
                font.family: root.fontFamily

                Keys.onPressed: function (event) {
                  if (event.key === Qt.Key_Escape) {
                    root.resetEndpointField()
                    keyCatcher.forceActiveFocus()
                    event.accepted = true
                  } else if (event.key === Qt.Key_Return || event.key === Qt.Key_Enter) {
                    root.commitEndpoint()
                    event.accepted = true
                  }
                }
              }

              PanelActionButton {
                id: saveEndpoint
                anchors.right: parent.right
                anchors.verticalCenter: parent.verticalCenter
                iconText: root.endpointSaved ? "󰄬" : "󰆓"
                tooltipText: "Save the endpoint"
                enabled: !!root.service && !root.service.savingConfig
                         && endpointField.text.trim() !== root.endpoint
                opacity: enabled ? 1.0 : 0.4
                foreground: root.foreground
                fontFamily: root.fontFamily
                onClicked: root.commitEndpoint()
              }
            }

            Text {
              width: parent.width
              visible: root.endpointError !== "" || root.endpointSaved
              text: root.endpointError !== "" ? root.endpointError : "Saved"
              color: root.endpointError !== "" ? root.urgent : root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }

            Text {
              width: parent.width
              visible: root.endpointError === "" && !root.endpointSaved
              text: "Answers with {\"url\": \"https://…/image.jpg\"}. Empty rotates what is already downloaded."
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              wrapMode: Text.WordWrap
            }
          }

          PanelSeparator { foreground: root.foreground }

          // ------------------------------------------------------ schedule

          Row {
            width: parent.width
            spacing: Style.space(12)

            NumberField {
              id: intervalField
              label: "Change every (min)"
              from: 1
              to: 10080
              stepSize: 5
              value: root.status.intervalMinutes || 60
              foreground: root.foreground
              fontFamily: root.fontFamily
              fieldWidth: Style.space(120)
              onModified: function (next) {
                if (root.service && next !== root.status.intervalMinutes)
                  root.service.setConfig("BG_INTERVAL_MINUTES", String(next))
              }
            }

            NumberField {
              id: keepField
              label: "Keep (images)"
              from: 1
              to: 200
              stepSize: 1
              value: root.status.keepImages || 10
              foreground: root.foreground
              fontFamily: root.fontFamily
              fieldWidth: Style.space(120)
              onModified: function (next) {
                if (root.service && next !== root.status.keepImages)
                  root.service.setConfig("BG_KEEP_IMAGES", String(next))
              }
            }
          }

          Toggle {
            width: parent.width
            label: "Pause rotation"
            description: "Keeps the plugin loaded, stops it changing the background"
            checked: root.paused
            foreground: root.foreground
            fontFamily: root.fontFamily
            onClicked: root.setPaused(!root.paused)
          }

          PanelSeparator { foreground: root.foreground }

          // -------------------------------------------------------- footer

          Column {
            width: parent.width
            spacing: Style.space(2)

            Text {
              width: parent.width
              text: (root.status.storedImages || 0) + " cached · "
                + (root.status.likedImages || 0) + " kept · "
                + (root.status.blockedImages || 0) + " never again"
              color: root.dim
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
            }

            Text {
              width: parent.width
              visible: String(root.status.lastLog || "") !== ""
              text: String(root.status.lastLog || "")
              color: Qt.darker(root.foreground, 2.0)
              font.family: root.fontFamily
              font.pixelSize: Style.font.caption
              elide: Text.ElideRight
              maximumLineCount: 1
            }
          }
        }
      }
    }
  }
}
