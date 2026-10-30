import WebUI

// MARK: - StorageAction

/// the storage row family: one wire identity per verb.
///
/// slot 0 is the verb and slot 1 the connection id; every slot is base64url,
/// so a row's identity reads `storage~ZWRpdA~<base64url id>`. the id rides the
/// attribute the router already routes on, which is what retires the
/// `targetId` / `dropFirst` / `storage-edit-` prefix parse the two
/// string-registered handlers shared.
enum StorageAction: Action {
	static let family = "storage"

	/// open the saved connection in the edit form.
	case edit(String)
	/// remove the saved connection.
	case delete(String)

	/// `[verb, id]` — slot 0 names the case, slot 1 carries the row.
	var parts: [ActionPart] {
		switch self {
		case .edit(let id): return [ActionPart("edit"), ActionPart(id)]
		case .delete(let id): return [ActionPart("delete"), ActionPart(id)]
		}
	}

	/// decode `storage~<verb>~<id>`; anything else — another verb, a missing
	/// slot, a payload that is not base64url utf8 — is not this type's frame.
	init?(key: ActionKey, event: EventData) {
		guard key.family == Self.family, key.parts.count == 2,
		      let verb = key.parts[0].decoded,
		      let id = key.parts[1].decoded
		else { return nil }
		switch verb {
		case "edit": self = .edit(id)
		case "delete": self = .delete(id)
		default: return nil
		}
	}
}
