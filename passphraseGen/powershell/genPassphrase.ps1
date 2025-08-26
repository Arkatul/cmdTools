[CmdletBinding()]
param(
    [int]$NumWords = 4,
    [int]$NumSpecials = 2,
    [int]$NumDigits = 2,
    [string]$AllowedSpecials = '!@#%&*',
    [string]$Separators = '-_:.',
    [ValidateSet(1,2,3,4,5)]
    [int]$CaseProfile = 3
)

function Get-RandomChars {
    param(
        [string]$Set,
        [int]$Count
    )
    $out = ''
    for ($i = 0; $i -lt $Count; $i++) {
        $out += $Set.Substring((Get-Random -Minimum 0 -Maximum $Set.Length),1)
    }
    return $out
}

$Words = Invoke-RestMethod -Uri "https://random-word-api.vercel.app/api?words=$NumWords"

switch ($CaseProfile) {
    1 { $Words = $Words | ForEach-Object { $_.ToLower() } }
    2 { $Words = $Words | ForEach-Object { $_.ToUpper() } }
    3 {
        $Words = $Words | ForEach-Object {
            if ((Get-Random -Minimum 0 -Maximum 2) -eq 0) { $_.ToLower() } else { $_.ToUpper() }
        }
    }
    4 {
        $Words = $Words | ForEach-Object {
            $word = $_.ToLower()
            $index = Get-Random -Minimum 0 -Maximum $word.Length
            $word.Substring(0,$index) + $word[$index].ToString().ToUpper() + $word.Substring($index+1)
        }
    }
    5 {
        $Words = $Words | ForEach-Object {
            ($_.ToCharArray() | ForEach-Object {
                if ((Get-Random -Minimum 0 -Maximum 2) -eq 0) { $_.ToString().ToLower() } else { $_.ToString().ToUpper() }
            }) -join ''
        }
    }
}

$Sep = $Separators[(Get-Random -Minimum 0 -Maximum $Separators.Length)]
$JoinedWords = $Words -join $Sep

$PrefixSpecials = Get-RandomChars -Set $AllowedSpecials -Count $NumSpecials
$chars = $PrefixSpecials.ToCharArray()
[array]::Reverse($chars)
$SuffixSpecials = -join $chars

$PrefixDigits = Get-RandomChars -Set '0123456789' -Count $NumDigits
$SuffixDigits = Get-RandomChars -Set '0123456789' -Count $NumDigits

$Passphrase = "$PrefixSpecials$PrefixDigits$Sep$JoinedWords$Sep$SuffixDigits$SuffixSpecials"

Write-Output 'Generated passphrase:'
Write-Output $Passphrase
