# Settings for PSScriptAnalyzer (used by .github/workflows/ci.yml).
@{
    Severity     = @('Error', 'Warning')
    ExcludeRules = @(
        # The scripts talk to the person at the keyboard, in colour, on purpose.
        'PSAvoidUsingWriteHost',
        # Secrets generated here have to reach Blossom CRM as text; they are
        # converted in memory and shown once (see docs/security.md).
        'PSAvoidUsingConvertToSecureStringWithPlainText',
        'PSAvoidUsingPlainTextForPassword',
        'PSAvoidUsingUsernameAndPasswordParams',
        # Helper functions named after what they do, not after approved verbs only.
        'PSUseShouldProcessForStateChangingFunctions',
        'PSUseSingularNouns'
    )
    Rules        = @{
        PSUseCompatibleSyntax = @{
            Enable         = $true
            TargetVersions = @('5.1')
        }
    }
}
