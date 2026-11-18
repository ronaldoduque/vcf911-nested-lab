# Funções da API do VCF Installer 9.1.x (mesma API do SDDC Manager, /v1/...).
# Usadas pelas etapas 5 (Installer), 6 (depot/bundles) e 8 (validação e deploy).

$script:VcfTok = $null

function Get-VcfToken {
    param([Parameter(Mandatory)][string]$Server, [Parameter(Mandatory)][string]$User, [Parameter(Mandatory)][string]$Password, [switch]$Force)
    if ($script:VcfTok -and -not $Force -and $script:VcfTok.Server -eq $Server -and $script:VcfTok.Expires -gt (Get-Date)) { return $script:VcfTok.Headers }
    $body = @{ username = $User; password = $Password } | ConvertTo-Json
    $r = Invoke-RestMethod -Uri "https://$Server/v1/tokens" -Method Post -Body $body -ContentType 'application/json' -SkipCertificateCheck -TimeoutSec 180
    $h = @{ Authorization = "Bearer $($r.accessToken)"; Accept = 'application/json' }
    # o token dura ~1 h; renova antes
    $script:VcfTok = @{ Server = $Server; Headers = $h; Expires = (Get-Date).AddMinutes(40) }
    $h
}

function Invoke-Vcf {
    <#  Chamada genérica à API com token, repetição em erro de rede e
        mensagem de erro legível (errorCode/message/remediationMessage). #>
    param(
        [Parameter(Mandatory)][string]$Server, [Parameter(Mandatory)][hashtable]$Cred,
        [Parameter(Mandatory)][string]$Path, [string]$Method = 'Get', $Body, [int]$Retry = 5, [switch]$Raw
    )
    $json = if ($null -eq $Body) { $null } elseif ($Body -is [string]) { $Body } else { $Body | ConvertTo-Json -Depth 30 }
    for ($i = 1; $i -le $Retry; $i++) {
        try {
            # o token também vai dentro do try: com o Installer ocupado (bundles), /v1/tokens pode demorar
            $h = Get-VcfToken -Server $Server -User $Cred.User -Password $Cred.Password
            $p = @{ Uri = "https://$Server$Path"; Method = $Method; Headers = $h; SkipCertificateCheck = $true; TimeoutSec = 180; ContentType = 'application/json' }
            if ($json) { $p.Body = $json }
            if ($Raw) { return Invoke-WebRequest @p }
            return Invoke-RestMethod @p
        } catch {
            $code = $_.Exception.Response.StatusCode.value__
            $msg  = $_.ErrorDetails.Message
            if ($code -eq 401) { $script:VcfTok = $null; continue }
            if ($code -and $code -lt 500) {
                $detail = try { $e = $msg | ConvertFrom-Json; "$($e.errorCode): $($e.message) $($e.remediationMessage)" } catch { $msg }
                throw "API $Method $Path -> HTTP $code. $detail"
            }
            if ($i -eq $Retry) { throw "API $Method $Path falhou: $($_.Exception.Message) $msg" }
            Start-Sleep -Seconds (15 * $i)
        }
    }
}

function Wait-VcfInstallerUi {
    param([Parameter(Mandatory)][string]$Server, [int]$TimeoutMin = 45)
    $deadline = (Get-Date).AddMinutes($TimeoutMin)
    while ((Get-Date) -lt $deadline) {
        try {
            $r = Invoke-WebRequest -Uri "https://$Server/vcf-installer-ui/login" -SkipCertificateCheck -TimeoutSec 10 -UseBasicParsing
            if ($r.StatusCode -eq 200) { return $true }
        } catch {}
        Start-Sleep -Seconds 30
    }
    throw "A interface do VCF Installer (https://$Server/vcf-installer-ui/login) não respondeu em $TimeoutMin min."
}

function Set-VcfOfflineDepot {
    <#  9.1+: HTTP sem autenticação. A URL tem que ser IP (9.1.1 recusa .lab - KB 456037). #>
    param([Parameter(Mandatory)][string]$Server, [Parameter(Mandatory)][hashtable]$Cred, [Parameter(Mandatory)][string]$Url)
    $body = @{ depotConfiguration = @{ isOfflineDepot = $true; url = $Url } }
    Invoke-Vcf -Server $Server -Cred $Cred -Path '/v1/system/settings/depot' -Method Put -Body $body -Raw | Out-Null
}

function Sync-VcfDepot {
    param([Parameter(Mandatory)][string]$Server, [Parameter(Mandatory)][hashtable]$Cred, [int]$TimeoutMin = 30)
    Invoke-Vcf -Server $Server -Cred $Cred -Path '/v1/system/settings/depot/depot-sync-info' -Method Patch -Raw | Out-Null
    $deadline = (Get-Date).AddMinutes($TimeoutMin)
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 20
        $s = Invoke-Vcf -Server $Server -Cred $Cred -Path '/v1/system/settings/depot/depot-sync-info'
        if ($s.syncStatus -eq 'SYNCED') { return $s }
        if ($s.syncStatus -match 'FAIL') { throw "Sync do depot falhou: $($s | ConvertTo-Json -Depth 5 -Compress)" }
    }
    throw "Sync do depot não terminou em $TimeoutMin min (KB 447589: metadata em cache/velho no servidor do depot?)."
}

function Get-VcfReleaseBundles {
    <#  Bundles de INSTALL da versão alvo, na forma { componente = bundleId } (+ '__release' e '__chosen').
        -Preferred: { componente = versão } (as completas no depot, gravadas pela etapa 3). Sem
        preferência, usa a versão mais nova oferecida. #>
    param([Parameter(Mandatory)][string]$Server, [Parameter(Mandatory)][hashtable]$Cred, [Parameter(Mandatory)][string]$Sku,
          [Parameter(Mandatory)][string]$Version, [hashtable]$Preferred = @{})
    $r = Invoke-Vcf -Server $Server -Cred $Cred -Path "/v1/releases/$Sku/release-components?releaseVersion=$Version&automatedInstall=true&imageType=INSTALL"
    $rel = $r.elements | Where-Object releaseVersion -eq $Version
    if (-not $rel) {
        $pre = ($Version -split '\.')[0..2] -join '.'
        $rel = $r.elements | Where-Object { $_.releaseVersion -like "$pre.*" } | Select-Object -First 1
    }
    if (-not $rel) {
        $have = ($r.elements.releaseVersion | Sort-Object -Unique) -join ', '
        throw "O depot não oferece a versão $Version para $Sku. Versões vistas: $have"
    }
    # nomes do catálogo do depot x nomes da API
    $alias = @{ 'SDDC_MANAGER' = 'SDDC_MANAGER_VCF' }
    $verKey = { param($v) (([regex]::Matches("$v", '\d+') | ForEach-Object { '{0:D10}' -f [int64]$_.Value }) -join '.') }
    $map = [ordered]@{ '__release' = $rel.releaseVersion }; $chosen = [ordered]@{}
    foreach ($c in $rel.components) {
        # o nome do campo de versão varia; pega o primeiro texto no formato 9.x.y.z.build do objeto
        $opts = foreach ($v in @($c.versions)) {
            $json = $v | ConvertTo-Json -Depth 8 -Compress
            $ver  = ([regex]::Match($json, '"(\d+\.\d+\.\d+\.\d+\.\d+)"')).Groups[1].Value
            $id   = @($v.artifacts.bundles.id) | Select-Object -First 1
            if ($id) { [pscustomobject]@{ Ver = $ver; Id = $id } }
        }
        if (-not $opts) { continue }
        $want = $Preferred[$c.name]; if (-not $want -and $alias[$c.name]) { $want = $Preferred[$alias[$c.name]] }
        $pick = if ($want) { $opts | Where-Object Ver -eq $want | Select-Object -First 1 }
        if (-not $pick) { $pick = $opts | Sort-Object { & $verKey $_.Ver } -Descending | Select-Object -First 1 }
        $map[$c.name] = $pick.Id
        $chosen[$c.name] = "$($pick.Ver)$(if ($want -and $pick.Ver -ne $want) { " (depot tem $want, não oferecida)" })"
    }
    $map['__chosen'] = $chosen
    $map
}

function Start-VcfBundleDownload {
    param([Parameter(Mandatory)][string]$Server, [Parameter(Mandatory)][hashtable]$Cred, [Parameter(Mandatory)][string]$BundleId)
    try {
        Invoke-Vcf -Server $Server -Cred $Cred -Path "/v1/bundles/$BundleId" -Method Patch -Body @{ bundleDownloadSpec = @{ downloadNow = $true } } -Raw | Out-Null
    } catch {
        # já baixado, ou download/validação em andamento (de uma execução anterior): segue e acompanha
        if ("$_" -notmatch 'ALREADY_DOWNLOADED|ALREADY_SCHEDULED|ALREADY_IN_PROGRESS|DOWNLOAD_NOT_AVAILABLE|already scheduled|in progress|is pending|getting validated') { throw }
    }
}

function Get-VcfDownloadStatus {
    param([Parameter(Mandatory)][string]$Server, [Parameter(Mandatory)][hashtable]$Cred, [Parameter(Mandatory)][string]$Version)
    (Invoke-Vcf -Server $Server -Cred $Cred -Path "/v1/bundles/download-status?releaseVersion=$Version&imageType=INSTALL").elements
}

function Invoke-VcfSpecValidation {
    <#  POST /v1/sddcs/validations e espera terminar. Devolve o objeto de validação. #>
    param([Parameter(Mandatory)][string]$Server, [Parameter(Mandatory)][hashtable]$Cred, [Parameter(Mandatory)][string]$SpecJson, [int]$TimeoutMin = 40)
    $v = Invoke-Vcf -Server $Server -Cred $Cred -Path '/v1/sddcs/validations' -Method Post -Body $SpecJson
    $deadline = (Get-Date).AddMinutes($TimeoutMin); $last = ''
    while ((Get-Date) -lt $deadline) {
        Start-Sleep -Seconds 20
        $v = Invoke-Vcf -Server $Server -Cred $Cred -Path "/v1/sddcs/validations/$($v.id)"
        $run = @($v.validationChecks | Where-Object { $_.resultStatus -eq 'IN_PROGRESS' }).Count
        $msg = "validação: $($v.executionStatus) ($run checagem(ns) em andamento)"
        if ($msg -ne $last) { Write-LabLog "  $msg"; $last = $msg }
        if ($v.executionStatus -in 'COMPLETED', 'FAILED') { return $v }
    }
    throw "A validação não terminou em $TimeoutMin min."
}

function Start-VcfDeployment {
    param([Parameter(Mandatory)][string]$Server, [Parameter(Mandatory)][hashtable]$Cred, [Parameter(Mandatory)][string]$SpecJson)
    Invoke-Vcf -Server $Server -Cred $Cred -Path '/v1/sddcs' -Method Post -Body $SpecJson
}

function Get-VcfDeployment {
    param([Parameter(Mandatory)][string]$Server, [Parameter(Mandatory)][hashtable]$Cred, [string]$Id)
    if ($Id) { return Invoke-Vcf -Server $Server -Cred $Cred -Path "/v1/sddcs/$Id" }
    $all = Invoke-Vcf -Server $Server -Cred $Cred -Path '/v1/sddcs'
    @($all.elements) | Sort-Object { [datetime]$_.creationTimestamp } -Descending -ErrorAction SilentlyContinue | Select-Object -First 1
}

function Restart-VcfDeployment {
    <#  Retoma um deploy que falhou, do ponto em que parou (PATCH /v1/sddcs/{id}). #>
    param([Parameter(Mandatory)][string]$Server, [Parameter(Mandatory)][hashtable]$Cred, [Parameter(Mandatory)][string]$Id, [string]$SpecJson)
    Invoke-Vcf -Server $Server -Cred $Cred -Path "/v1/sddcs/$Id" -Method Patch -Body $SpecJson -Raw | Out-Null
}

Export-ModuleMember -Function Get-VcfToken, Invoke-Vcf, Wait-VcfInstallerUi, Set-VcfOfflineDepot, Sync-VcfDepot,
                              Get-VcfReleaseBundles, Start-VcfBundleDownload, Get-VcfDownloadStatus,
                              Invoke-VcfSpecValidation, Start-VcfDeployment, Get-VcfDeployment, Restart-VcfDeployment
