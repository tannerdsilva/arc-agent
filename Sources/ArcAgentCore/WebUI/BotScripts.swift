import Foundation

// MARK: - Bot Mode JavaScript

/// Extended JavaScript runtime for the Bot Mode web UI.
///
/// This is appended to the base `Scripts.runtime` JS when bot mode is active.
/// It provides:
/// - Bot selection and chat switching
/// - Bot search filtering
/// - New Agent dialog
/// - New Routine dialog
/// - Group chat navigation
/// - @mention autocomplete
///
/// ## Design
///
/// Like `Scripts.runtime`, this is a static string embedded in the binary.
/// No external files, no build step, no npm.
extension Scripts {

    /// The bot mode JavaScript runtime.
    public static let botMode = """
    (function(){
      // ── Bot Selection ──────────────────────────────────────
      window.selectBot = function(name) {
        var ws = window.__ws;
        if (ws && ws.readyState === WebSocket.OPEN) {
          ws.send(JSON.stringify({type: 'select_bot', bot: name}));
        }
        // Update active state in roster
        document.querySelectorAll('.bot-row').forEach(function(row) {
          row.classList.toggle('active', row.dataset.bot === name);
        });
      };

      // ── Bot Search ─────────────────────────────────────────
      window.filterBots = function(query) {
        var q = query.toLowerCase().trim();
        document.querySelectorAll('.bot-row').forEach(function(row) {
          var name = (row.dataset.bot || '').toLowerCase();
          var text = row.textContent.toLowerCase();
          row.style.display = (!q || name.includes(q) || text.includes(q)) ? '' : 'none';
        });
        // Hide empty groups
        document.querySelectorAll('.group-header').forEach(function(header) {
          var next = header.nextElementSibling;
          var visible = false;
          while (next && next.classList.contains('bot-row')) {
            if (next.style.display !== 'none') { visible = true; break; }
            next = next.nextElementSibling;
          }
          header.style.display = (!q || visible) ? '' : 'none';
        });
      };

      // ── New Agent Dialog ───────────────────────────────────
      window.openNewAgentDialog = function() {
        var existing = document.getElementById('new-agent-dialog');
        if (existing) { existing.style.display = ''; return; }
        var div = document.createElement('div');
        div.id = 'new-agent-dialog';
        div.innerHTML = `\(newAgentDialogHTML())`;
        document.body.appendChild(div);
      };

      window.closeNewAgentDialog = function() {
        var el = document.getElementById('new-agent-dialog');
        if (el) el.style.display = 'none';
      };

      window.createAgent = function(event) {
        event.preventDefault();
        var name = document.getElementById('agent-name').value.trim();
        var title = document.getElementById('agent-title').value.trim();
        var desc = document.getElementById('agent-desc').value.trim();
        var clone = document.getElementById('agent-clone').value.trim();
        var model = document.getElementById('agent-model').value.trim();
        var provider = document.getElementById('agent-provider').value.trim();
        var group = document.getElementById('agent-group').value.trim();

        var ws = window.__ws;
        if (ws && ws.readyState === WebSocket.OPEN) {
          ws.send(JSON.stringify({
            type: 'create_agent',
            name: name,
            title: title,
            description: desc,
            clone_from: clone || undefined,
            model: model || undefined,
            provider: provider || undefined,
            group: group || undefined
          }));
        }
        closeNewAgentDialog();
      };

      // ── New Routine Dialog ─────────────────────────────────
      window.openNewRoutineDialog = function() {
        var existing = document.getElementById('new-routine-dialog');
        if (existing) { existing.style.display = ''; return; }
        var div = document.createElement('div');
        div.id = 'new-routine-dialog';
        div.innerHTML = `\(newRoutineDialogHTML())`;
        document.body.appendChild(div);
      };

      window.closeNewRoutineDialog = function() {
        var el = document.getElementById('new-routine-dialog');
        if (el) el.style.display = 'none';
      };

      window.createRoutine = function(event) {
        event.preventDefault();
        var schedule = document.getElementById('routine-schedule').value.trim();
        var prompt = document.getElementById('routine-prompt').value.trim();

        var ws = window.__ws;
        if (ws && ws.readyState === WebSocket.OPEN) {
          ws.send(JSON.stringify({
            type: 'create_routine',
            schedule: schedule,
            prompt: prompt
          }));
        }
        closeNewRoutineDialog();
      };

      // ── Group Chat ─────────────────────────────────────────
      window.openGroupChat = function(group) {
        var ws = window.__ws;
        if (ws && ws.readyState === WebSocket.OPEN) {
          ws.send(JSON.stringify({type: 'open_group_chat', group: group}));
        }
      };

      // ── @mention Autocomplete ──────────────────────────────
      var mentionTimer = null;
      document.addEventListener('keydown', function(e) {
        if (e.key === 'Enter' && !e.shiftKey) {
          var input = document.getElementById('message-input');
          if (!input) return;
          var text = input.value;
          // Check for @mentions
          var match = text.match(/@([a-z0-9_-]*)$/i);
          if (match) {
            // Let the server handle @mentions via the middleware
          }
        }
      });

      // ── Handle Bot-Specific Messages ───────────────────────
      var origOnMessage = window.__ws.onmessage;
      window.__ws.onmessage = function(e) {
        try {
          var msg = JSON.parse(e.data);
          switch (msg.type) {
            case 'roster_update':
              // Roster was updated (agent created/deleted) — reload
              if (msg.reload) { location.reload(); }
              break;
            case 'bot_activity':
              // Update the active now strip
              var strip = document.querySelector('.active-now-strip');
              if (strip && msg.bots) {
                // In a full implementation, this would update the strip dynamically
              }
              break;
            default:
              if (origOnMessage) origOnMessage(e);
          }
        } catch {
          if (origOnMessage) origOnMessage(e);
        }
      };
    })();
    """

    /// HTML for the New Agent dialog (inlined in JS).
    private static func newAgentDialogHTML() -> String {
        """
        <div class="dialog-overlay" onclick="closeNewAgentDialog()">
          <div class="dialog-content" onclick="event.stopPropagation()">
            <div class="dialog-title">New Agent</div>
            <form onsubmit="createAgent(event)">
              <label class="form-label">Name</label>
              <input class="form-input" id="agent-name" type="text" placeholder="e.g. researcher" required pattern="[a-z0-9][a-z0-9_-]{1,63}">

              <label class="form-label">Title</label>
              <input class="form-input" id="agent-title" type="text" placeholder="e.g. Research Analyst">

              <label class="form-label">Description</label>
              <textarea class="form-textarea" id="agent-desc" placeholder="What does this agent do?"></textarea>

              <details style="margin-bottom: 12px;">
                <summary style="font-size: 12px; color: var(--text-secondary); cursor: pointer;">Advanced</summary>
                <div style="margin-top: 8px;">
                  <label class="form-label">Clone from</label>
                  <input class="form-input" id="agent-clone" type="text" placeholder="Existing profile name (optional)">
                  <label class="form-label">Model override</label>
                  <input class="form-input" id="agent-model" type="text" placeholder="e.g. gpt-4o (optional)">
                  <label class="form-label">Provider override</label>
                  <input class="form-input" id="agent-provider" type="text" placeholder="e.g. openai (optional)">
                  <label class="form-label">Group</label>
                  <input class="form-input" id="agent-group" type="text" placeholder="Group name (optional)">
                </div>
              </details>

              <div class="form-actions">
                <button type="button" class="btn-secondary" onclick="closeNewAgentDialog()">Cancel</button>
                <button type="submit" class="btn-primary">Create Agent</button>
              </div>
            </form>
          </div>
        </div>
        """
    }

    /// HTML for the New Routine dialog (inlined in JS).
    private static func newRoutineDialogHTML() -> String {
        """
        <div class="dialog-overlay" onclick="closeNewRoutineDialog()">
          <div class="dialog-content" onclick="event.stopPropagation()">
            <div class="dialog-title">New Cronjob</div>
            <form onsubmit="createRoutine(event)">
              <label class="form-label">Schedule</label>
              <input class="form-input" id="routine-schedule" type="text" placeholder="e.g. every 1h, 0 9 * * *, 30m" required>

              <label class="form-label">Prompt</label>
              <textarea class="form-textarea" id="routine-prompt" placeholder="What should the agent do on this schedule?" required></textarea>

              <div class="form-actions">
                <button type="button" class="btn-secondary" onclick="closeNewRoutineDialog()">Cancel</button>
                <button type="submit" class="btn-primary">Create Cronjob</button>
              </div>
            </form>
          </div>
        </div>
        """
    }
}
