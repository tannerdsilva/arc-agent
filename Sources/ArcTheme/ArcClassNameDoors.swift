import WebUICore

// the spelling doors that survive the class-parameter migration.
//
// the 312 lines this slice deleted (ArcClassElements.swift's 181,
// ArcClassInitializers.swift's 131) existed for one reason: every primitive
// took `class:` as a `String?`, so a call site writing `Div(class: .setRow)`
// had no concrete type for the leading dot to resolve against, and each
// element therefore carried a delegating `class: ArcClass` initializer. the
// primitives now take `class: ClassName?` and `ArcClassNameStatics.swift`
// gives `ClassName` one static per token, so those bridges are unreachable as
// well as redundant: with an `ArcClass` overload still present, `.setRow` would
// name both `ArcClass.setRow` and `ClassName.setRow` and every bare call site
// would be ambiguous. they are deleted, not deprecated.
//
// what remains is the one spelling the statics cannot express: several
// declared tokens in one argument.
//
// every declaration here is public because arc's call sites are spread across
// three targets; nothing else from the two deleted files survives.

extension ClassName {
	/// several declared tokens as one `ClassName`, in order:
	/// `ClassName(.iconMini, .queueLinkBtn)`.
	///
	/// the first parameter is concrete (`ArcClass`) because `.a, .b` at a call
	/// site needs a type to resolve the leading dots against — an array
	/// literal's element type is fixed by the parameter, so
	/// `ClassName([.a, .b])` would have no `ArcClass` to infer against.
	///
	/// it stays a variadic initializer rather than becoming `.addClass(...)`
	/// chaining because the argument sits inside an element's `class:`
	/// label, before the content builder — a chain cannot be placed there.
	public init(_ first: ArcClass, _ more: ArcClass...) {
		self.init(([first] + more).map(\.token).joined(separator: " "))
	}
}
