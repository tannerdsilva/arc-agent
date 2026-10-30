import WebUI

// the delegating initializers that let a call site name a class by its case
// instead of its spelling: `Div(.setRow)` rather than `Div(class: "set-row")`.
//
// the parameter is `ArcClass`, a concrete type, and that is load-bearing:
// leading-dot inference needs one, and a `some CSSClass` parameter cannot
// provide it (measured, not a preference — the generic form fails to infer).
//
// every initializer delegates to the type's own `class:` initializer rather
// than assigning the property itself: a cross-module initializer may not touch
// a `let` stored property. delegating also keeps one renderer, so the bytes
// `Div(.setRow)` emits are the bytes `Div(class: "set-row")` emits — a test
// can compare the two and find no difference.
//
// `Div` and `Span` carry both readings because they are the overwhelming bulk
// of the call sites: the unlabeled form the plan specifies (`Div(.setRow)`) and
// a label-preserving one (`Div(class: .setRow)`) so a mechanical migration can
// leave the argument where it sits. every other type takes only the
// label-preserving form, positioned where that type's real `class:` parameter
// sits — `Element` takes `class:` after its tag, `Heading` after its level, and
// so on; the real signatures, not this list, decide.

// MARK: - Container elements

extension Div {
	/// `Div(.setRow) { … }` — the plan's spelling.
	public init(_ css: ArcClass, id: String? = nil, @ElementBuilder content: () -> Content) {
		self.init(id: id, class: css.token, content: content)
	}

	/// `Div(class: .setRow) { … }` — the label the element already takes.
	public init(id: String? = nil, class css: ArcClass, @ElementBuilder content: () -> Content) {
		self.init(id: id, class: css.token, content: content)
	}
}

extension Span {
	/// `Span(.queueStatus) { … }`.
	public init(_ css: ArcClass, id: String? = nil, @ElementBuilder content: () -> Content) {
		self.init(id: id, class: css.token, content: content)
	}

	/// `Span(class: .queueStatus) { … }`.
	public init(id: String? = nil, class css: ArcClass, @ElementBuilder content: () -> Content) {
		self.init(id: id, class: css.token, content: content)
	}
}

extension Section {
	public init(id: String? = nil, class css: ArcClass, @ElementBuilder content: () -> Content) {
		self.init(id: id, class: css.token, content: content)
	}
}

extension Header {
	public init(class css: ArcClass, @ElementBuilder content: () -> Content) {
		self.init(class: css.token, content: content)
	}
}

extension Element {
	/// `Element(.div, class: .setRow) { … }` — the tag stays the first argument.
	public init(_ tag: Tag, class css: ArcClass, id: String? = nil, @ElementBuilder content: () -> Content) {
		self.init(tag, class: css.token, id: id, content: content)
	}
}

// MARK: - Form

extension Form {
	/// the full parameter list, so a form that already names `action:`/`method:`
	/// keeps naming them — only `class:` changes type.
	public init(
		action: String = "",
		method: FormMethod? = .post,
		enctype: String = "",
		id: String? = nil,
		class css: ArcClass,
		csrfToken: String? = nil,
		@ElementBuilder content: () -> Content
	) {
		self.init(
			action: action, method: method, enctype: enctype, id: id,
			class: css.token, csrfToken: csrfToken, content: content
		)
	}
}

// MARK: - Text-bearing elements
//
// these take their text first, so the class stays where the type already puts
// it: labeled, after the content.

extension Heading {
	public init(_ text: String, level: HeadingLevel = .h1, class css: ArcClass) {
		self.init(text, level: level, class: css.token)
	}
}

extension Label {
	public init(_ text: String, for: String? = nil, class css: ArcClass) {
		self.init(text, for: `for`, class: css.token)
	}
}

extension Link {
	public init(_ text: String, href: String, class css: ArcClass, target: LinkTarget? = nil, rel: LinkRel? = nil) {
		self.init(text, href: href, class: css.token, target: target, rel: rel)
	}
}

// MARK: - View

extension View {
	/// add several declared classes at once: `.classes(.setRow, .active)`.
	///
	/// overloads the framework's `ClassName` variadic rather than replacing it;
	/// the literal spelling still compiles, and a zero-argument `.classes()` now
	/// has two candidates — no call site in this tree writes that, and the
	/// migration slice is where the literal form goes away.
	public func classes(_ names: ArcClass...) -> ModifiedView<Self, HTMLAttribute> {
		addClass(ClassName(names))
	}

	/// the singular reading: `.addClass(.detailTitle)`.
	public func addClass(_ name: ArcClass) -> ModifiedView<Self, HTMLAttribute> {
		addClass(ClassName(name))
	}
}

// MARK: - Multi-token class lists

extension ClassName {
	/// several declared tokens as one `ClassName`, in order.
	///
	/// the first parameter is concrete for the same reason every initializer
	/// above is: `.a, .b` at a call site needs a type to resolve the leading
	/// dots against. the framework's `[any CSSClass]` initializer cannot do it —
	/// an array literal's element type is the existential, and
	/// `ClassName([.a, .b])` fails to infer.
	public init(_ first: ArcClass, _ more: ArcClass...) {
		self.init([first] + more)
	}
}

// MARK: - Container types, multi-token form
//
// `Div(class: .a)` covers one token. a multi-class value needs a `ClassName`
// parameter to carry the joined text, and it must be a *separate* overload
// rather than a second spelling of the same parameter: `ArcClass` and
// `ClassName` are distinct types, and a call site with two cases is not one
// class. the label stays `class:` so a migration never moves the argument.

extension Div {
	public init(id: String? = nil, class css: ClassName, @ElementBuilder content: () -> Content) {
		self.init(id: id, class: css.value, content: content)
	}
}

extension Span {
	public init(id: String? = nil, class css: ClassName, @ElementBuilder content: () -> Content) {
		self.init(id: id, class: css.value, content: content)
	}
}

extension Form {
	public init(
		action: String = "",
		method: FormMethod? = .post,
		enctype: String = "",
		id: String? = nil,
		class css: ClassName,
		csrfToken: String? = nil,
		@ElementBuilder content: () -> Content
	) {
		self.init(
			action: action, method: method, enctype: enctype,
			id: id, class: css.value, csrfToken: csrfToken, content: content
		)
	}
}
