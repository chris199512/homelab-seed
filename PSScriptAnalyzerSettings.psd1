# Settings for PSScriptAnalyzer (used by CI for build.ps1).
@{
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        # Coloured console output is intended; build.ps1 is an interactive script.
        'PSAvoidUsingWriteHost',
        # Stop-Build only prints and exits, it changes no state.
        'PSUseShouldProcessForStateChangingFunctions'
    )
    Rules        = @{
        # Users run Windows PowerShell 5.1 as well as PowerShell 7.
        PSUseCompatibleSyntax = @{
            Enable         = $true
            TargetVersions = @('5.1', '7.0')
        }
    }
}
