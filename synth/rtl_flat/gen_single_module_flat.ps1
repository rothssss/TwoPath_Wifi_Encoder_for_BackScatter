param(
    [string]$SourceFile = "synth/rtl_flat/multi_mode_tx_baseband_flat_multimodule.v",
    [string]$OutputFile = "synth/rtl_flat/multi_mode_tx_baseband_flat.v",
    [string]$TopModule  = "multi_mode_tx_baseband"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = "Stop"

function Replace-Word {
    param(
        [string]$Text,
        [string]$Name,
        [string]$Replacement
    )
    $pattern = "(?<![A-Za-z0-9_$.]){0}(?![A-Za-z0-9_$])" -f [regex]::Escape($Name)
    return [regex]::Replace($Text, $pattern, [System.Text.RegularExpressions.MatchEvaluator]{ param($m) $Replacement })
}

function Parse-ParamBlock {
    param([string]$Text)
    $map = @{}
    if ([string]::IsNullOrWhiteSpace($Text)) { return $map }
    $re = [regex]'parameter\b(?:\s+integer\b)?(?:\s*\[[^\]]+\])?\s+([A-Za-z_][A-Za-z0-9_$]*)\s*=\s*([^,\r\n]+)'
    foreach ($m in $re.Matches($Text)) {
        $map[$m.Groups[1].Value] = $m.Groups[2].Value.Trim()
    }
    return $map
}

function Parse-PortNames {
    param([string]$Text)
    $names = New-Object System.Collections.Generic.List[string]
    if ([string]::IsNullOrWhiteSpace($Text)) { return $names }
    $re = [regex]'(?m)^\s*(?:input|output|inout)\b[^;\n]*?\b([A-Za-z_][A-Za-z0-9_$]*)\b(?=\s*(?:,|//|$))'
    foreach ($m in $re.Matches($Text)) {
        $name = $m.Groups[1].Value
        if (-not $names.Contains($name)) { [void]$names.Add($name) }
    }
    return $names
}

function Parse-DeclaredNames {
    param([string]$Body)
    $names = New-Object System.Collections.Generic.List[string]

    foreach ($m in [regex]::Matches($Body, '(?ms)^\s*localparam\b(.*?);')) {
        foreach ($n in [regex]::Matches($m.Groups[1].Value, '([A-Za-z_][A-Za-z0-9_$]*)\s*=')) {
            $name = $n.Groups[1].Value
            if (-not $names.Contains($name)) { [void]$names.Add($name) }
        }
    }

    foreach ($m in [regex]::Matches($Body, '(?ms)^\s*(?:reg|wire|integer)\b(?:\s+(?:signed|unsigned))?(?:\s*\[[^\]]+\])?\s*(.*?);')) {
        $declText = $m.Groups[1].Value
        if ($declText -match '=') {
            if ($declText -match '^\s*([A-Za-z_][A-Za-z0-9_$]*)\b') {
                $name = $matches[1]
                if (-not $names.Contains($name)) { [void]$names.Add($name) }
            }
        } else {
            foreach ($part in ($declText -split ',')) {
                $piece = $part.Trim()
                if ($piece -match '^([A-Za-z_][A-Za-z0-9_$]*)\b') {
                    $name = $matches[1]
                    if (-not $names.Contains($name)) { [void]$names.Add($name) }
                }
            }
        }
    }

    foreach ($m in [regex]::Matches($Body, '(?m)^\s*function\b(?:\s+\[[^\]]+\])?\s*([A-Za-z_][A-Za-z0-9_$]*)\s*;')) {
        $name = $m.Groups[1].Value
        if (-not $names.Contains($name)) { [void]$names.Add($name) }
    }

    return $names
}

function Parse-NamedArgs {
    param([string]$Text)
    $map = @{}
    if ([string]::IsNullOrWhiteSpace($Text)) { return $map }
    $re = [regex]'(?ms)\.([A-Za-z_][A-Za-z0-9_$]*)\s*\(\s*(.*?)\s*\)\s*(?:,|$)'
    foreach ($m in $re.Matches($Text)) {
        $map[$m.Groups[1].Value] = $m.Groups[2].Value.Trim()
    }
    return $map
}

function Convert-Module {
    param(
        [hashtable]$Modules,
        [string]$ModuleName,
        [string]$Prefix,
        [hashtable]$ParamMap,
        [hashtable]$ConnMap
    )

    $mod  = $Modules[$ModuleName]
    $body = $mod.Body

    $locals = Parse-DeclaredNames $body | Where-Object {
        (-not $mod.ParamDefaults.ContainsKey($_)) -and (-not $mod.Ports.Contains($_))
    }
    foreach ($name in $locals) {
        $body = Replace-Word $body $name ("{0}__{1}" -f $Prefix, $name)
    }

    foreach ($paramName in $mod.ParamDefaults.Keys) {
        $value = if ($ParamMap.ContainsKey($paramName)) { $ParamMap[$paramName] } else { $mod.ParamDefaults[$paramName] }
        $body = Replace-Word $body $paramName $value
    }

    foreach ($portName in $mod.Ports) {
        if ($ConnMap.ContainsKey($portName)) {
            $body = Replace-Word $body $portName $ConnMap[$portName]
        }
    }

    $body = Inline-Instances -Modules $Modules -Body $body -Prefix $Prefix
    return @"
// ---------------------------------------------------------------------------
// Inlined $ModuleName instance: $Prefix
// ---------------------------------------------------------------------------
$body
"@
}

function Inline-Instances {
    param(
        [hashtable]$Modules,
        [string]$Body,
        [string]$Prefix
    )

    $modNames = ($Modules.Keys | Where-Object { $_ -ne $TopModule }) -join '|'
    $instRe = [regex]("(?ms)^\s*(?<mod>$modNames)\s*(?:#\((?<params>.*?)\))?\s*(?<inst>[A-Za-z_][A-Za-z0-9_$]*)\s*\((?<conns>.*?)\)\s*;\s*$")

    while ($true) {
        $m = $instRe.Match($Body)
        if (-not $m.Success) { break }

        $childName = $m.Groups['mod'].Value
        $childInst = $m.Groups['inst'].Value
        $childPrefix = "{0}__{1}" -f $Prefix, $childInst

        $paramMap = @{}
        foreach ($k in $Modules[$childName].ParamDefaults.Keys) {
            $paramMap[$k] = $Modules[$childName].ParamDefaults[$k]
        }
        $paramOverrides = Parse-NamedArgs $m.Groups['params'].Value
        foreach ($k in $paramOverrides.Keys) { $paramMap[$k] = $paramOverrides[$k] }

        $connMap = Parse-NamedArgs $m.Groups['conns'].Value
        $inlined = Convert-Module -Modules $Modules -ModuleName $childName -Prefix $childPrefix -ParamMap $paramMap -ConnMap $connMap

        $Body = $Body.Substring(0, $m.Index) + $inlined + $Body.Substring($m.Index + $m.Length)
    }

    return $Body
}

$source = Get-Content -LiteralPath $SourceFile -Raw
$timescaleMatch = [regex]::Match($source, '(?m)^`timescale\s+[^\r\n]+')
$timescale = if ($timescaleMatch.Success) { $timescaleMatch.Value } else { '`timescale 1ns/1ps' }

$moduleRe = [regex]'(?ms)module\s+([A-Za-z_][A-Za-z0-9_$]*)\s*(?:#\((.*?)\))?\s*\((.*?)\);\s*(.*?)\s*endmodule'
$modules = @{}
foreach ($m in $moduleRe.Matches($source)) {
    $name = $m.Groups[1].Value
    $modules[$name] = [ordered]@{
        Name          = $name
        ParamText     = $m.Groups[2].Value.Trim()
        PortText      = $m.Groups[3].Value.Trim()
        Body          = $m.Groups[4].Value.Trim()
        ParamDefaults = Parse-ParamBlock $m.Groups[2].Value
        Ports         = Parse-PortNames $m.Groups[3].Value
    }
}

if (-not $modules.ContainsKey($TopModule)) {
    throw "Top module '$TopModule' not found in $SourceFile"
}

$top = $modules[$TopModule]
$topBody = Inline-Instances -Modules $modules -Body $top.Body -Prefix $TopModule

if ([regex]::IsMatch($topBody, "(?m)^\s*(?:" + (($modules.Keys | Where-Object { $_ -ne $TopModule }) -join '|') + ")\b")) {
    throw "Flattening incomplete: leftover module instantiations remain in top body."
}

$wireToRegReplacements = @(
    @{ Pattern = '(?m)^\s*wire\s+a_fifo_rd_en\s*;\s*$';                    Replacement = '    reg         a_fifo_rd_en;' },
    @{ Pattern = '(?m)^\s*wire\s+a_busy\s*;\s*$';                          Replacement = '    reg         a_busy;' },
    @{ Pattern = '(?m)^\s*wire\s+a_done\s*;\s*$';                          Replacement = '    reg         a_done;' },
    @{ Pattern = '(?m)^\s*wire\s+a_underrun\s*;\s*$';                      Replacement = '    reg         a_underrun;' },
    @{ Pattern = '(?m)^\s*wire\s+\[1:0\]\s+a_base_phase\s*;\s*$';          Replacement = '    reg  [1:0]  a_base_phase;' },
    @{ Pattern = '(?m)^\s*wire\s+\[1:0\]\s+a_delta_phi1\s*;\s*$';          Replacement = '    reg  [1:0]  a_delta_phi1;' },
    @{ Pattern = '(?m)^\s*wire\s+a_update_phi1\s*;\s*$';                   Replacement = '    reg         a_update_phi1;' },
    @{ Pattern = '(?m)^\s*wire\s+a_chip_valid_to_phy\s*;\s*$';             Replacement = '    reg         a_chip_valid_to_phy;' },
    @{ Pattern = '(?m)^\s*wire\s+a_chip_i\s*;\s*$';                        Replacement = '    reg         a_chip_i;' },
    @{ Pattern = '(?m)^\s*wire\s+a_chip_q\s*;\s*$';                        Replacement = '    reg         a_chip_q;' },
    @{ Pattern = '(?m)^\s*wire\s+a_chip_valid_out\s*;\s*$';                Replacement = '    reg         a_chip_valid_out;' },
    @{ Pattern = '(?m)^\s*wire\s+b_fifo_rd_en\s*;\s*$';                    Replacement = '    reg         b_fifo_rd_en;' },
    @{ Pattern = '(?m)^\s*wire\s+b_bit_valid\s*;\s*$';                     Replacement = '    reg         b_bit_valid;' },
    @{ Pattern = '(?m)^\s*wire\s+b_bit_out\s*;\s*$';                       Replacement = '    reg         b_bit_out;' },
    @{ Pattern = '(?m)^\s*wire\s+b_busy\s*;\s*$';                          Replacement = '    reg         b_busy;' },
    @{ Pattern = '(?m)^\s*wire\s+b_done\s*;\s*$';                          Replacement = '    reg         b_done;' },
    @{ Pattern = '(?m)^\s*wire\s+b_underrun\s*;\s*$';                      Replacement = '    reg         b_underrun;' },
    @{ Pattern = '(?m)^\s*wire\s+\[7:0\]\s+path_b_symbol\s*;\s*$';         Replacement = '    reg  [7:0]  path_b_symbol;' },
    @{ Pattern = '(?m)^\s*wire\s+path_b_symbol_valid\s*;\s*$';             Replacement = '    reg         path_b_symbol_valid;' }
)
foreach ($entry in $wireToRegReplacements) {
    $topBody = [regex]::Replace($topBody, $entry.Pattern, $entry.Replacement)
}

$funcRe = [regex]'(?ms)^\s*function\b.*?^\s*endfunction\s*'
$funcBlocks = @($funcRe.Matches($topBody) | ForEach-Object { $_.Value.TrimEnd() })
$topBody = $funcRe.Replace($topBody, '')
$functionSection = if ($funcBlocks.Count -gt 0) {
    ($funcBlocks -join "`r`n`r`n") + "`r`n`r`n"
} else {
    ''
}

$header = @"
// =============================================================================
// multi_mode_tx_baseband_flat.v
//
// Single-module flattened top-level RTL for synthesis handoff / export.
// The helper instances from the original hierarchical design are inlined into
// the top module below. The hierarchical multi-module stitch-up is preserved in
// multi_mode_tx_baseband_flat_multimodule.v for module-level benches.
// =============================================================================
$timescale

module $TopModule $(if ([string]::IsNullOrWhiteSpace($top.ParamText)) { '' } else { "#(`n$($top.ParamText)`n) " })(
$($top.PortText)
);

$functionSection
"@

$output = $header + $topBody.Trim() + "`r`n`r`nendmodule`r`n"
Set-Content -LiteralPath $OutputFile -Value $output -Encoding ascii
