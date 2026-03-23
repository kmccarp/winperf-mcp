[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$params = $input | ConvertFrom-Json
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$warnings = @()
$result = @{}

$adapterName = $null
if ($params.adapterName -and $params.adapterName -ne '') { $adapterName = [string]$params.adapterName }
$includeConnections = $false
if ($params.includeConnections -eq $true) { $includeConnections = $true }
$includeFirewallRules = $false
if ($params.includeFirewallRules -eq $true) { $includeFirewallRules = $true }
$includeWifi = $false
if ($params.includeWifi -eq $true) { $includeWifi = $true }
$testDns = $null
if ($params.testDns -and $params.testDns -ne '') { $testDns = [string]$params.testDns }

# Network adapters
try {
    $ErrorActionPreference = 'SilentlyContinue'
    if ($adapterName) {
        $adapters = @(Get-NetAdapter | Where-Object { $_.Name -like "*$adapterName*" })
    } else {
        $adapters = @(Get-NetAdapter)
    }
    $adapterList = @()
    foreach ($a in $adapters) {
        $adapterList += @{
            name                  = [string]$a.Name
            interface_description = [string]$a.InterfaceDescription
            status                = [string]$a.Status
            link_speed            = [string]$a.LinkSpeed
            media_type            = [string]$a.MediaType
            mac_address           = [string]$a.MacAddress
            interface_index       = [int]$a.InterfaceIndex
        }
    }
    $result['adapters'] = $adapterList
} catch {
    $warnings += "Net adapters: $($_.Exception.Message)"
}

# Network interface performance counters
try {
    $ErrorActionPreference = 'SilentlyContinue'
    $netCounters = @(
        '\Network Interface(*)\Bytes Received/sec',
        '\Network Interface(*)\Bytes Sent/sec',
        '\Network Interface(*)\Packets Received/sec',
        '\Network Interface(*)\Packets Sent/sec',
        '\Network Interface(*)\Output Queue Length'
    )
    $netSamples = Get-Counter -Counter $netCounters -SampleInterval 1 -MaxSamples 1

    $ifaceData = @{}
    foreach ($cs in $netSamples.CounterSamples) {
        $instance = $cs.InstanceName
        if (-not $ifaceData.ContainsKey($instance)) {
            $ifaceData[$instance] = @{}
        }
        $counterName = ($cs.Path -replace '.*\\network interface\([^)]*\)\\', '').ToLower() -replace ' ', '_' -replace '/', '_per_'
        $ifaceData[$instance][$counterName] = [math]::Round($cs.CookedValue, 2)
    }

    # Filter by adapter name if specified
    if ($adapterName) {
        $filtered = @{}
        foreach ($key in $ifaceData.Keys) {
            if ($key -like "*$adapterName*") {
                $filtered[$key] = $ifaceData[$key]
            }
        }
        $result['interface_counters'] = $filtered
    } else {
        $result['interface_counters'] = $ifaceData
    }
} catch {
    $warnings += "Network counters: $($_.Exception.Message)"
}

# TCP/UDP connections
if ($includeConnections) {
    # TCP connections
    try {
        $ErrorActionPreference = 'SilentlyContinue'
        $tcpConns = Get-NetTCPConnection | Select-Object LocalAddress, LocalPort, RemoteAddress, RemotePort, State, OwningProcess

        # Build PID-to-name cache
        $pidCache = @{}
        $allProcs = Get-Process -ErrorAction SilentlyContinue
        foreach ($p in $allProcs) {
            $pidCache[[string]$p.Id] = $p.Name
        }

        $tcpList = @()
        foreach ($c in $tcpConns) {
            $procName = "Unknown"
            if ($pidCache.ContainsKey([string]$c.OwningProcess)) {
                $procName = $pidCache[[string]$c.OwningProcess]
            }
            $tcpList += @{
                local_address  = [string]$c.LocalAddress
                local_port     = [int]$c.LocalPort
                remote_address = [string]$c.RemoteAddress
                remote_port    = [int]$c.RemotePort
                state          = [string]$c.State
                owning_process = [int]$c.OwningProcess
                process_name   = $procName
            }
        }

        # Separate listening ports
        $listening = $tcpList | Where-Object { $_.state -eq 'Listen' }
        $established = $tcpList | Where-Object { $_.state -ne 'Listen' }

        $result['tcp_connections'] = @{
            listening   = @($listening)
            other       = @($established)
            total_count = $tcpList.Count
        }
    } catch {
        $warnings += "TCP connections: $($_.Exception.Message)"
    }

    # UDP endpoints
    try {
        $ErrorActionPreference = 'SilentlyContinue'
        $udpEndpoints = Get-NetUDPEndpoint | Select-Object LocalAddress, LocalPort, OwningProcess

        $udpList = @()
        foreach ($u in $udpEndpoints) {
            $procName = "Unknown"
            if ($pidCache.ContainsKey([string]$u.OwningProcess)) {
                $procName = $pidCache[[string]$u.OwningProcess]
            }
            $udpList += @{
                local_address  = [string]$u.LocalAddress
                local_port     = [int]$u.LocalPort
                owning_process = [int]$u.OwningProcess
                process_name   = $procName
            }
        }
        $result['udp_endpoints'] = $udpList
    } catch {
        $warnings += "UDP endpoints: $($_.Exception.Message)"
    }
}

# Firewall rules
if ($includeFirewallRules) {
    try {
        $ErrorActionPreference = 'SilentlyContinue'
        $fwRules = Get-NetFirewallRule -Enabled True | Select-Object -First 50
        $fwList = @()
        foreach ($rule in $fwRules) {
            $portFilter = $null
            $appFilter = $null
            try {
                $portFilter = $rule | Get-NetFirewallPortFilter -ErrorAction SilentlyContinue
            } catch {}
            try {
                $appFilter = $rule | Get-NetFirewallApplicationFilter -ErrorAction SilentlyContinue
            } catch {}

            $entry = @{
                name         = [string]$rule.Name
                display_name = [string]$rule.DisplayName
                direction    = [string]$rule.Direction
                action       = [string]$rule.Action
                profile      = [string]$rule.Profile
            }

            if ($portFilter) {
                $entry['protocol']   = [string]$portFilter.Protocol
                $entry['local_port'] = [string]$portFilter.LocalPort
                $entry['remote_port'] = [string]$portFilter.RemotePort
            }
            if ($appFilter) {
                $entry['program'] = [string]$appFilter.Program
            }

            $fwList += $entry
        }
        $result['firewall_rules'] = $fwList
    } catch {
        $warnings += "Firewall rules: $($_.Exception.Message)"
    }
}

# WiFi info
if ($includeWifi) {
    try {
        $ErrorActionPreference = 'SilentlyContinue'
        $wlanOutput = & netsh wlan show interfaces 2>&1
        if ($LASTEXITCODE -eq 0) {
            $wifiInfo = @{}
            foreach ($line in $wlanOutput) {
                if ($line -match '^\s+(.+?)\s*:\s*(.+)$') {
                    $key = $Matches[1].Trim() -replace '\s+', '_'
                    $value = $Matches[2].Trim()
                    $wifiInfo[$key.ToLower()] = $value
                }
            }
            $result['wifi'] = $wifiInfo
        } else {
            $warnings += "WiFi: No wireless interfaces found or WLAN service not running."
        }
    } catch {
        $warnings += "WiFi: $($_.Exception.Message)"
    }
}

# DNS test
if ($testDns) {
    try {
        $ErrorActionPreference = 'SilentlyContinue'
        $dnsTime = Measure-Command { $dnsResult = Resolve-DnsName $testDns -ErrorAction Stop }
        $addresses = @()
        foreach ($r in $dnsResult) {
            if ($r.IPAddress) {
                $addresses += [string]$r.IPAddress
            }
        }
        $result['dns_test'] = @{
            query               = $testDns
            resolution_time_ms  = [math]::Round($dnsTime.TotalMilliseconds, 2)
            resolved_addresses  = $addresses
        }
    } catch {
        $warnings += "DNS test: $($_.Exception.Message)"
    }
}

$result['elevated'] = $isAdmin
$result['elevation_warnings'] = $warnings
$result | ConvertTo-Json -Depth 10
