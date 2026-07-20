# Catches the class of bug that ParseFile cannot.
#
# In PowerShell, `(if ($x) { 'a' } else { 'b' })` is SYNTACTICALLY VALID - it
# parses as "invoke a command named `if` with three arguments". It only explodes
# at runtime with "The term 'if' is not recognized as a cmdlet...", which in the
# Station means the whole UI fails to start. A syntax check passes it happily.
#
# The correct form is the subexpression operator: $(if ($x) { 'a' } else { 'b' }).
#
# This walks the AST for CommandAst nodes whose command name is a language
# keyword, which is always this mistake.
#
# ASCII only on purpose: PowerShell 5.1 reads a BOM-less .ps1 as ANSI, so a
# stray em-dash in a string literal breaks the parse.
#
# Run: powershell -NoProfile -File lint-ui.ps1

$ErrorActionPreference = 'Stop'
$target = Join-Path $PSScriptRoot 'ui.ps1'

$tokens = $null; $errors = $null
$ast = [System.Management.Automation.Language.Parser]::ParseFile($target, [ref]$tokens, [ref]$errors)

if ($errors.Count) {
    Write-Host "Syntax errors:" -ForegroundColor Red
    $errors | Select-Object -First 10 | ForEach-Object {
        Write-Host ("  {0}: {1}" -f $_.Extent.StartLineNumber, $_.Message)
    }
    exit 1
}

# Keywords that can never legitimately be a command name.
$keywords = @('if','elseif','else','foreach','while','do','switch','try','catch','finally','for','until')

$commands = $ast.FindAll({
    param($n) $n -is [System.Management.Automation.Language.CommandAst]
}, $true)

$bad = @()
foreach ($c in $commands) {
    $name = $null
    try { $name = $c.GetCommandName() } catch { }
    if ($name -and $keywords -contains $name.ToLowerInvariant()) {
        $bad += [pscustomobject]@{
            Line = $c.Extent.StartLineNumber
            Text = $c.Extent.Text -replace '\s+', ' '
        }
    }
}

if ($bad.Count) {
    Write-Host "$($bad.Count) keyword-as-command bug(s) - these throw at runtime:" -ForegroundColor Red
    foreach ($b in $bad) {
        $snippet = $b.Text
        if ($snippet.Length -gt 100) { $snippet = $snippet.Substring(0, 100) + '...' }
        Write-Host ("  line {0}: {1}" -f $b.Line, $snippet)
    }
    Write-Host ""
    Write-Host 'Fix: wrap in the subexpression operator - $(if (...) { } else { })' -ForegroundColor Yellow
    exit 1
}

Write-Host "ui.ps1 clean: no keyword-as-command bugs, no syntax errors." -ForegroundColor Green
exit 0
