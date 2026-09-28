import Foundation

// MARK: - Project tools (Hermes `tools/project_tools.py`)

/// Tool: `project_list` — list projects and the active one.
public enum ProjectListTool {
    public static let entry = ToolEntry(
        name: "project_list",
        toolset: "project",
        description: "List the named workspaces (projects) and which one is active.",
        schema: .object(description: "Project list", properties: [:], required: []),
        handler: { _ in
            let store = ProjectStore()
            do {
                let projects = try await store.list()
                let active = try await store.active()
                var list: [[String: Any]] = []
                for p in projects {
                    list.append([
                        "id": p.id,
                        "slug": p.slug,
                        "name": p.name,
                        "primary_path": p.primaryPath ?? "",
                        "active": p.id == active?.id,
                    ])
                }
                return JSONShim.string(from: [
                    "active_id": active?.id ?? "",
                    "projects": list,
                ])
            } catch {
                return "Error: \(error)"
            }
        },
        emoji: "🗂️"
    )
}

/// Tool: `project_create` — create a project and switch into it.
public enum ProjectCreateTool {
    public static let entry = ToolEntry(
        name: "project_create",
        toolset: "project",
        description: "Create a named workspace (project) and switch this chat into it. "
            + "Pass `path` to anchor it to a folder — this chat's workspace moves there. "
            + "Use when starting work in a new repo/folder; this is the intentional way "
            + "to move the session, not `cd`.",
        schema: .object(
            description: "Project create parameters",
            properties: [
                "name": .string(description: "Human name, e.g. 'Aurora Demo'"),
                "path": .string(description: "Primary repo/folder to anchor the project to"),
            ],
            required: ["name"]
        ),
        handler: { args in
            let name = (args["name"] as? String) ?? ""
            let path = args["path"] as? String
            let store = ProjectStore()
            do {
                let p = try await store.create(name: name, path: path)
                return JSONShim.string(from: [
                    "success": true,
                    "id": p.id,
                    "slug": p.slug,
                    "name": p.name,
                    "primary_path": p.primaryPath ?? "",
                ])
            } catch let e as ProjectError {
                return JSONShim.string(from: ["success": false, "error": e.description])
            } catch {
                return "Error: \(error)"
            }
        },
        emoji: "🌱"
    )
}

/// Tool: `project_switch` — switch into an existing project.
public enum ProjectSwitchTool {
    public static let entry = ToolEntry(
        name: "project_switch",
        toolset: "project",
        description: "Switch this chat into an existing project (by name, slug, or id). "
            + "Moves the session's workspace to the project's primary folder. "
            + "The intentional way to move between projects, not `cd`.",
        schema: .object(
            description: "Project switch parameters",
            properties: [
                "project": .string(description: "Project name, slug, or id"),
            ],
            required: ["project"]
        ),
        handler: { args in
            let token = (args["project"] as? String) ?? ""
            let store = ProjectStore()
            do {
                let p = try await store.switchTo(token: token)
                return JSONShim.string(from: [
                    "success": true,
                    "id": p.id,
                    "slug": p.slug,
                    "name": p.name,
                    "primary_path": p.primaryPath ?? "",
                ])
            } catch let e as ProjectError {
                return JSONShim.string(from: ["success": false, "error": e.description])
            } catch {
                return "Error: \(error)"
            }
        },
        emoji: "🔀"
    )
}

/// Small JSON helper shared by tool responses.
enum JSONShim {
    static func string(from object: [String: Any]) -> String {
        guard let data = try? JSONSerialization.data(withJSONObject: object, options: [.sortedKeys]),
              let text = String(data: data, encoding: .utf8) else {
            return "{}"
        }
        return text
    }
}
