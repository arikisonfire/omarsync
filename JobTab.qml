import QtQuick
import QtQuick.Controls as QQC
import Quickshell
import qs.Commons
import qs.Ui

import "Options.js" as Options
import "Locations.js" as Locations
import "Easy.js" as Easy

// Job tab: source and destination, the SSH box, the Easy-mode questions or the
// Expert presets and quick switches, the command preview with its blockers and
// warnings, and the saved profiles.

Flickable {
  id: jobPage

  required property var panel
  anchors.fill: parent
  contentHeight: jobColumn.implicitHeight
  clip: true
  boundsBehavior: Flickable.StopAtBounds
  QQC.ScrollBar.vertical: QQC.ScrollBar { policy: jobPage.contentHeight > jobPage.height ? QQC.ScrollBar.AlwaysOn : QQC.ScrollBar.AlwaysOff }

  Column {
    id: jobColumn
    width: jobPage.width - Style.spacing.xl
    spacing: Style.spacing.xl

    PathField {
      width: parent.width
      title: "SOURCE"
      path: panel.job.src
      info: panel.srcInfo
      choices: panel.opened && panel.tab === "job" ? panel.choicesFor("src") : []
      icons: panel.icons
      foreground: panel.fg
      fontFamily: panel.ff
      onEdited: function(t) { panel.setPath("src", t) }
      onBrowse: function(mode) { panel.browse("src", mode) }
      onPicked: function(i) { panel.pickChoice("src", choices[i]) }
    }

    Item {
      width: parent.width
      implicitHeight: Math.max(swapButton.height, contentsRow.implicitHeight)
      Row {
        id: contentsRow
        spacing: Style.spacing.md
        anchors.verticalCenter: parent.verticalCenter
        visible: panel.job.src !== ""
        ToggleSwitch {
          checked: panel.contentsOnly
          foreground: panel.fg
          onToggled: panel.setContentsOnly(!panel.contentsOnly)
          anchors.verticalCenter: parent.verticalCenter
        }
        Text {
          textFormat: Text.PlainText
          anchors.verticalCenter: parent.verticalCenter
          width: jobColumn.width - swapButton.width - Style.space(80)
          wrapMode: Text.WordWrap
          readonly property string name: String(panel.job.src).replace(/\/+$/, "").replace(/^.*[\/:]/, "") || "/"
          readonly property string dstName: String(panel.job.dst).replace(/\/+$/, "").replace(/^.*[\/:]/, "") || "/"
          text: panel.contentsOnly
            ? "Copy the contents of “" + name + "” into " + (panel.job.dst ? "“" + dstName + "”" : "the destination")
            : "Copy the folder “" + name + "” itself: creates " + (panel.job.dst ? dstName + "/" : "") + name
          color: panel.dim
          font.family: panel.ff
          font.pixelSize: Style.font.caption
        }
      }
      PanelActionButton {
        id: swapButton
        anchors.right: parent.right
        iconText: panel.icons.swap
        tooltipText: "Swap source and destination"
        foreground: panel.fg
        fontFamily: panel.ff
        bordered: true
        onClicked: panel.swapPaths()
      }
    }

    PathField {
      width: parent.width
      title: "DESTINATION"
      path: panel.job.dst
      info: panel.dstInfo
      choices: panel.opened && panel.tab === "job" ? panel.choicesFor("dst") : []
      icons: panel.icons
      foreground: panel.fg
      fontFamily: panel.ff
      onEdited: function(t) { panel.setPath("dst", t) }
      onBrowse: function(mode) { panel.browse("dst", mode) }
      onPicked: function(i) { panel.pickChoice("dst", choices[i]) }
    }

    // ---- SSH box
    BorderSurface {
      visible: panel.remotePath !== ""
      width: parent.width
      height: visible ? sshColumn.implicitHeight + Style.spacing.xl * 2 : 0
      radius: Style.cornerRadius
      color: Style.normalFillFor(panel.fg, Color.accent, Color.urgent)
      borderSpec: Border.controlSpec("normal", panel.fg, Color.accent)

      Column {
        id: sshColumn
        x: Style.spacing.xl
        y: Style.spacing.xl
        width: parent.width - Style.spacing.xl * 2
        spacing: Style.spacing.md

        Item {
          width: parent.width
          implicitHeight: Math.max(sshTitle.implicitHeight, sshButtons.implicitHeight)
          Text {
            textFormat: Text.PlainText
            id: sshTitle
            anchors.verticalCenter: parent.verticalCenter
            text: panel.icons.server + "  SSH · " + panel.sshHostArg() + (Number(panel.job.opts.sshPort) ? " port " + panel.job.opts.sshPort : "")
            color: panel.fg
            font.family: panel.ff
            font.pixelSize: Style.font.body
            font.bold: true
          }
          Row {
            id: sshButtons
            anchors.right: parent.right
            spacing: Style.spacing.md
            Button {
              visible: panel.auxRunning
              text: "Cancel"
              foreground: Color.urgent
              fontFamily: panel.ff
              fontSize: Style.font.caption
              bordered: true
              onClicked: panel.stopAux()
            }
            Button {
              text: "Test connection"
              iconText: panel.icons.connect
              bordered: true
              enabled: !panel.busy && panel.plainSsh
              opacity: enabled ? 1 : 0.5
              foreground: panel.fg
              fontFamily: panel.ff
              fontSize: Style.font.caption
              onClicked: panel.testConnection()
            }
            Button {
              text: "Set up key login"
              iconText: panel.icons.key
              bordered: true
              enabled: !panel.busy && panel.plainSsh
              opacity: enabled ? 1 : 0.5
              tooltipText: "Install " + panel.setupKeyFile + " on the server (created if it does not exist yet), so the server password is no longer needed. A key with a passphrase asks for it until the keyring remembers it."
              foreground: panel.fg
              fontFamily: panel.ff
              fontSize: Style.font.caption
              onClicked: panel.setupKeyLogin()
            }
          }
        }
        Text {
          visible: panel.auxResult !== ""
          width: parent.width
          wrapMode: Text.WordWrap
          textFormat: Text.PlainText
          text: panel.auxResult
          color: panel.auxRunning ? panel.dim : panel.auxOk ? panel.fg : Color.urgent
          font.family: panel.ff
          font.pixelSize: Style.font.caption
        }
        Text {
          width: parent.width
          wrapMode: Text.WordWrap
          textFormat: Text.PlainText
          text: panel.hostKeyChanged
            ? "⚠ The server's identity changed. This can mean someone is intercepting the connection: ssh refused or restricted the login. Only after the server's administrator confirms the new key, remove the old entry (ssh-keygen -R host) and connect again."
            : "Passwords, key passphrases and new host keys are asked for right here. Nothing is stored unless you tick Remember."
          color: panel.hostKeyChanged ? Color.urgent : panel.dim
          font.family: panel.ff
          font.pixelSize: Style.font.caption
        }
        Row {
          visible: panel.savedPassword
          spacing: Style.spacing.md
          Text {
            textFormat: Text.PlainText
            text: panel.icons.key + "  A password for " + panel.keyringTarget + " is saved in the keyring"
            color: panel.dim
            font.family: panel.ff
            font.pixelSize: Style.font.caption
            anchors.verticalCenter: parent.verticalCenter
          }
          Button {
            text: "Forget"
            bordered: true
            foreground: panel.fg
            fontFamily: panel.ff
            fontSize: Style.font.caption
            onClicked: panel.forgetPassword()
          }
        }
        Row {
          visible: panel.savedPassphrase
          spacing: Style.spacing.md
          Text {
            textFormat: Text.PlainText
            text: panel.icons.key + "  The passphrase of the key " + panel.fileName(panel.setupKeyFile) + " is saved in the keyring"
            color: panel.dim
            font.family: panel.ff
            font.pixelSize: Style.font.caption
            anchors.verticalCenter: parent.verticalCenter
          }
          Button {
            text: "Forget"
            bordered: true
            foreground: panel.fg
            fontFamily: panel.ff
            fontSize: Style.font.caption
            onClicked: panel.forgetPassphrase()
          }
        }
      }
    }

    PanelSeparator { foreground: panel.fg }

    // ---- easy mode questions
    EasyOptions {
      visible: !panel.expert
      width: parent.width
      answers: panel.easyAnswers
      summary: {
        var base = function(p) { return String(p).replace(/\/+$/, "").replace(/^.*[\/:]/, "") || "/" }
        return Easy.summary(panel.job, {
          srcName: base(panel.job.src) === "/" && panel.job.srcAnchor ? panel.job.srcAnchor.label : base(panel.job.src),
          dstName: base(panel.job.dst) === "/" && panel.job.dstAnchor ? panel.job.dstAnchor.label : base(panel.job.dst),
          contentsOnly: panel.contentsOnly, remote: panel.remotePath !== "", dstFs: panel.dstFs
        })
      }
      remote: panel.remotePath !== ""
      foreground: panel.fg
      fontFamily: panel.ff
      onGoalPicked: function(id) { panel.easyGoal(id) }
      onAnswered: function(key, value) { panel.easyAnswer(key, value) }
      onOpenExpert: panel.setUiMode("expert")
    }

    // ---- presets
    Column {
      visible: panel.expert
      width: parent.width
      spacing: Style.spacing.md
      PanelSectionHeader { text: "MODE"; foreground: panel.fg; fontFamily: panel.ff }
      ButtonGroup {
        focusable: false
        foreground: panel.fg
        fontFamily: panel.ff
        value: panel.activePreset
        options: Options.PRESETS.map(function(p) { return { value: p.id, label: p.label, tooltip: p.hint } })
          .concat([{ value: "custom", label: "Custom", tooltip: "Your own combination (Options tab)" }])
        onChanged: function(v) {
          for (var i = 0; i < Options.PRESETS.length; i++) if (Options.PRESETS[i].id === v) panel.applyPreset(Options.PRESETS[i])
          if (v === "custom") panel.tab = "options"
        }
      }
      Text {
        width: parent.width
        wrapMode: Text.WordWrap
        textFormat: Text.PlainText
        text: {
          for (var i = 0; i < Options.PRESETS.length; i++) if (Options.PRESETS[i].id === panel.activePreset)
            return Options.PRESETS[i].hint + (panel.presetMatch.limitedFs
              ? ". Adapted for " + (panel.dstFs || "the drive") + ": without permissions, owners, symlinks, hard links, ACLs and xattrs"
                + (Options.isOn(panel.job.opts, "safeNames") ? ", with safe file names" : "")
              : "")
          return "Custom option set, see the Options tab"
        }
        color: panel.dim
        font.family: panel.ff
        font.pixelSize: Style.font.caption
      }
    }

    // ---- quick switches
    Grid {
      id: quick
      visible: panel.expert
      width: parent.width
      columns: 2
      columnSpacing: Style.spacing.xxl
      rowSpacing: Style.spacing.xs
      Repeater {
        model: ["delete", "update", "compress", "checksum", "partial", "hardLinks", "acls", "xattrs"]
        OptionRow {
          required property string modelData
          width: (quick.width - quick.columnSpacing) / 2
          def: Options.BY_KEY[modelData]
          effective: Options.isOn(panel.job.opts, modelData)
          implied: Options.impliedByArchive(panel.job.opts, modelData) && panel.job.opts[modelData] === undefined
          foreground: panel.fg
          fontFamily: panel.ff
          onEdited: function(v) { panel.setOpt(modelData, v) }
        }
      }
    }

    OptionRow {
      visible: panel.expert
      width: parent.width
      def: Options.BY_KEY.bwlimit
      value: panel.job.opts.bwlimit
      modified: Options.isModified(panel.job.opts, "bwlimit")
      foreground: panel.fg
      fontFamily: panel.ff
      onEdited: function(v) { panel.setOpt("bwlimit", v) }
    }

    OptionRow {
      visible: panel.expert && (panel.srcFs !== "" || panel.dstFs !== "" || Options.isOn(panel.job.opts, "safeNames"))
      width: parent.width
      def: Options.BY_KEY.safeNames
      effective: Options.isOn(panel.job.opts, "safeNames")
      modified: Options.isModified(panel.job.opts, "safeNames")
      foreground: panel.fg
      fontFamily: panel.ff
      onEdited: function(v) { panel.setOpt("safeNames", v) }
    }

    PanelSeparator { foreground: panel.fg }

    // ---- command preview
    Column {
      width: parent.width
      spacing: Style.spacing.md
      Item {
        width: parent.width
        implicitHeight: Math.max(cmdHeader.implicitHeight, copyButton.height)
        PanelSectionHeader {
          id: cmdHeader
          text: (panel.expert ? "" : (panel.showCommand ? panel.icons.chevronDown : panel.icons.chevronRight) + "  ") + "COMMAND"
          foreground: panel.fg
          fontFamily: panel.ff
          anchors.verticalCenter: parent.verticalCenter
          MouseArea {
            enabled: !panel.expert
            anchors.fill: parent
            cursorShape: enabled ? Qt.PointingHandCursor : Qt.ArrowCursor
            onClicked: panel.showCommand = !panel.showCommand
          }
        }
        PanelActionButton {
          id: copyButton
          anchors.right: parent.right
          iconText: panel.icons.copy
          tooltipText: "Copy command"
          foreground: panel.fg
          fontFamily: panel.ff
          onClicked: {
            Quickshell.execDetached(["wl-copy", "--", panel.commandText])
            panel.flash("Command copied")
          }
        }
      }
      Text {
        visible: panel.expert || panel.showCommand
        width: parent.width
        wrapMode: Text.WrapAnywhere
        textFormat: Text.PlainText
        text: panel.commandText
        color: panel.fg
        font.family: "monospace"
        font.pixelSize: Style.font.caption
      }
      Repeater {
        model: panel.blockers
        Text {
          required property string modelData
          width: jobColumn.width
          wrapMode: Text.WordWrap
          textFormat: Text.PlainText
          text: panel.icons.alert + "  " + modelData
          color: Color.urgent
          font.family: panel.ff
          font.pixelSize: Style.font.caption
        }
      }
      Repeater {
        model: panel.built.warnings.concat(Locations.fsWarnings(panel.runJob.dst, panel.runJob.opts, panel.mounts, panel.home, Options.isRemote(panel.runJob.src)))
        Text {
          required property string modelData
          width: jobColumn.width
          wrapMode: Text.WordWrap
          textFormat: Text.PlainText
          text: "•  " + modelData
          color: Color.accent
          font.family: panel.ff
          font.pixelSize: Style.font.caption
        }
      }
    }

    // ---- profiles
    Column {
      width: parent.width
      spacing: Style.spacing.md
      PanelSectionHeader { text: "PROFILES"; foreground: panel.fg; fontFamily: panel.ff }
      Row {
        width: parent.width
        spacing: Style.spacing.md
        TextField {
          id: profileField
          width: parent.width - saveProfileButton.width - parent.spacing
          placeholderText: "Name, e.g. Laptop → USB backup"
          text: panel.profileName
          foreground: panel.fg
          onAccepted: panel.saveProfile(text)
        }
        Button {
          id: saveProfileButton
          text: "Save profile"
          bordered: true
          enabled: profileField.text.trim() !== ""
          opacity: enabled ? 1 : 0.5
          foreground: panel.fg
          fontFamily: panel.ff
          height: profileField.height
          onClicked: panel.saveProfile(profileField.text)
        }
      }
      Flow {
        width: parent.width
        spacing: Style.spacing.md
        Repeater {
          model: panel.profiles
          Button {
            required property var modelData
            text: modelData.name
            tooltipText: panel.armedProfile === modelData.name ? "Right click again to delete" : "Load · right click to delete"
            bordered: true
            active: panel.profileName === modelData.name
            background: panel.armedProfile === modelData.name ? Util.alpha(Color.urgent, 0.25) : "transparent"
            foreground: panel.fg
            fontFamily: panel.ff
            fontSize: Style.font.caption
            onClicked: { panel.loadJob(modelData.job); panel.profileName = modelData.name }
            onRightClicked: {
              if (panel.armedProfile !== modelData.name) { panel.armedProfile = modelData.name; armedProfileReset.restart(); return }
              panel.armedProfile = ""
              panel.deleteProfile(modelData.name)
            }
          }
        }
      }
    }

    Item { width: 1; height: Style.spacing.md }
  }
}
