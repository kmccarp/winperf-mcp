[Console]::OutputEncoding = [System.Text.Encoding]::UTF8
$params = $input | ConvertFrom-Json
$isAdmin = ([Security.Principal.WindowsPrincipal][Security.Principal.WindowsIdentity]::GetCurrent()).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
$warnings = @()
$result = @{}

$className = if ($null -ne $params.className -and $params.className -ne '') { $params.className } else { $null }
$namespace = if ($null -ne $params.namespace -and $params.namespace -ne '') { $params.namespace } else { 'root/cimv2' }
$properties = if ($null -ne $params.properties -and $params.properties.Count -gt 0) { $params.properties } else { $null }
$filter = if ($null -ne $params.filter -and $params.filter -ne '') { $params.filter } else { $null }
$query = if ($null -ne $params.query -and $params.query -ne '') { $params.query } else { $null }
$maxResults = if ($null -ne $params.maxResults -and $params.maxResults -gt 0) { [int]$params.maxResults } else { 50 }

# Security validation for raw queries
if ($query) {
    $trimmedQuery = $query.Trim()
    if ($trimmedQuery -notmatch '^SELECT\s') {
        $result['error'] = "Query must start with SELECT. Raw query rejected for security."
        $result['elevated'] = $isAdmin
        $result['elevation_warnings'] = $warnings
        $result | ConvertTo-Json -Depth 10
        return
    }

    $dangerousKeywords = @('INSERT', 'UPDATE', 'DELETE', 'EXEC', 'CREATE', 'DROP', 'ALTER', 'INVOKE')
    foreach ($keyword in $dangerousKeywords) {
        if ($trimmedQuery -match "\b$keyword\b") {
            $result['error'] = "Query contains forbidden keyword '$keyword'. Rejected for security."
            $result['elevated'] = $isAdmin
            $result['elevation_warnings'] = $warnings
            $result | ConvertTo-Json -Depth 10
            return
        }
    }
}

try {
    $cimResults = $null

    if ($query) {
        $cimResults = Get-CimInstance -Query $query -Namespace $namespace -ErrorAction Stop |
            Select-Object -First $maxResults
    } elseif ($className) {
        $cimParams = @{
            ClassName   = $className
            Namespace   = $namespace
            ErrorAction = 'Stop'
        }
        if ($filter) {
            $cimParams['Filter'] = $filter
        }
        $cimResults = Get-CimInstance @cimParams

        if ($properties) {
            $cimResults = $cimResults | Select-Object $properties
        }
        $cimResults = $cimResults | Select-Object -First $maxResults
    } else {
        $result['error'] = "Either 'className' or 'query' must be provided."
        $result['elevated'] = $isAdmin
        $result['elevation_warnings'] = $warnings
        $result | ConvertTo-Json -Depth 10
        return
    }

    # Convert results to list of hashtables
    $resultList = @()
    foreach ($item in $cimResults) {
        $entry = @{}
        $item.PSObject.Properties | ForEach-Object {
            # Skip CIM internal properties
            if ($_.Name -notmatch '^(Cim|PS)') {
                $val = $_.Value
                # Convert DateTime objects to ISO string
                if ($val -is [DateTime]) {
                    $val = $val.ToString('o')
                }
                $entry[$_.Name] = $val
            }
        }
        $resultList += $entry
    }

    $result['results'] = $resultList
    $result['result_count'] = $resultList.Count
    $result['namespace'] = $namespace
    if ($className) { $result['class_name'] = $className }
    if ($query) { $result['query'] = $query }

} catch {
    $warnings += "CIM query failed: $_"
    $result['results'] = @()
    $result['result_count'] = 0
}

$result['elevated'] = $isAdmin
$result['elevation_warnings'] = $warnings
$result | ConvertTo-Json -Depth 10
