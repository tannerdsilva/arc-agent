# Gateway Messaging (Telegram / Email / Slack)

The Arc Agent gateway (`arc-agent serve`) connects the agent core to
messaging platforms. Configuration lives in `gateway.json` in the user's
home directory (`~/gateway.json`), with environment-variable overrides
(environment values always win — the same convention Hermes uses). Secrets
belong in environment variables, not in checked-in JSON.

Enabling a platform requires nothing more than its credentials: a platform
turns itself on automatically when a token is present (`enabled` may also be
set explicitly).

## Common behavior (all platforms)

| Behavior | Notes |
|---|---|
| Streaming replies | While the agent produces output, the message is updated in place (Telegram `editMessageText`, Slack `chat.update`). Platforms without edits (email) send once when finished. |
| Typing indicator | Telegram `sendChatAction`; Slack/email have no indicator (no-op). Controlled by `typing_indicator`. |
| `reply_to_mode` | `off` — never thread; `first` — thread only on the first reply; `all` — every reply threads (Telegram forum topics / Slack threads). |
| Authz | `allowed_users` — comma-separated platform ids; `allow_all_users` — open access; `require_mention` — outside DMs the bot must be mentioned (Slack defaults on, Telegram off). |
| Long messages | Split into platform-sized chunks (4096 Telegram / 4000 Slack), never mid-code-fence. |

## Telegram

```json
{
  "telegram": {
    "enabled": true,
    "bot_token": "",
    "allowed_users": "",
    "allow_all_users": false,
    "home_channel": "",
    "typing_indicator": true,
    "reply_to_mode": "first",
    "require_mention": false,
    "poll_interval_seconds": 1
  }
}
```

Env overrides: `TELEGRAM_BOT_TOKEN`, `TELEGRAM_ALLOWED_USERS`,
`TELEGRAM_ALLOW_ALL_USERS`, `TELEGRAM_HOME_CHANNEL`.

Token from [@BotFather](https://t.me/BotFather). Long polling only — no
webhook or TLS listener required.

## Email

```json
{
  "email": {
    "enabled": true,
    "address": "bot@example.com",
    "password": "",
    "imap_host": "imap.example.com",
    "imap_port": 993,
    "imap_use_tls": true,
    "smtp_host": "smtp.example.com",
    "smtp_port": 465,
    "smtp_use_tls": true,
    "allowed_users": "",
    "allow_all_users": false,
    "poll_interval_seconds": 60
  }
}
```

Env overrides: `EMAIL_ADDRESS`, `EMAIL_PASSWORD`, `EMAIL_IMAP_HOST`,
`EMAIL_IMAP_PORT`, `EMAIL_SMTP_HOST`, `EMAIL_SMTP_PORT`,
`EMAIL_ALLOWED_USERS`, `EMAIL_ALLOW_ALL_USERS`.

- The same `address`/`password` are used for IMAP (login) and SMTP (AUTH
  PLAIN); an app password is recommended.
- Plain connections use STARTTLS when `imap_use_tls`/`smtp_use_tls` are
  false; implicit TLS when true (default).
- Each sender address is its own chat; replies carry
  `In-Reply-To`/`References` (subject threading preserved).

## Slack

```json
{
  "slack": {
    "enabled": true,
    "bot_token": "",
    "app_token": "",
    "allowed_users": "",
    "allow_all_users": false,
    "home_channel": "",
    "typing_indicator": false,
    "reply_to_mode": "first",
    "require_mention": true
  }
}
```

Env overrides: `SLACK_BOT_TOKEN`, `SLACK_APP_TOKEN`, `SLACK_ALLOWED_USERS`,
`SLACK_ALLOW_ALL_USERS`, `SLACK_HOME_CHANNEL`.

Socket Mode setup:
- `bot_token` (`xoxb-…`) — bot token.
- `app_token` (`xapp-…`) — app-level token with the `connections:write`
  scope (Socket Mode enabled for the app).
- Events: `app_mention` and `message.*` subscribed; the adapter answers DMs
  and mention messages, requires a mention in channels when
  `require_mention` is true, and treats each `thread_ts` as a thread.
- Slash commands are treated as mentions of the bot.

## Gateway CLI

```bash
arc-agent serve            # loads ~/gateway.json
arc-agent serve --telegram-token <token>   # legacy single-platform form
```

`--host`/`--port` control the control HTTP server (default `127.0.0.1:8080`).
