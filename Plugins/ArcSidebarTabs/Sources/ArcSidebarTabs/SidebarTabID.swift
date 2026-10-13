import Foundation

// MARK: - SidebarTabID

/// Validation for sidebar tab ids.
///
/// A tab id is a stable slug used for the rail button (`nav-<id>`), the
/// event-component prefixes, and persisted settings. Restricting the
/// shape keeps all of those interactions unambiguous and makes it
/// impossible for a tab id to collide with the host's own component ids.
public enum SidebarTabID {

    /// The id shape: lowercase letters, digits, and single hyphens;
    /// must start with a letter or digit; at most 48 characters.
    public static func isValid(_ id: String) -> Bool {
        guard !id.isEmpty, id.count <= 48 else { return false }
        guard let first = id.first, first.isLowercase || first.isNumber else { return false }
        for ch in id {
            guard ch.isLowercase || ch.isNumber || ch == "-" else { return false }
        }
        guard !id.contains("--") else { return false }
        return id.first != "-" && id.last != "-"
    }
}
