# ocp.ps1 — OC PowerShell Wrapper

A lightweight PowerShell wrapper around `oc` that adds smart login, a context-aware prompt, fast auto-completions (clusters/namespaces/pods/routes/contexts), and convenient subcommands. It loads in your profile but **doesn’t run `oc` until you actually use `ocp`**. The prompt only updates **when you’re logged in**.

> Prompt example (cluster short name + namespace):
>
> `(rm3 : payments) PS C:\src\my-service>`

---

## Table of Contents

* [Features](#features)
* [Prerequisites](#prerequisites)
* [Installation](#installation)
* [Setting up (API server URL)](#setting-up-api-server-url)
* [Configuration](#configuration)
* [Commands](#commands)
* [Usage Examples](#usage-examples)
* [Auto-completion](#auto-completion)
* [Context & Namespace Sync (outside `ocp`)](#context--namespace-sync-outside-ocp)
* [Performance Notes](#performance-notes)
* [Troubleshooting](#troubleshooting)
* [Contributing](#contributing)
* [License](#license)

---

## Features

* **Zero-cost startup:** No `oc` calls at profile load; everything initializes the first time you use `ocp`.
* **Login convenience:**
  `ocp <cluster> [usernameOrToken]` — tokens starting with `sha256~` are auto-detected and passed via `--token`; otherwise `--username` is used.
* **Prompt tags (auth-gated):** Shows **cluster short name** and **namespace** in the prompt and updates only when logged in.
* **Context switching:** `ocp ctx` lists/switches contexts (sorted by short cluster name first).
* **Auto-completion with caching:** Tab-complete clusters, namespaces, pods, routes, and contexts with TTL-based caches.
* **External change detection (lazy):** Detects namespace/context changes made **outside** `ocp` (e.g., `oc project foo`, `oc -n bar get pods`) via:

  * A **FileSystemWatcher** on kubeconfig(s) for persisted changes.
  * A **PSReadLine history hook** for ephemeral `-n/--namespace` and `oc project` changes.
    Both start only after your first `ocp` use and stop on `ocp logout`.
* **Configurable server/regex:** Centralized OpenShift API URL building and “short cluster” extraction, configurable via **env vars**.

---

## Prerequisites

* **PowerShell** 7.x (Core) or Windows PowerShell 5.1
* **OpenShift CLI** (`oc`) installed and on `PATH`
* **PSReadLine** module (bundled with modern PowerShell)
* A valid **kubeconfig** via:

  * `$KUBECONFIG` (Windows uses `;`, macOS/Linux uses `:`), or
  * default path: `~/.kube/config` *(portable handling for all OSes)*

---

## Installation

1. **Save the script** somewhere on disk, e.g.:

   ```
   %USERPROFILE%\scripts\ocp.ps1           # Windows
   ~/.config/powershell/ocp.ps1            # macOS/Linux (example)
   ```

2. **Dot-source the script in your PowerShell profile** so it loads each session.

   * Open your profile:

     ```powershell
     code $PROFILE   # or: notepad $PROFILE
     ```

     If `$PROFILE` doesn’t exist:

     ```powershell
     New-Item -Type File -Force $PROFILE | Out-Null
     ```

   * Add a dot-source line (adjust the path):

     ```powershell
     . "$HOME\scripts\ocp.ps1"             # Windows
     # or
     . "$HOME/.config/powershell/ocp.ps1"  # macOS/Linux
     ```

3. *(Windows only)* If Execution Policy blocks local scripts:

   ```powershell
   Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
   ```

Open a new PowerShell session (or re-dot-source your profile) and run `ocp`.

---

## Setting up (API server URL)

`ocp` constructs the API server URL from simple building blocks:

```
{scheme}://api.{cluster}.{domain}{:port?}
```

* **scheme**: usually `https`
* **cluster**: the short cluster you pass to `ocp` (e.g., `rm3`)
* **domain**: your organization’s OpenShift domain (default shown below)
* **port**: typically `6443`; set to `0` (or empty) to omit

| Setting | Default                     | Example override                               |
| ------- | --------------------------- | ---------------------------------------------- |
| Scheme  | `https`                     | `OCP_API_SCHEME=https`                         |
| Domain  | `7wse.p1.openshiftapps.com` | `OCP_DOMAIN=corp.example.com`                  |
| Port    | `6443`                      | `OCP_API_PORT=443` or `OCP_API_PORT=0` to omit |

**Examples**

* Default domain/port, cluster `rm3` →
  `https://api.rm3.7wse.p1.openshiftapps.com:6443`
* Custom domain, omit port, cluster `dev` →
  set `OCP_DOMAIN=corp.example.com`, `OCP_API_PORT=0` →
  `https://api.dev.corp.example.com`

**How the “short cluster” is detected**

When reading the current server (e.g., from kubeconfig), `ocp` extracts the short cluster using a regex. You can override it with `OCP_SERVER_REGEX`, which **must** contain a named group `(?<short>...)`.

* Default pattern (conceptual):
  `^https?://api\.(?<short>[^.]+)\.<domain>(?::\d+)?$`
* Custom example:
  `OCP_SERVER_REGEX=^https?://api\.(?<short>[a-z0-9-]+)\.corp\.example\.com(?::\d+)?$`

> Tip: after logging in, run `oc whoami --show-server` to verify the server URL matches your expectations.

---

## Configuration

### Server & regex (env vars)

You can change how the server URL is built and how the short cluster name is parsed **without editing the file**:

| Env var            | Example value                                                  | Purpose                                                                        |
| ------------------ | -------------------------------------------------------------- | ------------------------------------------------------------------------------ |
| `OCP_API_SCHEME`   | `https`                                                        | Protocol for the API URL                                                       |
| `OCP_DOMAIN`       | `7wse.p1.openshiftapps.com`                                    | Domain appended after `api.<cluster>.`                                         |
| `OCP_API_PORT`     | `6443` (or `0` to omit)                                        | Port for the API URL                                                           |
| `OCP_SERVER_REGEX` | `^https?://api\.(?<short>[^.]+)\.corp\.example\.com(?::\d+)?$` | Override the default detection regex; **must** include a `(?<short>...)` group |

Example (session-scoped):

```powershell
$env:OCP_DOMAIN       = 'corp.example.com'
$env:OCP_API_PORT     = '443'     # or '0' to omit the port
$env:OCP_SERVER_REGEX = '^https?://api\.(?<short>[^.]+)\.corp\.example\.com(?::\d+)?$'
```

### Sync feature toggles (per session)

After dot-sourcing the script, you can toggle these:

```powershell
$script:OcpSync.UseFileWatcher  = $true   # or $false
$script:OcpSync.UseReadLineHook = $true   # or $false
```

---

## Commands

| Command     | Syntax                                          | Description                                                                                                             |
| ----------- | ----------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------- |
| **login**   | `ocp <cluster> [usernameOrToken]`               | Logs into `https://api.<cluster>.<domain>:<port>`. Detects `sha256~` tokens vs username. Updates prompt & warms caches. |
| **logout**  | `ocp logout`                                    | Runs `oc logout`, clears prompt tags, and stops external sync.                                                          |
| **who**     | `ocp who`                                       | Shows current user, server, and namespace.                                                                              |
| **ns**      | `ocp ns <namespace>`                            | Switches project/namespace. Updates prompt and refreshes pod/route caches.                                              |
| **logs**    | `ocp logs <pod> [-- extra oc logs args]`        | Runs `oc logs` in the current namespace (with your extra args).                                                         |
| **tail**    | `ocp tail <pod>`                                | Runs `oc logs -f` (follow) in the current namespace.                                                                    |
| **route**   | `ocp route <route-name>`                        | Opens the route URL in the default browser (https if TLS is set).                                                       |
| **ctx**     | `ocp ctx [name \| short]`                       | Lists contexts (sorted by short first) or switches to the selected context. Updates prompt if logged in.                |
| **refresh** | `ocp refresh [ns\|pods\|routes\|contexts\|all]` | Manually refreshes one or more caches.                                                                                  |
| **help**    | `ocp help`                                      | Shows usage and registered commands.                                                                                    |

---

## Usage Examples

```powershell
# Login
ocp rm3                 # uses --username=$env:USERNAME
ocp rm3 alice           # explicit username
ocp rm3 sha256~ABC...   # token-based login

# Quick info
ocp who

# Namespace / context
ocp ns payments
ocp ctx                 # list contexts
ocp ctx rm3             # switch by short name

# Logs & routes
ocp logs api-7f6c9 -c app --since=10m
ocp tail worker-0
ocp route web-frontend

# Housekeeping
ocp refresh all
ocp logout
```

---

## Auto-completion

* `ocp <TAB>` → clusters (from kubeconfig servers)
* `ocp ns <TAB>` → namespaces
* `ocp logs|tail <TAB>` → pods in the current namespace
* `ocp route <TAB>` → routes in the current namespace
* `ocp ctx <TAB>` → contexts (tooltip shows short cluster name)

Caching keeps completions responsive while avoiding excessive `oc` calls.

---

## Context & Namespace Sync (outside `ocp`)

The script detects changes made directly with `oc` or other tools:

* **Persisted changes** (kubeconfig edits): a file watcher marks a refresh.
* **Ephemeral changes** (`oc project foo`, `oc -n bar get pods`, `--namespace=baz`): a PSReadLine hook marks a refresh.

The actual read happens at the **next prompt render** (post-command), ensuring accurate tags. If you’re **not logged in**, the prompt tags remain **cleared**.

---

## Performance Notes

* **Lazy initialization:** No `oc` calls at shell startup.
* **Debounced refreshes:** Kubeconfig changes are debounced (\~250ms) and applied at the next prompt.
* **TTL-based caches:** Namespaces / pods / routes / contexts cache per sensible TTLs.

---

## Troubleshooting

* **Prompt shows nothing for cluster/namespace:**
  You’re likely not authenticated. Run `oc login …` or `ocp <cluster> …`.
  (Typing `ocp` alone will not set tags unless logged in.)

* **Namespace changes don’t reflect immediately:**
  Ensure PSReadLine is loaded (`Get-Module PSReadLine`). The prompt updates right after the command completes.

* **Multiple kubeconfigs:**
  Set `$KUBECONFIG` (`;` on Windows, `:` on macOS/Linux). The watcher follows all listed files.

* **Execution policy blocks loading (Windows):**
  `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`.

---

## Contributing

PRs and issues welcome! Good candidates:

* Additional resource helpers (`ocp get`, `ocp describe`) with completion.
* Async cache refresh (opt-in).
* More env toggles for per-machine behavior.

---

## License

MIT License
