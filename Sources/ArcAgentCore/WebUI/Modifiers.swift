import Foundation

// MARK: - View Modifier Methods

extension View {

    // MARK: - Background & Foreground

    /// Set the background color of this view.
    /// - Parameter color: A CSS color value.
    /// - Returns: A modified view with the background color applied.
    public func backgroundColor(_ color: String) -> ModifiedView<Self> {
        ModifiedView(content: self, modifier: InlineStyle("background-color", color))
    }

    /// Set the text color of this view.
    /// - Parameter color: A CSS color value.
    /// - Returns: A modified view with the foreground color applied.
    public func foregroundColor(_ color: String) -> ModifiedView<Self> {
        ModifiedView(content: self, modifier: InlineStyle("color", color))
    }

    // MARK: - Typography

    /// Set the font size and weight of this view.
    /// - Parameters:
    ///   - size: Font size in pixels.
    ///   - weight: Font weight (e.g. `"normal"`, `"bold"`, `"600"`).
    /// - Returns: A modified view with the font styling applied.
    public func font(size: Int, weight: String = "normal") -> ModifiedView<Self> {
        let first = InlineStyle("font-size", "\(size)px")
        let second = InlineStyle("font-weight", weight)
        return ModifiedView(content: self, modifier: ComposedModifier(first: first, second: second))
    }

    /// Set the font family of this view.
    /// - Parameter family: A CSS font-family value.
    /// - Returns: A modified view with the font family applied.
    public func fontFamily(_ family: String) -> ModifiedView<Self> {
        ModifiedView(content: self, modifier: InlineStyle("font-family", family))
    }

    /// Set the text alignment of this view.
    /// - Parameter alignment: A CSS text-align value.
    /// - Returns: A modified view with the text alignment applied.
    public func textAlign(_ alignment: String) -> ModifiedView<Self> {
        ModifiedView(content: self, modifier: InlineStyle("text-align", alignment))
    }

    // MARK: - Spacing

    /// Add padding around this view on all sides.
    /// - Parameter all: Padding in pixels.
    /// - Returns: A modified view with padding applied.
    public func padding(_ all: Int) -> ModifiedView<Self> {
        ModifiedView(content: self, modifier: InlineStyle("padding", "\(all)px"))
    }

    /// Add padding around this view with different values per axis.
    /// - Parameters:
    ///   - horizontal: Horizontal padding in pixels.
    ///   - vertical: Vertical padding in pixels.
    /// - Returns: A modified view with padding applied.
    public func padding(horizontal: Int, vertical: Int) -> ModifiedView<Self> {
        ModifiedView(
            content: self,
            modifier: InlineStyle("padding", "\(vertical)px \(horizontal)px")
        )
    }

    /// Add margin around this view on all sides.
    /// - Parameter all: Margin in pixels.
    /// - Returns: A modified view with margin applied.
    public func margin(_ all: Int) -> ModifiedView<Self> {
        ModifiedView(content: self, modifier: InlineStyle("margin", "\(all)px"))
    }

    // MARK: - Dimensions

    /// Set the width of this view.
    /// - Parameter width: A CSS width value (e.g. `"100%"`, `"200px"`).
    /// - Returns: A modified view with the width applied.
    public func width(_ width: String) -> ModifiedView<Self> {
        ModifiedView(content: self, modifier: InlineStyle("width", width))
    }

    /// Set the height of this view.
    /// - Parameter height: A CSS height value (e.g. `"100%"`, `"200px"`).
    /// - Returns: A modified view with the height applied.
    public func height(_ height: String) -> ModifiedView<Self> {
        ModifiedView(content: self, modifier: InlineStyle("height", height))
    }

    /// Set the maximum width of this view.
    /// - Parameter width: A CSS max-width value.
    /// - Returns: A modified view with the max-width applied.
    public func maxWidth(_ width: String) -> ModifiedView<Self> {
        ModifiedView(content: self, modifier: InlineStyle("max-width", width))
    }

    // MARK: - Layout

    /// Set the display property of this view.
    /// - Parameter display: A CSS display value (e.g. `"none"`, `"flex"`).
    /// - Returns: A modified view with the display property applied.
    public func display(_ display: String) -> ModifiedView<Self> {
        ModifiedView(content: self, modifier: InlineStyle("display", display))
    }

    /// Set the CSS `flex` property of this view.
    /// - Parameter flex: A CSS flex value (e.g. `"1"`, `"0 0 auto"`).
    /// - Returns: A modified view with the flex property applied.
    public func flex(_ flex: String) -> ModifiedView<Self> {
        ModifiedView(content: self, modifier: InlineStyle("flex", flex))
    }

    // MARK: - Borders

    /// Set the border of this view.
    /// - Parameter border: A CSS border value (e.g. `"1px solid #30363d"`).
    /// - Returns: A modified view with the border applied.
    public func border(_ border: String) -> ModifiedView<Self> {
        ModifiedView(content: self, modifier: InlineStyle("border", border))
    }

    /// Set the border radius of this view.
    /// - Parameter radius: A CSS border-radius value.
    /// - Returns: A modified view with the border radius applied.
    public func cornerRadius(_ radius: String) -> ModifiedView<Self> {
        ModifiedView(content: self, modifier: InlineStyle("border-radius", radius))
    }

    // MARK: - Visibility

    /// Conditionally show or hide this view.
    /// - Parameter condition: If `true`, the view is shown; if `false`, hidden.
    /// - Returns: The view unchanged when shown, or wrapped with `display: none` when hidden.
    public func showIf(_ condition: Bool) -> ModifiedView<Self> {
        ModifiedView(
            content: self,
            modifier: condition ? NoopModifier() : InlineStyle("display", "none")
        )
    }

    // MARK: - HTML Attributes

    /// Set the HTML `id` attribute of this view.
    /// - Parameter id: The id value.
    /// - Returns: A modified view with the id attribute.
    public func id(_ id: String) -> ModifiedView<Self> {
        ModifiedView(content: self, modifier: HTMLAttribute("id", id))
    }

    /// Add CSS class names to this view.
    /// - Parameter name: The class value.
    /// - Returns: A modified view with the class attribute.
    public func `class`(_ name: String) -> ModifiedView<Self> {
        ModifiedView(content: self, modifier: HTMLAttribute("class", name))
    }
}
