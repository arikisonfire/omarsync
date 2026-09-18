import QtQuick

// Bar icon: "rs" inside a ring that doubles as a progress indicator, plus a
// status badge. Distinct from the round-arrow update/sync glyphs.
//
//   idle      faint full ring
//   running   ring fills with progress; while rsync builds the file list a
//             short segment circles instead
//   badge     "prompt" pulsing lock · "failed" red dot · "done" check for 6 s
//             after a successful run · "dry" small n during a dry run
Item {
  id: root

  property color color: "white"
  property color urgent: "red"
  property string fontFamily: "monospace"
  property bool running: false
  property real progress: -1           // 0..1, < 0 = unknown
  property string badge: ""            // "" | prompt | failed | done | dry

  implicitWidth: 16
  implicitHeight: 16

  readonly property real size: Math.min(width, height) * 1.18
  readonly property bool indeterminate: running && progress < 0

  Canvas {
    id: ring
    anchors.centerIn: parent
    width: root.size
    height: root.size
    antialiasing: true
    onPaint: {
      var ctx = getContext("2d")
      ctx.reset()
      var c = width / 2
      var lw = Math.max(1.3, width * 0.09)
      var r = c - lw / 2
      var top = -Math.PI / 2
      ctx.lineCap = "round"
      ctx.lineWidth = lw
      ctx.strokeStyle = root.color

      ctx.globalAlpha = root.running ? 0.28 : 0.55
      ctx.beginPath()
      ctx.arc(c, c, r, 0, Math.PI * 2, false)
      ctx.stroke()

      if (!root.running) return
      ctx.globalAlpha = 1
      ctx.beginPath()
      if (root.indeterminate) ctx.arc(c, c, r, top, top + Math.PI * 0.5, false)
      else if (root.progress > 0) ctx.arc(c, c, r, top, top + Math.PI * 2 * Math.min(1, root.progress), false)
      ctx.stroke()
    }

    RotationAnimator on rotation {
      running: root.indeterminate
      from: 0
      to: 360
      duration: 1100
      loops: Animation.Infinite
      onStopped: ring.rotation = 0
    }
  }

  Text {
    textFormat: Text.PlainText
    anchors.centerIn: parent
    anchors.verticalCenterOffset: -root.size * 0.02
    text: "rs"
    color: root.color
    font.family: root.fontFamily
    font.pixelSize: Math.max(6, Math.round(root.size * 0.46))
    font.bold: true
  }

  Item {
    id: badgeBox
    visible: root.badge !== ""
    width: Math.max(6, Math.round(root.size * 0.44))
    height: width
    x: root.width / 2 + root.size / 2 - width * 0.55
    y: root.height / 2 + root.size / 2 - height * 0.55

    Canvas {
      id: badgeCanvas
      anchors.fill: parent
      antialiasing: true
      onPaint: {
        var ctx = getContext("2d")
        ctx.reset()
        var s = width
        if (root.badge === "failed") {
          ctx.fillStyle = root.urgent
          ctx.beginPath()
          ctx.arc(s / 2, s / 2, s * 0.42, 0, Math.PI * 2)
          ctx.fill()
        } else if (root.badge === "done") {
          ctx.strokeStyle = root.color
          ctx.lineWidth = Math.max(1.3, s * 0.17)
          ctx.lineCap = "round"
          ctx.lineJoin = "round"
          ctx.beginPath()
          ctx.moveTo(s * 0.16, s * 0.55)
          ctx.lineTo(s * 0.42, s * 0.8)
          ctx.lineTo(s * 0.86, s * 0.24)
          ctx.stroke()
        } else if (root.badge === "prompt") {
          ctx.fillStyle = root.urgent
          ctx.strokeStyle = root.urgent
          ctx.lineWidth = Math.max(1.1, s * 0.13)
          ctx.beginPath()
          ctx.arc(s / 2, s * 0.42, s * 0.22, Math.PI, 0, false)   // shackle
          ctx.stroke()
          ctx.fillRect(s * 0.16, s * 0.42, s * 0.68, s * 0.5)     // body
        }
      }
    }

    Text {
      textFormat: Text.PlainText
      visible: root.badge === "dry"
      anchors.centerIn: parent
      text: "n"
      color: root.color
      font.family: root.fontFamily
      font.pixelSize: Math.max(6, Math.round(parent.width * 1.05))
      font.bold: true
    }

    SequentialAnimation on opacity {
      running: root.badge === "prompt"
      loops: Animation.Infinite
      NumberAnimation { from: 1; to: 0.25; duration: 550; easing.type: Easing.InOutQuad }
      NumberAnimation { from: 0.25; to: 1; duration: 550; easing.type: Easing.InOutQuad }
      onStopped: badgeBox.opacity = 1
    }
  }

  onColorChanged: { ring.requestPaint(); badgeCanvas.requestPaint() }
  onUrgentChanged: badgeCanvas.requestPaint()
  onRunningChanged: ring.requestPaint()
  onProgressChanged: ring.requestPaint()
  onBadgeChanged: badgeCanvas.requestPaint()
  onWidthChanged: ring.requestPaint()
}
