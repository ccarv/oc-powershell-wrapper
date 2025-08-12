# ocp.ps1 — PowerShell OpenShift CLI Helper

A lightweight PowerShell wrapper around `oc` that adds smart login, a context-aware prompt, fast auto-completions (clusters/namespaces/pods/routes/contexts), and convenient subcommands. 

> Prompt example (cluster short name + namespace):
>
> `(rm3 -- payments) PS C:\src\my-service>`

---

## Table of Contents

* [Features](#features)
* [Prerequisites](#prerequisites)
* [Installation](#installation)
* [Usage](#usage)

  * [Login](#login)
  * [Prompt](#prompt)
  * [Subcommands](#subcommands)
  * [Auto-completion](#auto-completion)
  * [Context & Namespace sync (outside `ocp`)](#context--namespace-sync-outside-ocp)
* [Configuration](#configuration)
* [Performance Notes](#performance-notes)
* [Troubleshooting](#troubleshooting)
* [Contributing](#contributing)
* [License](#license)

---

## Features

* **Zero-cost startup:** No `oc` calls at profile load; everything initializes the first time you use `ocp`.
* **Login convenience:**
  `ocp <cluster> [usernameOrToken]` — detects tokens that start with `sha256~` and uses `--token` automatically; otherwise uses `--username`.
* **Prompt tags:** Shows **cluster short name** and **namespace** in your PowerShell prompt and updates on login, `ocp ns`, and context switches.
* **Context switching:** `ocp ctx` lists/switches contexts; output is sorted by short cluster name first:

  ```
  *  [rm3]  my-context-name
     [qa1]  another-context
  ```
* **Auto-completion with caching:** Tab-complete clusters, namespaces, pods, routes, and contexts with TTL-based caches.
* **Helpful subcommands:** `logout`, `who`, `ns`, `logs`, `tail`, `route`, `ctx`, `refresh`, `help`.
* **External change detection (lazy):** Detects namespace/context changes made **outside** `ocp` (e.g., `oc project foo`, `oc -n bar get pods`) via:

  * A **FileSystemWatcher** on kubeconfig(s) for persisted changes.
  * A **PSReadLine history hook** for ephemeral `-n/--namespace` and `oc project` changes.
    Both start only after your first use of `ocp` and tear down on `ocp logout`.

---

## Prerequisites

* **PowerShell** 7.x (Core) or Windows PowerShell 5.1
  (Works cross-platform on Windows/macOS/Linux with PS7+.)
* **OpenShift CLI** (`oc`) installed and on `PATH`.
* **PSReadLine** module (included by default in modern PowerShell) — used for the history hook.
* A valid **kubeconfig** (via `$KUBECONFIG` or `~/.kube/config`).

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

3. (Windows only) If your Execution Policy blocks local scripts:

   ```powershell
   Set-ExecutionPolicy -Scope CurrentUser RemoteSigned
   ```

That’s it. Open a new PowerShell session (or re-dot-source your profile) and run `ocp`.

---

## Usage

### Login

```powershell
# Username-based login (username inferred from $env:USERNAME if omitted)
ocp rm3                # uses --username=$env:USERNAME
ocp rm3 alice          # uses --username=alice

# Token-based login (auto-detected when it starts with 'sha256~')
ocp rm3 sha256~<token>
```

`ocp` logs into `https://api.<cluster>.7wse.p1.openshiftapps.com:6443`, sets your prompt tags, and warms caches.

### Prompt

The prompt shows `( <cluster-short> -- <namespace> )` before the usual `PS <path>`:

```
(rm3 -- dev) PS C:\src\svc>
```

It updates on:

* successful `ocp` login,
* `ocp ns <name>`,
* `ocp ctx <name-or-short>`,
* and external changes (see below).

### Subcommands

```powershell
ocp help
```

* `ocp logout` — `oc logout` + clears prompt tags and stops external sync.
* `ocp who` — shows current user, server, and namespace.
* `ocp ns <namespace>` — switch project/namespace (updates prompt).
* `ocp logs <pod> [-- extra oc logs args]` — `oc logs` once.
* `ocp tail <pod>` — `oc logs -f`.
* `ocp route <route-name>` — opens the route in your default browser.
* `ocp ctx [name|short]` — list or switch contexts (sorted by short name first).
* `ocp refresh [ns|pods|routes|contexts|all]` — manually refresh caches.

**Examples**

```powershell
ocp ns payments
ocp ctx                 # lists contexts
ocp ctx rm3             # switch by short name
ocp logs api-7f6c9 -c app --since=10m
ocp tail worker-0
ocp route web-frontend
ocp refresh all
ocp logout
```

### Auto-completion

* `ocp <TAB>` → clusters (from kubeconfig server URLs)
* `ocp ns <TAB>` → namespaces
* `ocp logs|tail <TAB>` → pods in the current namespace
* `ocp route <TAB>` → routes in the current namespace
* `ocp ctx <TAB>` → contexts (tooltip shows short cluster)

Caching uses sensible TTLs to keep completions fast without stale results.

### Context & Namespace sync (outside `ocp`)

The script detects changes made directly with `oc` or other tools:

* **Persisted changes** (kubeconfig edits): file watcher triggers a refresh.
* **Ephemeral changes** (`oc project foo`, `oc -n bar get pods`, `--namespace=baz`): a PSReadLine hook marks a refresh and the prompt updates immediately when it renders next.

Both mechanisms are **lazy-started** the first time you use `ocp`, and **stopped** on `ocp logout`.

---

## Configuration

The external sync has simple feature toggles you can flip **after** the script loads:

```powershell
# Disable watcher or history hook for this session
$script:OcpSync.UseFileWatcher  = $false
$script:OcpSync.UseReadLineHook = $false
```

(These are script-scoped values defined by `ocp.ps1`. Set them in your profile *after* dot-sourcing the script if you want different defaults.)

---

## Performance Notes

* **Lazy initialization:** No `oc` calls at shell startup.
* **Debounced refreshes:** File watcher changes are debounced (250ms) and applied at the next prompt render to avoid reading kubeconfig mid-write.
* **TTL-based caches:** Namespaces / pods / routes / contexts are cached per TTL and current namespace, improving tab completion speed.

---

## Troubleshooting

* **Prompt doesn’t show cluster/namespace:**
  Use `ocp` at least once (e.g., `ocp who`) to trigger lazy init. Then try `ocp refresh all`.

* **Namespace changes don’t reflect immediately:**
  Ensure PSReadLine is loaded (`Get-Module PSReadLine`). The prompt updates right after the command completes, when the prompt renders.

* **Using multiple kubeconfigs:**
  Set `$KUBECONFIG` (Windows uses `;`, macOS/Linux uses `:` as the separator). The watcher handles all listed files.

* **`oc` not on PATH or missing kubeconfig:**
  `ocp` relies on `oc` and your kubeconfig. Confirm `oc version` and that either `$KUBECONFIG` is set or `~/.kube/config` exists.

* **Execution policy blocks loading:**
  On Windows: `Set-ExecutionPolicy -Scope CurrentUser RemoteSigned`.

---

## Contributing

Issues and PRs are welcome! Ideas that would be especially helpful:

* Additional resource helpers (`ocp get`, `ocp describe`) with completion.
* Async cache refresh (opt-in).
* Per-machine environment toggles for sync features.

---

## License

MIT License
