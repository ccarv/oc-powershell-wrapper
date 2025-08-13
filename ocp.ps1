# =====================  OCP Login + Helpers + Contexts + Tab Completion  =====================
# Usage:
#   ocp <cluster> [usernameOrToken]          # logs into https://api.<cluster>...:6443
#   ocp logout                               # oc logout + clear prompt tags
#   ocp who                                  # show user/server/namespace
#   ocp ns <namespace>                       # switch namespace (project)
#   ocp logs <pod> [-- extra oc logs args]   # logs once
#   ocp tail <pod>                           # logs -f (follow)
#   ocp route <route-name>                   # open route URL in browser
#   ocp ctx [name|shortCluster]              # list/switch kube contexts (autocomplete)
#   ocp refresh [ns|pods|routes|contexts|all]# manual cache refresh
#
# Tab completion:
#   ocp <TAB>         -> clusters (from kubeconfig server URLs)
#   ocp ns <TAB>      -> namespaces (via projects)
#   ocp logs/tail<TAB>-> pods in current namespace
#   ocp route <TAB>   -> routes in current namespace
#   ocp ctx <TAB>     -> contexts (tooltip shows short cluster name)
# =============================================================================================

# ---- OpenShift API server config (domain suffix REQUIRED) ----------------------
# Environment variables:
#   OCP_DOMAIN_SUFFIX  -> e.g. "corp.example.com"  (REQUIRED; no default)
#   OCP_API_SCHEME     -> e.g. "https"             (optional; default https)
#   OCP_API_PORT       -> e.g. "6443"              (optional; 0/empty omits port)
#   OCP_SERVER_REGEX   -> full regex override with a (?<short>...) group (optional)
$script:OcpServer = @{
    Scheme        = if ($env:OCP_API_SCHEME) { $env:OCP_API_SCHEME } else { 'https' }
    DomainSuffix  = $env:OCP_DOMAIN_SUFFIX     # REQUIRED: must be set by the user
    Port          = if ($env:OCP_API_PORT)     { try { [int]$env:OCP_API_PORT } catch { 6443 } } else { 6443 }
    ServerRegex   = $env:OCP_SERVER_REGEX
}

function Assert-OcpDomainSuffix {
    Resolve-OcpConfigFromEnv
    if ([string]::IsNullOrWhiteSpace($script:OcpServer.DomainSuffix)) {
        Write-Error @"
OCP_DOMAIN_SUFFIX is required and not set.
Set it for this session (example):
    `$env:OCP_DOMAIN_SUFFIX = 'corp.example.com'
Or add it to your PowerShell profile so it’s always set.
"@
        throw "OCP_DOMAIN_SUFFIX is not set."
    }
}

function Get-OcpApiServerUrl {
    param([Parameter(Mandatory)][string]$Cluster)
    Assert-OcpDomainSuffix
    $portPart = if ($script:OcpServer.Port -gt 0) { ":$($script:OcpServer.Port)" } else { "" }
    return "{0}://api.{1}.{2}{3}" -f $script:OcpServer.Scheme, $Cluster, $script:OcpServer.DomainSuffix, $portPart
}

function Get-OcpServerRegex {
    Assert-OcpDomainSuffix

    if ($script:OcpServer.ServerRegex -and $script:OcpServer.ServerRegex.Trim().Length -gt 0) {
        try { return [regex]::new($script:OcpServer.ServerRegex, [Text.RegularExpressions.RegexOptions]::IgnoreCase) } catch { }
    }

    $dom = [regex]::Escape($script:OcpServer.DomainSuffix)
    $pat = "^(?<scheme>https?)://api\.(?<short>[^.]+)\.$dom(?::\d+)?$"
    return [regex]::new($pat, [Text.RegularExpressions.RegexOptions]::IgnoreCase)
}

function Get-OcpShortFromServer {
    param([string]$Server)
    if (-not $Server) { return $null }
    $m = (Get-OcpServerRegex).Match($Server)
    if ($m.Success) { return $m.Groups['short'].Value } else { return $null }
}

# ---------------------- State + Prompt ------------------------------------------
$global:OcpState = [ordered]@{ Cluster = $null; Namespace = $null }

function Set-OcpClusterTag     { param([string]$Name) $global:OcpState.Cluster   = $Name }
function Clear-OcpClusterTag   { $global:OcpState.Cluster   = $null }
function Set-OcpNamespaceTag   { param([string]$Name) $global:OcpState.Namespace = $Name }
function Clear-OcpNamespaceTag { $global:OcpState.Namespace = $null }

function global:prompt {
    $loc = (Get-Location).Path

    # Post-exec deferred refresh (e.g., after 'oc project <ns>')
    if ($script:OcpSync.PendingRefresh) {
        $script:OcpSync.PendingRefresh = $false
        Refresh-OcpFromEnvironment
    }

    if ($global:OcpState.Cluster -or $global:OcpState.Namespace) {
        Write-Host "(" -NoNewline

        if ($global:OcpState.Cluster) {
            Write-Host $global:OcpState.Cluster -ForegroundColor DarkRed -NoNewline
        } else {
            Write-Host "-" -ForegroundColor DarkGray -NoNewline
        }

        Write-Host ":" -ForegroundColor DarkGray -NoNewline  # user preference

        if ($global:OcpState.Namespace) {
            Write-Host $global:OcpState.Namespace -ForegroundColor Cyan -NoNewline
        } else {
            Write-Host "-" -ForegroundColor DarkGray -NoNewline
        }

        Write-Host ") " -NoNewline
    }

    Write-Host "PS " -NoNewline
    Write-Host $loc -NoNewline
    return "> "
}

# ---------------------- External change sync (lazy; starts on first ocp use) ----
# Feature toggles (change if you want different defaults)
$script:OcpSync = @{
    UseFileWatcher      = $true
    UseReadLineHook     = $true
    Started             = $false
    KubeWatchers        = @()
    KubeWatchSubs       = @()
    DebounceQueued      = $false
    PrevHistoryHandler  = $null
    PendingRefresh      = $false
}

function Get-OcpKubeConfigPaths {
    if ($env:KUBECONFIG) {
        $sep = if ($IsWindows) { ';' } else { ':' }
        return $env:KUBECONFIG -split [regex]::Escape($sep) | Where-Object { $_ -and (Test-Path $_) }
    }
    $p = Join-Path (Join-Path $HOME ".kube") "config"
    if (Test-Path $p) { return ,$p } else { return @() }
}

function Refresh-OcpFromEnvironment {
    try {
        if (Test-OcpLoggedIn) {
            $curNs = Get-OcpCurrentNamespace
            if ($curNs) { Set-OcpNamespaceTag $curNs } else { Clear-OcpNamespaceTag }

            $server = (& oc whoami --show-server 2>$null)
            $short  = Get-OcpShortFromServer $server
            if ($short) { Set-OcpClusterTag $short } else { Clear-OcpClusterTag }

            Update-OcpNsCache
            Update-OcpPodsCache
            Update-OcpRoutesCache
            Update-OcpContextsCache
            $script:OcpSessionTagsInitialized = $true
        } else {
            Clear-OcpClusterTag
            Clear-OcpNamespaceTag
        }
    } catch { }
}

function Start-OcpExternalSync {
    if ($script:OcpSync.Started) { return }
    $script:OcpSync.Started = $true

    # ---- (1) FileSystemWatcher over kubeconfig(s) -----------------------------
    if ($script:OcpSync.UseFileWatcher) {
        foreach ($sub in $script:OcpSync.KubeWatchSubs) { Unregister-Event -SubscriptionId $sub.Id -ErrorAction SilentlyContinue }
        foreach ($w in $script:OcpSync.KubeWatchers)   { try { $w.EnableRaisingEvents = $false; $w.Dispose() } catch {} }
        $script:OcpSync.KubeWatchSubs = @()
        $script:OcpSync.KubeWatchers  = @()

        foreach ($cfg in Get-OcpKubeConfigPaths) {
            $dir  = Split-Path -Path $cfg -Parent
            $file = Split-Path -Path $cfg -Leaf
            try {
                $fsw = New-Object IO.FileSystemWatcher $dir, $file
                $fsw.NotifyFilter = [IO.NotifyFilters]'LastWrite, Size, FileName'
                $fsw.IncludeSubdirectories = $false
                $fsw.EnableRaisingEvents   = $true

                # Defer: set PendingRefresh and let prompt() do the read after writes settle
                $sub = Register-ObjectEvent -InputObject $fsw -EventName Changed -Action {
                    if (-not $script:OcpSync.DebounceQueued) {
                        $script:OcpSync.DebounceQueued = $true
                        Start-Sleep -Milliseconds 250
                        try { $script:OcpSync.PendingRefresh = $true } finally { $script:OcpSync.DebounceQueued = $false }
                    }
                }
                $script:OcpSync.KubeWatchers  += $fsw
                $script:OcpSync.KubeWatchSubs += $sub
            } catch { }
        }
    }

    # ---- (2) PSReadLine AddToHistoryHandler (chain, don’t clobber) -----------
    if ($script:OcpSync.UseReadLineHook) {
        try {
            if (Get-Module -ListAvailable PSReadLine) {
                $opt = Get-PSReadLineOption
                $script:OcpSync.PrevHistoryHandler = $opt.AddToHistoryHandler

                $hook = {
                    param($line)

                    # Match namespace/context changers (handles --namespace=foo and -n=foo forms)
                    $matchNs = ($line -match '^\s*oc\s+(project|projects)\b') -or
                               ($line -match '^\s*oc\s+config\s+use-context\b') -or
                               ($line -match '^\s*oc\s+config\s+set-context\b') -or
                               ($line -match '^\s*kubectl\s+config\s+use-context\b') -or
                               ($line -match '^\s*kubectl\s+config\s+set-context\b') -or
                               ($line -match '^\s*oc\b.*\s--namespace(\s+|=)\S+') -or
                               ($line -match '^\s*oc\b.*\s-n(\s+|=)\S+')

                    # Chain any previous handler
                    $keep = $true
                    if ($script:OcpSync.PrevHistoryHandler) {
                        try { $keep = & $script:OcpSync.PrevHistoryHandler $line } catch { $keep = $true }
                    }

                    if ($matchNs) { $script:OcpSync.PendingRefresh = $true }  # defer to prompt()
                    return $keep
                }

                Set-PSReadLineOption -AddToHistoryHandler $hook
            }
        } catch { }
    }
}

function Stop-OcpExternalSync {
    if (-not $script:OcpSync.Started) { return }
    $script:OcpSync.Started = $false

    foreach ($sub in $script:OcpSync.KubeWatchSubs) { Unregister-Event -SubscriptionId $sub.Id -ErrorAction SilentlyContinue }
    foreach ($w in $script:OcpSync.KubeWatchers)   { try { $w.EnableRaisingEvents = $false; $w.Dispose() } catch {} }
    $script:OcpSync.KubeWatchSubs = @()
    $script:OcpSync.KubeWatchers  = @()

    try {
        if (Get-Module -ListAvailable PSReadLine) {
            if ($script:OcpSync.PrevHistoryHandler) {
                Set-PSReadLineOption -AddToHistoryHandler $script:OcpSync.PrevHistoryHandler
            } else {
                Set-PSReadLineOption -AddToHistoryHandler $null
            }
            $script:OcpSync.PrevHistoryHandler = $null
        }
    } catch { }
}

# ---------------------- Subcommand framework ------------------------------------
if (-not $script:OcpSub) { $script:OcpSub = @{} }
function Register-OcpCommand {
    param(
        [Parameter(Mandatory)][string]$Name,
        [Parameter(Mandatory)][string]$Help,
        [Parameter(Mandatory)][scriptblock]$Action
    )
    $script:OcpSub[$Name.ToLower()] = @{ Help = $Help; Action = $Action }
}

function Show-OcpUsage {
    Write-Host "Usage:" -ForegroundColor Gray
    Write-Host "  ocp <cluster> [usernameOrToken]" -ForegroundColor Gray
    Write-Host ""
    Write-Host "Commands:" -ForegroundColor Gray

    $maxLen = ($script:OcpSub.Keys | Measure-Object -Maximum Length).Maximum

    $script:OcpSub.Keys |
        Sort-Object |
        ForEach-Object {
            $cmd  = $_
            $help = $script:OcpSub[$cmd].Help
            Write-Host ("  ocp {0}{1}        {2}" -f $cmd, (' ' * ($maxLen - $cmd.Length)), $help) -ForegroundColor Gray
        }
}

# ---------------------- Caches + TTLs -------------------------------------------
$script:Cache = @{
    Ns        = @{ Data=@(); Ns=''; At=[datetime]0; Ttl=([timespan]::FromSeconds(180)) }
    Pods      = @{ Data=@(); Ns=''; At=[datetime]0; Ttl=([timespan]::FromSeconds(90))  }
    Routes    = @{ Data=@(); Ns=''; At=[datetime]0; Ttl=([timespan]::FromSeconds(120)) }
    Clusters  = @{ Data=@(); At=[datetime]0; Ttl=([timespan]::FromSeconds(300)) }
    Contexts  = @{ Data=@(); At=[datetime]0; Ttl=([timespan]::FromSeconds(300)) } # list of PSCustomObject: Name, ClusterName, Server, Short
}

# ---------------------- Lazy session tags (no oc calls at profile load) ---------
$script:OcpSessionTagsInitialized = $false
function Ensure-OcpSessionTags {
    if ($script:OcpSessionTagsInitialized) { return }
    try {
        if (Test-OcpLoggedIn) {
            # Namespace (safe when logged in)
            $initNs = Get-OcpCurrentNamespace
            if ($initNs) { Set-OcpNamespaceTag $initNs }

            # Cluster short from server
            $server   = (& oc whoami --show-server 2>$null)
            $inferred = Get-OcpShortFromServer $server
            if ($inferred) { Set-OcpClusterTag $inferred }
        } else {
            # Not logged in -> no prompt tags
            Clear-OcpClusterTag
            Clear-OcpNamespaceTag
        }
    } catch { }
    $script:OcpSessionTagsInitialized = $true

    # Lazily start external sync only after first ocp usage
    if (-not $script:OcpSync.Started) { Start-OcpExternalSync }
}

# ---------------------- Helpers: current namespace & warmers ---------------------
# Refresh script-scoped config from environment (live overrides)
function Resolve-OcpConfigFromEnv {
    if ($env:OCP_API_SCHEME)        { $script:OcpServer.Scheme       = $env:OCP_API_SCHEME }
    if ($env:OCP_DOMAIN_SUFFIX)     { $script:OcpServer.DomainSuffix = $env:OCP_DOMAIN_SUFFIX }
    if ($null -ne $env:OCP_API_PORT -and $env:OCP_API_PORT -ne '') {
        try { $script:OcpServer.Port = [int]$env:OCP_API_PORT } catch { }
    }
    if ($env:OCP_SERVER_REGEX)      { $script:OcpServer.ServerRegex  = $env:OCP_SERVER_REGEX }
}

function Test-OcpLoggedIn {
    try {
        & oc whoami 1>$null 2>$null
        return ($LASTEXITCODE -eq 0)
    } catch { return $false }
}

function Get-OcpCurrentNamespace {
    $ns = (& oc project -q 2>$null)
    if ($ns -and $ns.Trim().Length -gt 0) { return $ns.Trim() }
    return $null
}

function Update-OcpNsCache {
    $namesText = & oc get projects -o jsonpath='{range .items[*]}{.metadata.name}{"`n"}{end}' 2>$null
    if (-not $namesText) {
        $namesText = & oc get projects -o custom-columns=NAME:.metadata.name --no-headers 2>$null
    }
    $names = @()
    if ($namesText) {
        $names = $namesText -split "(`r`n|`n|`r)" | Where-Object { $_ -and $_.Trim().Length -gt 0 } | Sort-Object -Unique
    }
    if (-not $names -or -not $names.Count) { $names = @('') }
    $script:Cache.Ns.Data = $names
    $script:Cache.Ns.At   = Get-Date
}

function Update-OcpPodsCache {
    $ns = Get-OcpCurrentNamespace
    if (-not $ns) { return }
    $namesText = & oc get pods -n $ns -o jsonpath='{range .items[*]}{.metadata.name}{"`n"}{end}' 2>$null
    if (-not $namesText) {
        $namesText = & oc get pods -n $ns -o custom-columns=NAME:.metadata.name --no-headers 2>$null
    }
    $pods = @()
    if ($namesText) {
        $pods = $namesText -split "(`r`n|`n|`r)" | Where-Object { $_ -and $_.Trim().Length -gt 0 } | Sort-Object -Unique
    }
    $script:Cache.Pods.Data = $pods
    $script:Cache.Pods.Ns   = $ns
    $script:Cache.Pods.At   = Get-Date
}

function Update-OcpRoutesCache {
    $ns = Get-OcpCurrentNamespace
    if (-not $ns) { return }
    $namesText = & oc get routes -n $ns -o jsonpath='{range .items[*]}{.metadata.name}{"`n"}{end}' 2>$null
    if (-not $namesText) {
        $namesText = & oc get routes -n $ns -o custom-columns=NAME:.metadata.name --no-headers 2>$null
    }
    $routes = @()
    if ($namesText) {
        $routes = $namesText -split "(`r`n|`n|`r)" | Where-Object { $_ -and $_.Trim().Length -gt 0 } | Sort-Object -Unique
    }
    $script:Cache.Routes.Data = $routes
    $script:Cache.Routes.Ns   = $ns
    $script:Cache.Routes.At   = Get-Date
}

# -------- Contexts: list + switch + infer short cluster from server -------------
function Update-OcpContextsCache {
    $json = & oc config view -o json 2>$null
    if (-not $json) { return }
    try {
        $cfg = $json | ConvertFrom-Json
        $clusterByName = @{}
        foreach ($cl in ($cfg.clusters | Where-Object { $_ })) {
            $clusterByName[$cl.name] = $cl.cluster.server
        }
        $list = @()
        foreach ($ctx in ($cfg.contexts | Where-Object { $_ })) {
            $name = $ctx.name
            $clName = $ctx.context.cluster
            $server = if ($clusterByName.ContainsKey($clName)) { $clusterByName[$clName] } else { $null }
            $short = Get-OcpShortFromServer $server

            $list += [pscustomobject]@{
                Name        = $name
                ClusterName = $clName
                Server      = $server
                Short       = $short
            }
        }
        $script:Cache.Contexts.Data = $list
        $script:Cache.Contexts.At   = Get-Date
    } catch { }
}

function Get-OcpContextsCached {
    if ( (Get-Date) - $script:Cache.Contexts.At -lt $script:Cache.Contexts.Ttl -and
         $script:Cache.Contexts.Data -and $script:Cache.Contexts.Data.Count ) {
        return $script:Cache.Contexts.Data
    }
    Update-OcpContextsCache
    return $script:Cache.Contexts.Data
}

# ---------------------- Cached getters (use TTLs) --------------------------------
function Get-OcpNamespacesCached {
    if ((Get-Date) - $script:Cache.Ns.At -lt $script:Cache.Ns.Ttl -and $script:Cache.Ns.Data.Count) { return $script:Cache.Ns.Data }
    Update-OcpNsCache; return $script:Cache.Ns.Data
}
function Get-OcpPodsCached([string]$Namespace) {
    if ($Namespace -eq $script:Cache.Pods.Ns -and (Get-Date) - $script:Cache.Pods.At -lt $script:Cache.Pods.Ttl -and $script:Cache.Pods.Data.Count) { return $script:Cache.Pods.Data }
    Update-OcpPodsCache; return $script:Cache.Pods.Data
}
function Get-OcpRoutesCached([string]$Namespace) {
    if ($Namespace -eq $script:Cache.Routes.Ns -and (Get-Date) - $script:Cache.Routes.At -lt $script:Cache.Routes.Ttl -and $script:Cache.Routes.Data.Count) { return $script:Cache.Routes.Data }
    Update-OcpRoutesCache; return $script:Cache.Routes.Data
}
function Get-OcpClustersCached {
    if ((Get-Date) - $script:Cache.Clusters.At -lt $script:Cache.Clusters.Ttl -and $script:Cache.Clusters.Data.Count) { return $script:Cache.Clusters.Data }
    $cfgJson = & oc config view -o json 2>$null
    if (-not $cfgJson) { return $script:Cache.Clusters.Data }
    $cfg = $cfgJson | ConvertFrom-Json
    $vals = @()
    foreach ($c in $cfg.clusters) {
        $srv   = $c.cluster.server
        $short = Get-OcpShortFromServer $srv
        if ($short) { $vals += $short }
    }
    $vals = $vals | Sort-Object -Unique
    $script:Cache.Clusters = @{ Data=$vals; At=Get-Date; Ttl=$script:Cache.Clusters.Ttl }
    return $vals
}

# ---------------------- Shared helpers for logs/tail ----------------------------
function Complete-OcpPods {
    param([string]$WordToComplete)
    $ns = Get-OcpCurrentNamespace
    if (-not $ns) { return @('') }
    $pods = Get-OcpPodsCached $ns
    if (-not $pods -or -not $pods.Count) { return @('') }
    $needle = if ($null -ne $WordToComplete) { $WordToComplete } else { '' }
    $pods | Where-Object { $_ -like "$needle*" }
}

function Invoke-OcpLogs {
    param(
        [Parameter(Mandatory)][string]$Pod,
        [string[]]$ExtraArgs,
        [switch]$Follow
    )
    $ns = Get-OcpCurrentNamespace
    if (-not $ns) { Write-Warning "No current namespace; run 'ocp ns <name>' first."; return }

    $known = Get-OcpPodsCached $ns
    if ($known.Count -eq 0) { Write-Warning "No pods visible in namespace '$ns'."; return }
    elseif ($known -notcontains $Pod) { Write-Host "Tip: pod '$Pod' not found in '$ns'. Try Tab on 'ocp logs <TAB>' or 'ocp tail <TAB>'." -ForegroundColor DarkGray }

    $args = @('logs', $Pod, '-n', $ns)
    if ($Follow) { $args += '-f' }
    if ($ExtraArgs) { $args += $ExtraArgs }
    & oc @args
}

# ---------------------- Built-in subcommands ------------------------------------
Register-OcpCommand -Name 'logout' -Help 'oc logout + clear prompt tags.' -Action {
    try { & oc logout | Out-Null } catch { }
    if ($LASTEXITCODE -eq 0) {
        Stop-OcpExternalSync
        Clear-OcpClusterTag
        Clear-OcpNamespaceTag
        $script:OcpSessionTagsInitialized = $false
        Write-Host "Logged out."
    } else { Write-Warning "oc logout failed ($LASTEXITCODE)." }
}

Register-OcpCommand -Name 'who' -Help 'Show current user, server, and namespace.' -Action {
    $u  = (& oc whoami 2>$null)
    $sv = (& oc whoami --show-server 2>$null)
    $ns = (& oc project -q 2>$null)
    Write-Host "User:      " -NoNewline; Write-Host ($(if ($u)  { $u }  else { '<unknown>' })) -ForegroundColor Cyan
    Write-Host "Server:    " -NoNewline; Write-Host ($(if ($sv) { $sv } else { '<unknown>' })) -ForegroundColor Cyan
    Write-Host "Namespace: " -NoNewline; Write-Host ($(if ($ns) { $ns } else { '<none>'    })) -ForegroundColor Cyan
}

Register-OcpCommand -Name 'ns' -Help 'Switch namespace (project).' -Action {
    param([Parameter(Mandatory)][string]$Name)
    & oc project $Name
    if ($LASTEXITCODE -eq 0) {
        Write-Host "Namespace set to " -NoNewline
        Write-Host $Name -ForegroundColor Cyan
        Set-OcpNamespaceTag $Name
        $script:OcpSessionTagsInitialized = $true
        Update-OcpPodsCache
        Update-OcpRoutesCache
    }
}

Register-OcpCommand -Name 'logs' -Help 'Logs from a pod. Usage: ocp logs <pod> [-- extra oc logs args]' -Action {
    param(
        [Parameter(Mandatory)][string]$Pod,
        [Parameter(ValueFromRemainingArguments=$true)][string[]]$Rest
    )
    Invoke-OcpLogs -Pod $Pod -ExtraArgs $Rest
}

Register-OcpCommand -Name 'tail' -Help 'Tail logs from a pod. Usage: ocp tail <pod>' -Action {
    param([Parameter(Mandatory)][string]$Pod)
    Write-Host "Tailing logs for $Pod..." -ForegroundColor Cyan
    Invoke-OcpLogs -Pod $Pod -Follow
}

Register-OcpCommand -Name 'route' -Help 'Open route URL in browser. Usage: ocp route <route-name>' -Action {
    param([Parameter(Mandatory)][string]$RouteName)
    $ns = Get-OcpCurrentNamespace
    if (-not $ns) { Write-Warning "No current namespace; run 'ocp ns <name>' first."; return }

    $routeHost = & oc get route $RouteName -n $ns -o jsonpath='{.spec.host}' 2>$null
    if (-not $routeHost) { Write-Warning "Route '$RouteName' not found in namespace '$ns'."; return }
    $tls = & oc get route $RouteName -n $ns -o jsonpath='{.spec.tls.termination}' 2>$null
    $url = if ($tls) { "https://$routeHost" } else { "http://$routeHost" }
    Write-Host "Opening $url ..." -ForegroundColor Cyan
    Start-Process $url
}

# --------- Context switching (list + switch + prompt update) -------------------
Register-OcpCommand -Name 'ctx' -Help 'List or switch kube contexts. Usage: ocp ctx [name|shortCluster]' -Action {
    param([string]$Target)

    function Show-Contexts {
        $cur  = (& oc config current-context 2>$null)
        $rows = Get-OcpContextsCached
        if (-not $rows -or $rows.Count -eq 0) {
            Write-Warning "No contexts found in kubeconfig."
            return
        }

        # Determine padding for the [short] column
        $shorts    = $rows | ForEach-Object { if ($_.Short) { $_.Short } else { '-' } }
        $maxShort  = ($shorts | Measure-Object -Maximum Length).Maximum

        # Sort by Short first (blank last), then by Name
        $sorted = $rows | Sort-Object @{
            Expression = { if ([string]::IsNullOrEmpty($_.Short)) { '~' } else { $_.Short } }
        }, @{ Expression = { $_.Name } }

        foreach ($r in $sorted) {
            $mark        = if ($r.Name -eq $cur) { '*' } else { ' ' }
            $short       = if ($r.Short) { $r.Short } else { '-' }
            $shortPadded = $short.PadRight($maxShort)
            Write-Host ("{0}  [{1}]  {2}" -f $mark, $shortPadded, $r.Name) -ForegroundColor Gray
        }
    }

    if (-not $Target) { Show-Contexts; return }

    $rows = Get-OcpContextsCached
    if (-not $rows -or $rows.Count -eq 0) { Write-Warning "No contexts available."; return }

    # Resolve: exact context name or by Short cluster token (e.g., rm3). Prefer exact match.
    $match = $rows | Where-Object { $_.Name -ieq $Target } | Select-Object -First 1
    if (-not $match) {
        $cands = $rows | Where-Object { $_.Short -and ($_.Short -like "$Target*") }
        if ($cands.Count -gt 1) {
            Write-Host "Multiple contexts match short cluster '$Target':" -ForegroundColor Yellow
            $cands | ForEach-Object { Write-Host ("  {0}  [{1}]" -f $_.Name, $_.Short) -ForegroundColor Gray }
            return
        } elseif ($cands.Count -eq 1) {
            $match = $cands[0]
        }
    }

    if (-not $match) { Write-Warning "No context matching '$Target'."; return }

    & oc config use-context $match.Name
    if ($LASTEXITCODE -ne 0) { Write-Warning "Failed to switch context to '$($match.Name)'."; return }

    # Update prompt tags from the selected context:
    if (Test-OcpLoggedIn) {
        $short = if ($match.Short) { $match.Short } else { Get-OcpShortFromServer $match.Server }
        if ($short) { Set-OcpClusterTag $short } else { Clear-OcpClusterTag }

        $curNs = Get-OcpCurrentNamespace
        if ($curNs) { Set-OcpNamespaceTag $curNs } else { Clear-OcpNamespaceTag }
    } else {
        Clear-OcpClusterTag
        Clear-OcpNamespaceTag
    }

    Update-OcpNsCache
    Update-OcpPodsCache
    Update-OcpRoutesCache

    $script:OcpSessionTagsInitialized = $true

    Write-Host ("Switched context to {0} [{1}]" -f $match.Name, ($(if ($short){$short}else{'-'}))) -ForegroundColor Cyan
}

Register-OcpCommand -Name 'refresh' -Help 'Refresh cached lists. Usage: ocp refresh [ns|pods|routes|contexts|all]' -Action {
    param([string]$What = 'all')
    switch ($What.ToLower()) {
        'ns'        { Update-OcpNsCache }
        'pods'      { Update-OcpPodsCache }
        'routes'    { Update-OcpRoutesCache }
        'contexts'  { Update-OcpContextsCache }
        default     { Update-OcpNsCache; Update-OcpPodsCache; Update-OcpRoutesCache; Update-OcpContextsCache }
    }
    Write-Host "Refreshed '$What' cache(s)." -ForegroundColor DarkGray
}

Register-OcpCommand -Name 'help' -Help 'Show usage.' -Action { Show-OcpUsage }

# ---------------------- Command dispatcher (login or subcommand) ----------------
function ocp {
    [CmdletBinding()]
    param([Parameter(ValueFromRemainingArguments = $true)][string[]] $ArgumentList)

    # Lazy init: do not run 'oc' until ocp is actually used
    Ensure-OcpSessionTags

    # Require domain suffix before any ocp operation
    try { Assert-OcpDomainSuffix } catch { return }

    if (-not $ArgumentList -or $ArgumentList.Count -eq 0) { Show-OcpUsage; return }

    $first = $ArgumentList[0]
    $rest  = @($ArgumentList | Select-Object -Skip 1)
    $key   = $first.ToLower()

    # Guard: if user typed an 'oc' verb after ocp, nudge them
    $reservedFirst = @(
        'get','describe','delete','apply','create','edit','scale','expose','port-forward','top',
        'deploy','dc','pod','pods','svc','service','services','route','routes',
        'cm','configmap','secret','ns','namespace','project','projects','node','nodes'
    )
    if ($first -in $reservedFirst -and -not $script:OcpSub.ContainsKey($key)) {
        Write-Warning "Looks like an 'oc' command. Use: oc $($ArgumentList -join ' ')"
        return
    }

    if ($script:OcpSub.ContainsKey($key)) {
        $action = $script:OcpSub[$key].Action
        & $action @rest
        return
    }

    # Login flow: ocp <cluster> [usernameOrToken]
    $Cluster  = $ArgumentList[0]
    $rest     = @($ArgumentList | Select-Object -Skip 1)

    $candidate = if ($rest.Count -ge 1) { $rest[0] } else { $null }
    $useToken  = ($candidate -and ($candidate -like 'sha256~*'))

    if ($useToken) {
        $displayUser = "token (sha256~$(([string]$candidate).Substring(7,4))…)"
        $authArgs    = @("--token=$candidate")
    } else {
        $Username    = if ($candidate) { $candidate } else { $env:USERNAME }
        $displayUser = $Username
        $authArgs    = @("--username=$Username")
    }

    $server = Get-OcpApiServerUrl $Cluster
    Write-Host "Logging in to $server as $displayUser ..."

    $ocArgs = @('login', "--server=$server") + $authArgs
    & oc @ocArgs
    $exit = $LASTEXITCODE

    if ($exit -eq 0) {
        Set-OcpClusterTag $Cluster
        $curNs = Get-OcpCurrentNamespace
        if ($curNs) { Set-OcpNamespaceTag $curNs } else { Clear-OcpNamespaceTag }
        $script:OcpSessionTagsInitialized = $true
        Update-OcpNsCache
        Update-OcpPodsCache
        Update-OcpRoutesCache
        Update-OcpContextsCache
        Write-Host "Login successful."
    } else {
        Write-Warning "Login failed (exit code $exit)."
    }
}

# ---------------------- Tab completion for ocp ----------------------------------
Register-ArgumentCompleter -CommandName ocp -ParameterName ArgumentList -ScriptBlock {
    param($commandName,$parameterName,$wordToComplete,$commandAst,$fakeBoundParameters)

    # Lazy init on first Tab press; still no calls at profile load
    Ensure-OcpSessionTags

    $tokens = @(); foreach ($e in $commandAst.CommandElements) { $tokens += $e.Extent.Text }

    function _cr([string[]]$items,[string]$word,[string]$hint){
        $needle = if ($null -ne $word) { $word } else { '' }
        $hits = $items | Where-Object { $_ -like "$needle*" }
        if (-not $hits -or -not $hits.Count) {
            return ,([System.Management.Automation.CompletionResult]::new($needle,$needle,'ParameterValue',''))
        }
        $hits | ForEach-Object {
            [System.Management.Automation.CompletionResult]::new($_,$_, 'ParameterValue', "$hint $_")
        }
    }

    $subs = @('logout','who','ns','logs','tail','route','ctx','refresh','help')
    $reservedFirst = @(
        'get','describe','delete','apply','create','edit','scale','expose','port-forward','top',
        'deploy','dc','pod','pods','svc','service','services','route','routes',
        'cm','configmap','secret','ns','namespace','project','projects','node','nodes'
    )

    # First arg after 'ocp' -> suggest clusters unless it's a known subcommand OR a reserved oc word
    if ($tokens.Count -le 2) {
        $first = if ($tokens.Count -ge 2) { $tokens[1] } else { $wordToComplete }
        if ($null -eq $first -or ( ($first -notin $subs) -and ($first -notin $reservedFirst) )) {
            $clusters = Get-OcpClustersCached
            return _cr $clusters $wordToComplete 'cluster'
        }
    }

    if ($tokens.Count -ge 2) {
        switch ($tokens[1].ToLower()) {
            'ns' {
                $names = Get-OcpNamespacesCached
                return _cr $names $wordToComplete 'namespace'
            }
            'logs' {
                $pods = Complete-OcpPods -WordToComplete $wordToComplete
                return _cr $pods $wordToComplete 'pod'
            }
            'tail' {
                $pods = Complete-OcpPods -WordToComplete $wordToComplete
                return _cr $pods $wordToComplete 'pod'
            }
            'route' {
                $ns = Get-OcpCurrentNamespace
                $routes = Get-OcpRoutesCached $ns
                return _cr $routes $wordToComplete 'route'
            }
            'ctx' {
                $rows = Get-OcpContextsCached
                # Sort to mirror list order: short first (blank last), then name
                $rows = $rows | Sort-Object @{
                    Expression = { if ([string]::IsNullOrEmpty($_.Short)) { '~' } else { $_.Short } }
                }, @{ Expression = { $_.Name } }

                $needle = if ($null -ne $wordToComplete) { $wordToComplete } else { '' }
                $out = @()
                foreach ($r in $rows) {
                    $name  = $r.Name
                    $short = if ($r.Short) { $r.Short } else { '-' }
                    if ($name -like "$needle*" -or ($short -ne '-' -and $short -like "$needle*")) {
                        $out += [System.Management.Automation.CompletionResult]::new($name,$name,'ParameterValue',"cluster $short")
                    }
                }
                if ($out.Count -gt 0) { return $out }
                return ,([System.Management.Automation.CompletionResult]::new($needle,$needle,'ParameterValue',''))
            }
            'refresh' {
                return _cr @('ns','pods','routes','contexts','all') $wordToComplete 'cache'
            }
        }
    }

    @()
}
# =====================  END: OCP script  =======================================
