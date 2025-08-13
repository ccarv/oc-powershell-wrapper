# ocp.ps1 — PowerShell OpenShift CLI Helper

A lightweight PowerShell wrapper around `oc` that adds smart login, a context-aware prompt, fast auto-completions (clusters/namespaces/pods/routes/contexts), and convenient subcommands. It loads in your profile but **doesn’t run `oc` until you actually use `ocp`**. The prompt only updates **when you’re logged in**.

[![Example](assets/example.gif)]

---

## Table of Contents

* [Features](#features)
* [Prerequisites](#prerequisites)
* [Installation](#installation)
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

* **Login convenience:**
  `ocp <cluster> [usernameOrToken]` — tokens starting with `sha256~` are auto-detected and passed via `--token`; otherwise `--username` is used.
* **Prompt tags (auth-gated):** Shows **cluster short name** and **namespace** in the prompt and updates only when logged in.
* **Context switching:** `ocp ctx` lists/switches contexts (sorted by short cluster name first).
* **Auto-completion with caching:** Tab-complete clusters, namespaces, pods, routes, and contexts with TTL-based caches.
* **Namespace/context aware:** Detects namespace/context changes made **outside** `ocp` (e.g., `oc project foo`, `oc -n bar get pods`) via:
  * Actively monitors on kubeconfig(s) for persisted changes.
  * Watches for ephemeral `-n/--namespace` and `oc project` changes.

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

## Configuration

Only **one** variable is required: your organization’s **domain suffix**.

| Variable            | Required | Default     | Example value                                                  | Purpose                                                                                                  |
| ------------------- | :------: | ----------- | -------------------------------------------------------------- | -------------------------------------------------------------------------------------------------------- |
| `OCP_DOMAIN_SUFFIX` |  **Yes** | —           | `corp.example.com`                                             | Domain suffix used to build API URLs and to detect the **short cluster** from `oc whoami --show-server`. |
| `OCP_API_SCHEME`    |    No    | `https`     | `https`                                                        | Protocol for API URL construction.                                                                       |
| `OCP_API_PORT`      |    No    | `6443`      | `6443` (or `0` to omit)                                        | Port for API URL; set to `0` (or empty) to omit `:port`.                                                 |
| `OCP_SERVER_REGEX`  |    No    | *(derived)* | `^https?://api\.(?<short>[^.]+)\.corp\.example\.com(?::\d+)?$` | Full override for server detection; **must** include a named group `(?<short>...)`.                      |

**Set for current session:**

```powershell
$env:OCP_DOMAIN_SUFFIX = 'corp.example.com'   # REQUIRED
# Optional:
$env:OCP_API_SCHEME    = 'https'
$env:OCP_API_PORT      = '6443'               # or '0' to omit the port
$env:OCP_SERVER_REGEX  = '^https?://api\.(?<short>[^.]+)\.corp\.example\.com(?::\d+)?$'
```

**URL construction**

```
{scheme}://api.{cluster}.{domainSuffix}{:port?}
```

Examples with **cluster** `uswest8` and **domain suffix** `corp.example.com`:

* Default port `6443` → `https://api.uswest8.corp.example.com:6443`
* Omit port (`OCP_API_PORT=0`) → `https://api.uswest8.corp.example.com`

> If `OCP_DOMAIN_SUFFIX` is not set, `ocp` will error and refuse to run until you set it.

---

## Commands

| Command     | Syntax                                          | Description                                                                                                                   |
| ----------- | ----------------------------------------------- | ----------------------------------------------------------------------------------------------------------------------------- |
| **login**   | `ocp <cluster> [usernameOrToken]`               | Logs into `https://api.<cluster>.<domainSuffix>:<port>`. Detects `sha256~` tokens vs username. Updates prompt & warms caches. |
| **logout**  | `ocp logout`                                    | Runs `oc logout`, clears prompt tags, and stops external sync.                                                                |
| **who**     | `ocp who`                                       | Shows current user, server, and namespace.                                                                                    |
| **ns**      | `ocp ns <namespace>`                            | Switches project/namespace. Updates prompt and refreshes pod/route caches.                                                    |
| **logs**    | `ocp logs <pod> [-- extra oc logs args]`        | Runs `oc logs` in the current namespace (with your extra args).                                                               |
| **tail**    | `ocp tail <pod>`                                | Runs `oc logs -f` (follow) in the current namespace.                                                                          |
| **route**   | `ocp route <route-name>`                        | Opens the route URL in the default browser (https if TLS is set).                                                             |
| **ctx**     | `ocp ctx [name \| short]`                       | Lists contexts (sorted by short first) or switches to the selected context. Updates prompt if logged in.                      |
| **refresh** | `ocp refresh [ns\|pods\|routes\|contexts\|all]` | Manually refreshes one or more caches.                                                                                        |
| **help**    | `ocp help`                                      | Shows usage and registered commands.                                                                                          |

---

## Usage Examples

```powershell
# REQUIRED: set your domain suffix first
$env:OCP_DOMAIN_SUFFIX = 'corp.example.com'

# Login (cluster 'uswest8')
ocp uswest8                 # uses --username=$env:USERNAME
ocp uswest8 alice           # explicit username
ocp uswest8 sha256~ABC...   # token-based login

# Quick info
ocp who

# Namespace / context
ocp ns payments
ocp ctx                 # list contexts
ocp ctx uswest8         # switch by short name if the context maps to that server

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

* **“OCP\_DOMAIN\_SUFFIX is not set” error:**
  Set it and re-run:

  ```powershell
  $env:OCP_DOMAIN_SUFFIX = 'corp.example.com'
  ```

* **Prompt shows nothing for cluster/namespace:**
  You’re likely not authenticated. Run `oc login …` or `ocp uswest8 …`.
  (Typing `ocp` alone will not set tags unless logged in.)

* **Namespace changes don’t reflect immediately:**
  Ensure PSReadLine is loaded (`Get-Module PSReadLine`). The prompt updates right after the command completes.

* **Multiple kubeconfigs:**
  Set `$KUBECONFIG` (`;` on Windows, `:` on macOS/Linux). The watcher follows all listed files.

* **Execution policy blocks loading (Windows):**
  `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`, or `Unblock-File` on the downloaded files.

---

## Contributing

PRs and issues welcome! Good candidates:

* Additional resource helpers (`ocp get`, `ocp describe`) with completion.
* Async cache refresh (opt-in).
* More env toggles for per-machine behavior.

---

## License

MIT (or your preferred license). Add a `LICENSE` file in the repo root.
