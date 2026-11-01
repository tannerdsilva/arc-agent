#!/usr/bin/env python3
"""generate Sources/ArcTheme/ArcClassNameStatics.swift from ArcClass.swift.

one `public static var` per ArcClass case, each returning the case's token as a
ClassName, named exactly the case's swift name. the case list is the sheet's
vocabulary (ArcClass.swift), so the statics are a projection of it and never a
second list to keep in sync.

usage: python3 Scripts/gen-classname-statics.py [repo-root]
"""
import re
import sys

REPO = sys.argv[1] if len(sys.argv) > 1 else "."
SRC = f"{REPO}/Sources/ArcTheme/ArcClass.swift"
OUT = f"{REPO}/Sources/ArcTheme/ArcClassNameStatics.swift"

# names that cannot stand bare in a declaration. `open` and `switch` are already
# backticked in ArcClass.swift; the rest would only bite a future case, so the
# generator backticks anything that is not a plain non-keyword identifier.
KEYWORDS = set("""
associatedtype class deinit enum extension fileprivate func import init inout
internal let open operator private protocol public rethrows static struct
subscript typealias var break case continue default defer do else fallthrough
for guard if in repeat return switch where while as Any catch false is nil
super self Self throw throws true try _ async await actor some any each
""".split())

CASE_RE = re.compile(r'^\tcase (`?)([A-Za-z_][A-Za-z0-9_]*)\1 = "([^"]*)"$')

HEADER = """import WebUICore

/// every `ArcClass` case as a `ClassName`, so a `class:` argument can be
/// spelled `.setRow` without the element carrying a bridge initializer.
///
/// generated, not typed: one `public static var` per case in `ArcClass.swift`,
/// named exactly the case's swift name and returning that case's token
/// (`ClassName(ArcClass.setRow.token)`). the case list is the sheet's
/// vocabulary, so the two files move together; regenerate with
/// `Scripts/gen-classname-statics.py` after any `ArcClass` change, and never
/// hand-edit a static.
///
/// this is why the 312 bridge lines in `ArcClassElements.swift` and
/// `ArcClassInitializers.swift` could go: `ClassName` is the element's `class:`
/// parameter type, and leading-dot spelling resolves against these members
/// instead of against a concrete `ArcClass` parameter added per element.
///
/// two case names are keywords (`open`, `switch`) and are declared backticked,
/// exactly as `ArcClass` declares them."""


def main() -> int:
    text = open(SRC, encoding="utf-8").read()
    cases = []
    for line in text.split("\n"):
        m = CASE_RE.match(line)
        if m:
            cases.append((m.group(2), m.group(3)))
    if not cases:
        sys.exit("no cases parsed -- refusing to write an empty file")

    seen = set()
    for name, _ in cases:
        if name in seen:
            sys.exit(f"duplicate case name {name}")
        seen.add(name)

    def ident(name: str) -> str:
        return name if name.isidentifier() and name not in KEYWORDS else f"`{name}`"

    out = [HEADER, "", "extension ClassName {"]
    for name, _tok in cases:
        out.append(f"\tpublic static var {ident(name)}: ClassName {{ ClassName(ArcClass.{ident(name)}.token) }}")
    out.append("}")
    out.append("")

    open(OUT, "w", encoding="utf-8").write("\n".join(out))
    statics = sum(1 for line in out if line.startswith("\tpublic static var"))
    print(f"cases: {len(cases)}")
    print(f"statics: {statics}")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
