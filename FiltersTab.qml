import QtQuick
import QtQuick.Controls as QQC
import qs.Commons
import qs.Ui
import "Options.js" as Options

// Filters tab: the job's filter rules in order, quick excludes, and the
// catalog options that belong to filtering. Stateless like the other tabs:
// everything is read from and written back to `panel.job`.
Flickable {
  id: filtersPage

  required property var panel
  contentHeight: filtersColumn.implicitHeight
  clip: true
  boundsBehavior: Flickable.StopAtBounds
  QQC.ScrollBar.vertical: QQC.ScrollBar { policy: filtersPage.contentHeight > filtersPage.height ? QQC.ScrollBar.AlwaysOn : QQC.ScrollBar.AlwaysOff }

  function setRules(list) { panel.patchJob({ filters: list }) }
  function updateRule(i, changes) {
    var list = panel.job.filters.slice()
    list[i] = Object.assign({}, list[i], changes)
    setRules(list)
  }
  function moveRule(i, d) {
    var list = panel.job.filters.slice()
    var j = i + d
    if (j < 0 || j >= list.length) return
    var t = list[i]; list[i] = list[j]; list[j] = t
    setRules(list)
  }

  Column {
    id: filtersColumn
    width: filtersPage.width - Style.spacing.xl
    spacing: Style.spacing.lg

    PanelSectionHeader { text: "RULES"; foreground: panel.fg; fontFamily: panel.ff }
    Text {
      width: parent.width
      wrapMode: Text.WordWrap
      textFormat: Text.PlainText
      text: "Checked top to bottom, the first matching rule wins. Patterns: * any name part, ** across folders, a trailing / matches only folders, a leading / anchors at the source root. Include rules need their parent folders included too (e.g. + */ before - *)."
      color: panel.dim
      font.family: panel.ff
      font.pixelSize: Style.font.caption
    }

    Repeater {
      model: panel.job.filters
      Row {
        required property var modelData
        required property int index
        width: filtersColumn.width
        spacing: Style.spacing.md
        Dropdown {
          id: ruleType
          showLabel: false
          width: Style.space(120)
          foreground: panel.fg
          fontFamily: panel.ff
          value: modelData.type
          options: Options.FILTER_TYPES
          onChanged: function(v) { filtersPage.updateRule(index, { type: v }) }
        }
        TextField {
          width: parent.width - ruleType.width - Style.space(28) * 3 - parent.spacing * 4
          height: ruleType.height
          verticalPadding: Style.spacing.xs
          text: modelData.pattern || ""
          enabled: modelData.type !== "clear"
          placeholderText: modelData.type === "merge" || modelData.type === "dir-merge" ? "rules file" : "pattern, e.g. *.tmp or node_modules/"
          foreground: panel.fg
          font.family: "monospace"
          onTextEdited: filtersPage.updateRule(index, { pattern: text })
        }
        PanelActionButton { iconText: panel.icons.up; size: Style.space(28); foreground: panel.fg; fontFamily: panel.ff; tooltipText: "Move up"; onClicked: filtersPage.moveRule(index, -1) }
        PanelActionButton { iconText: panel.icons.down; size: Style.space(28); foreground: panel.fg; fontFamily: panel.ff; tooltipText: "Move down"; onClicked: filtersPage.moveRule(index, 1) }
        PanelActionButton {
          iconText: panel.icons.trash; size: Style.space(28); foreground: panel.fg; fontFamily: panel.ff; tooltipText: "Remove"
          onClicked: { var l = panel.job.filters.slice(); l.splice(index, 1); filtersPage.setRules(l) }
        }
      }
    }

    Flow {
      width: parent.width
      spacing: Style.spacing.md
      Button {
        text: "Add rule"
        iconText: panel.icons.plus
        bordered: true
        foreground: panel.fg
        fontFamily: panel.ff
        onClicked: filtersPage.setRules(panel.job.filters.concat([{ type: "exclude", pattern: "" }]))
      }
      Repeater {
        model: [".git/", "node_modules/", ".cache/", "*.tmp", "*~", ".Trash-*/", "lost+found/", ".DS_Store"]
        Button {
          required property string modelData
          text: "− " + modelData
          tooltipText: "Exclude " + modelData
          bordered: true
          foreground: panel.fg
          fontFamily: panel.ff
          fontSize: Style.font.caption
          visible: !panel.job.filters.some(function(f) { return f.type === "exclude" && f.pattern === modelData })
          onClicked: filtersPage.setRules(panel.job.filters.concat([{ type: "exclude", pattern: modelData }]))
        }
      }
    }

    PanelSeparator { foreground: panel.fg }
    PanelSectionHeader { text: "FILTER OPTIONS"; foreground: panel.fg; fontFamily: panel.ff }

    Repeater {
      model: Options.CATALOG.filter(function(d) { return d.group === "filters" }).concat([Options.BY_KEY.deleteExcluded])
      OptionRow {
        required property var modelData
        width: filtersColumn.width
        def: modelData
        value: panel.job.opts[modelData.key]
        effective: Options.isOn(panel.job.opts, modelData.key)
        modified: Options.isModified(panel.job.opts, modelData.key)
        foreground: panel.fg
        fontFamily: panel.ff
        onEdited: function(v) { panel.setOpt(modelData.key, v) }
        onBrowse: function(mode) { panel.browse(modelData.key, mode) }
      }
    }
  }
}
