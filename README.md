# gcal

A tiny Zig CLI to read Google Calendar events and print a clean, pager-friendly view.

## Install

- Zig 0.15.1 recommended
- Build:
  ```
  zig build --release=safe
  ```
- The binary is placed in `zig-out/bin/gcal`

Optionally copy the binary to a path in your `$PATH` for easy access.

## Configure

1. Create OAuth client credentials (Installed application) in [Google Cloud Console](https://console.cloud.google.com/) and download the JSON.

2. Place the JSON at: `~/.gcal.config`

   Expected format (Google's default "installed" block):
   ```json
   {
     "installed": {
       "client_id": "...",
       "project_id": "...",
       "auth_uri": "https://accounts.google.com/o/oauth2/auth",
       "token_uri": "https://oauth2.googleapis.com/token",
       "auth_provider_x509_cert_url": "https://www.googleapis.com/oauth2/v1/certs",
       "client_secret": "...",
       "redirect_uris": ["http://localhost"]
     }
   }
   ```

3. First run will guide you through device code auth and save the token to `~/.gcal`

## Usage

```
gcal [flags]
```

Flags:
- `--today`, `-t`: show today's events
- `--tomorrow`, `-T`: show tomorrow's events
- `--week`, `-W`: show this week (default)
- `--month`, `-M`: show this month
- `--custom`, `-C START [END]`: custom date range (YYYY-MM-DD)
- `--user`, `-u EMAIL`: use a specific calendar (default: primary)
- `--list-calendars`, `-l`: list calendars and interactively pick one
- `--no-pager`: write to stdout instead of pager
- `--help`, `-h`: show help

Examples:
- `gcal -t`
- `gcal -C 2025-10-01 2025-10-07`
- `gcal -u someone@example.com -W`

Environment:
- `GCAL_PAGER`: pager command (default: `less`)

## Notes

- Read-only scope: `https://www.googleapis.com/auth/calendar.readonly`
- Token is refreshed automatically before expiry.
- Output groups by ISO date (YYYY-MM-DD) and displays `Mon-dd` headers.
