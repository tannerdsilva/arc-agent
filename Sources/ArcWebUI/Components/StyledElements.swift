import ArcTheme
import WebUI
import WebUIDesignSystem

// MARK: - Styled elements, batch one
//
// one declaration per class token written at three or more element call sites:
// a site that spelled its class as `class: .set-row` on a `Div` now names the
// type, and the token is spelled once — at the declaration — instead of at every
// site that used it. no comment in this file writes the old call shape, so a
// measurement of the tree still counts only real sites.
//
// every base class here derives from the type name (`PanelHead` -> `panel-head`,
// `PlK` -> `pl-k`), and each name was checked against its `ArcClass` raw value
// by a script rather than assumed. no declaration in this file passes `class:`:
// the inversion reproduces the token for all of them, including the
// single-letter segments (`pl-k`, `pl-v`, `dd`) that a naive splitter would
// mangle.
//
// `.set-label` is the one token at three or more sites that is *not* here. it is
// written on both `Div` (16 sites) and `Span` (1 site), and a component pins one
// tag; forcing it into either would render a different element. those 17 sites
// stay element calls until a slice decides which tag the token belongs to.
//
// a call site that also carried `id:` keeps it — the generated initializers take
// `id:` after any payload — so nothing about the emitted attributes changes.

// MARK: - Div

/// `.detail-sub` — the sub-line under a detail card's title.
@StyledElement(.div)
public struct DetailSub<Content: WebUI.View> {}

/// `.empty-hint` — the placeholder line an empty list shows.
@StyledElement(.div)
public struct EmptyHint<Content: WebUI.View> {}

/// `.panel-head` — a panel's head row, holding its title and actions.
@StyledElement(.div)
public struct PanelHead<Content: WebUI.View> {}

/// `.set-hint` — the hint line under a setting.
@StyledElement(.div)
public struct SetHint<Content: WebUI.View> {}

/// `.panel-body` — a panel's body.
@StyledElement(.div)
public struct PanelBody<Content: WebUI.View> {}

/// `.main-view` — the main column of a tab's page.
@StyledElement(.div)
public struct MainView<Content: WebUI.View> {}

/// `.row-actions-main` — the main group of a row's actions.
@StyledElement(.div)
public struct RowActionsMain<Content: WebUI.View> {}

/// `.blank` — an empty-state block.
@StyledElement(.div)
public struct Blank<Content: WebUI.View> {}

/// `.dd-list` — the list a dropdown opens.
@StyledElement(.div)
public struct DdList<Content: WebUI.View> {}

/// `.dd` — a dropdown's outer frame.
@StyledElement(.div)
public struct Dd<Content: WebUI.View> {}

/// `.form-grid` — a form's two-column grid.
@StyledElement(.div)
public struct FormGrid<Content: WebUI.View> {}

/// `.panel-actions` — the action group in a panel's head.
@StyledElement(.div)
public struct PanelActions<Content: WebUI.View> {}

/// `.pl-row` — a property line: a key beside its value.
@StyledElement(.div)
public struct PlRow<Content: WebUI.View> {}

/// `.big` — a large icon block.
@StyledElement(.div)
public struct Big<Content: WebUI.View> {}

/// `.cat-add-actions` — the add controls beside a category title.
@StyledElement(.div)
public struct CatAddActions<Content: WebUI.View> {}

/// `.ctx-tooltip-line` — a line inside the context tooltip.
@StyledElement(.div)
public struct CtxTooltipLine<Content: WebUI.View> {}

/// `.dd-empty` — the line a dropdown shows when it has no rows.
@StyledElement(.div)
public struct DdEmpty<Content: WebUI.View> {}

/// `.live-status` — the live status indicator.
@StyledElement(.div)
public struct LiveStatus<Content: WebUI.View> {}

/// `.mem-head` — a memory card's head row.
@StyledElement(.div)
public struct MemHead<Content: WebUI.View> {}

/// `.row-actions` — a row's action group.
@StyledElement(.div)
public struct RowActions<Content: WebUI.View> {}

/// `.filter-bar` — the filter bar above a list.
@StyledElement(.div)
public struct FilterBar<Content: WebUI.View> {}

/// `.row-split` — a row split into a label and its value.
@StyledElement(.div)
public struct RowSplit<Content: WebUI.View> {}

/// `.tc-detail` — the detail pane of a tool call.
@StyledElement(.div)
public struct TcDetail<Content: WebUI.View> {}

/// `.tc-label` — a label on a tool call.
@StyledElement(.div)
public struct TcLabel<Content: WebUI.View> {}

// MARK: - Span

/// `.dd-row-title` — the title line inside a dropdown row.
@StyledElement(.span)
public struct DdRowTitle<Content: WebUI.View> {}

/// `.dd-row-sub` — the secondary line of a dropdown row.
@StyledElement(.span)
public struct DdRowSub<Content: WebUI.View> {}

/// `.panel-title` — a panel's title.
@StyledElement(.span)
public struct PanelTitle<Content: WebUI.View> {}

/// `.mc-badge` — a small badge in a model-configuration row.
@StyledElement(.span)
public struct McBadge<Content: WebUI.View> {}

/// `.pl-k` — the key of a property line.
@StyledElement(.span)
public struct PlK<Content: WebUI.View> {}

/// `.pl-v` — the value of a property line.
@StyledElement(.span)
public struct PlV<Content: WebUI.View> {}

/// `.tw-caret` — the caret that opens a tree row.
@StyledElement(.span)
public struct TwCaret<Content: WebUI.View> {}

/// `.tw-spacer` — the caret-width spacer that aligns a tree row without one.
@StyledElement(.span)
public struct TwSpacer<Content: WebUI.View> {}

/// `.approval-btn-label` — the label inside an approval button.
@StyledElement(.span)
public struct ApprovalBtnLabel<Content: WebUI.View> {}

/// `.cat-dot` — the dot marking a category.
@StyledElement(.span)
public struct CatDot<Content: WebUI.View> {}

/// `.dd-model-main` — the main column of a dropdown's model row.
@StyledElement(.span)
public struct DdModelMain<Content: WebUI.View> {}

/// `.lr-name` — the name column of a list row.
@StyledElement(.span)
public struct LrName<Content: WebUI.View> {}

/// `.dd-badges` — the badges on a dropdown row.
@StyledElement(.span)
public struct DdBadges<Content: WebUI.View> {}

/// `.dd-foot-ico` — the icon on a dropdown's footer row.
@StyledElement(.span)
public struct DdFootIco<Content: WebUI.View> {}

/// `.dd-foot-txt` — the text on a dropdown's footer row.
@StyledElement(.span)
public struct DdFootTxt<Content: WebUI.View> {}

/// `.inline-err` — an inline error line.
@StyledElement(.span)
public struct InlineErr<Content: WebUI.View> {}

/// `.log-stat` — a statistic in the log panel.
@StyledElement(.span)
public struct LogStat<Content: WebUI.View> {}

/// `.lr-sub` — the secondary column of a list row.
@StyledElement(.span)
public struct LrSub<Content: WebUI.View> {}

// MARK: - Section

/// `.set-section` — a settings section.
@StyledElement(.section)
public struct SetSection<Content: WebUI.View> {}

// MARK: - Styled elements, batch two
//
// one declaration per class token written at exactly two element call sites --
// the rest of slice d, after the tokens at three or more. the derivation is
// batch one's: a declaration names the class by being named, and the macro
// inverts the type name back to the token (`ChatInner` -> `chat-inner`,
// `MmLeft` -> `mm-left`, `DdFoot` -> `dd-foot`). every name below was checked
// against its `ArcClass` raw value by a script, not assumed.
//
// two tokens need the explicit form. `FormGrid2` inverts to `form-grid2` and
// the token is `form-grid-2`; a digit segment is the one shape the inversion
// cannot reproduce, so `FormGrid2` and `FormGrid3` pass `class:` and name the
// case through `ArcClass` rather than spelling the string.
//
// no token in this batch is written on more than one tag, so each declaration
// pins the tag both of its sites used. `.set-label` is still the one token that
// spans two tags, and it stays an element call, as in batch one.

// MARK: - Div

/// `.blank-ico` — the large icon at the top of an empty state.
@StyledElement(.div)
public struct BlankIco<Content: WebUI.View> {}

/// `.blank-sub` — the explanatory line under an empty state's title.
@StyledElement(.div)
public struct BlankSub<Content: WebUI.View> {}

/// `.blank-title` — the title of an empty state.
@StyledElement(.div)
public struct BlankTitle<Content: WebUI.View> {}

/// `.cat-swatches` — the swatch strip beside a category row.
@StyledElement(.div)
public struct CatSwatches<Content: WebUI.View> {}

/// `.chat-inner` — the message column inside a chat's scroller.
@StyledElement(.div)
public struct ChatInner<Content: WebUI.View> {}

/// `.chat-scroll` — the scroller around a chat's messages.
@StyledElement(.div)
public struct ChatScroll<Content: WebUI.View> {}

/// `.dd-foot` — a dropdown's footer row.
@StyledElement(.div)
public struct DdFoot<Content: WebUI.View> {}

/// `.dd-note` — a note line under a dropdown or connector form.
@StyledElement(.div)
public struct DdNote<Content: WebUI.View> {}

/// `.dd-search` — the search box at the top of a dropdown.
@StyledElement(.div)
public struct DdSearch<Content: WebUI.View> {}

/// `.detail-body` — the body of a detail card.
@StyledElement(.div)
public struct DetailBody<Content: WebUI.View> {}

/// `.form-grid-2` — a form grid laid out in two columns.
@StyledElement(.div, class: .formGrid2)
public struct FormGrid2<Content: WebUI.View> {}

/// `.form-grid-3` — a form grid laid out in three columns.
@StyledElement(.div, class: .formGrid3)
public struct FormGrid3<Content: WebUI.View> {}

/// `.limit-row` — a key and its value in an interruption card.
@StyledElement(.div)
public struct LimitRow<Content: WebUI.View> {}

/// `.main-scroll` — the scroller of a tab's main column.
@StyledElement(.div)
public struct MainScroll<Content: WebUI.View> {}

/// `.mc-row` — a model-configuration row.
@StyledElement(.div)
public struct McRow<Content: WebUI.View> {}

/// `.mem-sep` — the rule between two memory sections.
@StyledElement(.div)
public struct MemSep<Content: WebUI.View> {}

/// `.msg-body` — a message's body.
@StyledElement(.div)
public struct MsgBody<Content: WebUI.View> {}

/// `.msg-meta` — the meta line above a message's body.
@StyledElement(.div)
public struct MsgMeta<Content: WebUI.View> {}

/// `.set-row` — a row pairing a setting's label with its control.
@StyledElement(.div)
public struct SetRow<Content: WebUI.View> {}

/// `.task-ctrl-line` — a key/value line in a scheduled task's summary.
@StyledElement(.div)
public struct TaskCtrlLine<Content: WebUI.View> {}

/// `.todo-empty` — the empty state of a todo panel.
@StyledElement(.div)
public struct TodoEmpty<Content: WebUI.View> {}

/// `.todo-empty-ico` — the icon in a todo panel's empty state.
@StyledElement(.div)
public struct TodoEmptyIco<Content: WebUI.View> {}

/// `.todo-head` — the head row of a todo panel.
@StyledElement(.div)
public struct TodoHead<Content: WebUI.View> {}

/// `.todo-head-actions` — the action group in a todo panel's head.
@StyledElement(.div)
public struct TodoHeadActions<Content: WebUI.View> {}

/// `.todo-sub` — the sub-line under a todo panel's title.
@StyledElement(.div)
public struct TodoSub<Content: WebUI.View> {}

/// `.tool-pills` — the row holding a message's tool-call cards.
@StyledElement(.div)
public struct ToolPills<Content: WebUI.View> {}

/// `.wl-detail` — the body of a work-log details row.
@StyledElement(.div)
public struct WlDetail<Content: WebUI.View> {}

/// `.ws-path` — the path line of a workspace tree row.
@StyledElement(.div)
public struct WsPath<Content: WebUI.View> {}

// MARK: - Span

/// `.dd-trigger-label` — the label inside a dropdown's trigger.
@StyledElement(.span)
public struct DdTriggerLabel<Content: WebUI.View> {}

/// `.ins-range-hint` — the parenthetical after an insights range label.
@StyledElement(.span)
public struct InsRangeHint<Content: WebUI.View> {}

/// `.limit-k` — the key of a limit row.
@StyledElement(.span)
public struct LimitK<Content: WebUI.View> {}

/// `.limit-v` — the value of a limit row.
@StyledElement(.span)
public struct LimitV<Content: WebUI.View> {}

/// `.mc-model` — the model line of a model-configuration row.
@StyledElement(.span)
public struct McModel<Content: WebUI.View> {}

/// `.mc-name` — the name of a model configuration.
@StyledElement(.span)
public struct McName<Content: WebUI.View> {}

/// `.mm-left` — the left group of a message's meta line.
@StyledElement(.span)
public struct MmLeft<Content: WebUI.View> {}

/// `.mm-right` — the right group of a message's meta line.
@StyledElement(.span)
public struct MmRight<Content: WebUI.View> {}

/// `.mm-spacer` — the spacer that pushes a message's meta groups apart.
@StyledElement(.span)
public struct MmSpacer<Content: WebUI.View> {}

/// `.msg-elapsed` — the elapsed time on a live or finished turn.
@StyledElement(.span)
public struct MsgElapsed<Content: WebUI.View> {}

/// `.msg-tps-inline` — the inline tokens-per-second reading on a message.
@StyledElement(.span)
public struct MsgTpsInline<Content: WebUI.View> {}

/// `.plug-chips` — the row of tool chips on a sidecar plugin card.
@StyledElement(.span)
public struct PlugChips<Content: WebUI.View> {}

/// `.queue-in` — the feed summary on a queue entry.
@StyledElement(.span)
public struct QueueIn<Content: WebUI.View> {}

/// `.queue-run-ico` — the icon on a queue run button.
@StyledElement(.span)
public struct QueueRunIco<Content: WebUI.View> {}

/// `.req-tag` — the required marker beside a field label.
@StyledElement(.span)
public struct ReqTag<Content: WebUI.View> {}

/// `.sess-title` — the title in a session row.
@StyledElement(.span)
public struct SessTitle<Content: WebUI.View> {}

/// `.task-ctrl-key` — the key of a scheduled task's control line.
@StyledElement(.span)
public struct TaskCtrlKey<Content: WebUI.View> {}

/// `.task-ctrl-val` — the value of a scheduled task's control line.
@StyledElement(.span)
public struct TaskCtrlVal<Content: WebUI.View> {}

/// `.tc-arg` — the argument summary of a tool call.
@StyledElement(.span)
public struct TcArg<Content: WebUI.View> {}

/// `.tc-name` — the name of a tool call.
@StyledElement(.span)
public struct TcName<Content: WebUI.View> {}

/// `.tw-label` — the label of a work-log row.
@StyledElement(.span)
public struct TwLabel<Content: WebUI.View> {}

/// `.ws-ic` — the icon of a workspace tree row.
@StyledElement(.span)
public struct WsIc<Content: WebUI.View> {}

/// `.ws-name` — the name of a workspace tree row.
@StyledElement(.span)
public struct WsName<Content: WebUI.View> {}
