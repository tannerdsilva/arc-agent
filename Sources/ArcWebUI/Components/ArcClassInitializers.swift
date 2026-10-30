import ArcTheme
import WebUI
import WebUIDesignSystem

// the delegating initializers for arc's own components — the half of the
// `ArcClass` vocabulary that cannot live in `ArcTheme`, because these types are
// arc's and the theme target sits *below* them in the dependency graph.
//
// same contract as `ArcClassElements.swift`: a concrete `ArcClass` parameter so
// leading-dot inference works, and a delegation to each type's real initializer
// so the renderer stays the one that already exists.

// MARK: - ArcButton

extension ArcButton where Views == EmptyView {
	/// `ArcButton("Apply", id: "queue-link-apply", component: nil, class: .primaryBtn)`.
	///
	/// `ArcButton.class` is a `String` with no default — the macro generates the
	/// parameter from the stored property — so this initializer has to carry it
	/// through rather than drop it.
	public init(
		_ label: String,
		id: String? = nil,
		component: String? = nil,
		routing: ComponentID? = nil,
		class css: ArcClass,
		type: ButtonType = .button,
		tabIndex: Int? = nil,
		disabled: Bool = false,
		hidden: Bool = false
	) {
		self.init(
			label, id: id, component: component, routing: routing,
			class: css.token, type: type, tabIndex: tabIndex,
			disabled: disabled, hidden: hidden
		)
	}
}

extension ArcButton {
	/// the view-builder reading: `ArcButton(id: "x", class: .iconMini) { … }`.
	public init(
		id: String? = nil,
		component: String? = nil,
		routing: ComponentID? = nil,
		class css: ArcClass,
		type: ButtonType = .button,
		tabIndex: Int? = nil,
		disabled: Bool = false,
		hidden: Bool = false,
		@ElementBuilder views: () -> Views
	) {
		self.init(
			id: id, component: component, routing: routing,
			class: css.token, type: type, tabIndex: tabIndex,
			disabled: disabled, hidden: hidden, views: views
		)
	}
}

// MARK: - FieldLabel

extension FieldLabel {
	/// `FieldLabel(.auxLabel) { … }` — the label wraps its control.
	public init(_ css: ArcClass, @ElementBuilder content: () -> Content) {
		self.init(class: css.token, content: content)
	}

	/// the label the type already takes: `FieldLabel(class: .auxLabel) { … }`.
	public init(class css: ArcClass, @ElementBuilder content: () -> Content) {
		self.init(class: css.token, content: content)
	}
}

// MARK: - DetailTitle

extension DetailTitle {
	/// `DetailTitle("Settings", icon: .gear, class: .wide)` — the third parameter
	/// is the extra class the title appends after its own `detail-title`.
	public init(_ text: String, icon: IconName? = nil, class css: ArcClass) {
		self.init(text, icon: icon, class: css.token)
	}
}

// the multi-token reading: `class: ClassName(.iconMini, .queueLinkBtn)`.
//
// a multi-class value cannot go through the `ArcClass` parameter (one case is
// one token), and it cannot be chained onto the call either — `.addClass(...)`
// would have to sit after the content builder, which a mechanical migration
// cannot place reliably. the `ClassName` parameter is the seam: the call site
// names cases, the type carries the joined text.

extension ArcButton where Views == EmptyView {
	public init(
		_ label: String,
		id: String? = nil,
		component: String? = nil,
		routing: ComponentID? = nil,
		class css: ClassName,
		type: ButtonType = .button,
		tabIndex: Int? = nil,
		disabled: Bool = false,
		hidden: Bool = false
	) {
		self.init(
			label, id: id, component: component, routing: routing,
			class: css.value, type: type, tabIndex: tabIndex,
			disabled: disabled, hidden: hidden
		)
	}
}

extension ArcButton {
	public init(
		id: String? = nil,
		component: String? = nil,
		routing: ComponentID? = nil,
		class css: ClassName,
		type: ButtonType = .button,
		tabIndex: Int? = nil,
		disabled: Bool = false,
		hidden: Bool = false,
		@ElementBuilder views: () -> Views
	) {
		self.init(
			id: id, component: component, routing: routing,
			class: css.value, type: type, tabIndex: tabIndex,
			disabled: disabled, hidden: hidden, views: views
		)
	}
}
