# Used by CI and locally: Invoke-ScriptAnalyzer -Path scripts -Recurse -Settings ./PSScriptAnalyzerSettings.psd1
@{
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        # Interactive CLI: progress text must reach the console, never the pipeline.
        'PSAvoidUsingWriteHost'
        # The scripts implement their own -DryRun; -WhatIf/-Confirm would duplicate it.
        'PSUseShouldProcessForStateChangingFunctions'
        # False positive: script params read inside functions (e.g. $User) are flagged.
        'PSReviewUnusedParameter'
        # False positive with Pester BeforeAll/It scoping in tests.
        'PSUseDeclaredVarsMoreThanAssignments'
    )
}
