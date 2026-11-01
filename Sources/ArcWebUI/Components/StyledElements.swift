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
