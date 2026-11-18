#Requires -Version 7.2
<#
.SYNOPSIS
    Gera o JSON de deploy do VCF 9.1.1 (VCF Installer: POST /v1/sddcs/validations e /v1/sddcs).
.DESCRIPTION
    Estrutura do SddcSpec do 9.1 (base: gerador do William Lam para 9.1 e a referência da
    VCF Installer API 9.1.1), adaptada ao desenho do lab, o mesmo do 5.2:
      - VDS01 (vmnic0/1, port group VCF911-MGMT): MANAGEMENT, VM_MANAGEMENT e VMOTION sem tag
      - VDS02 (vmnic2/3, port group VCF911-VSAN): VSAN sem tag
      - VDS03 (vmnic4/5, LAN Segment): NSX; TEP com tag (transportVlanId), pool estático;
        zonas de transporte OVERLAY e VLAN (a VLAN fica pronta para os uplinks das Edges)
      - vSAN OSA, FTT do config
      - NSX Manager com 1 nó + VIP
      - VCF Operations + coletor, VCF Management Services (VCFMS) com pool de IPs,
        Fleet LCM, SDDC LCM, Identity Broker, License Server
      - VCF Automation só se Vcf.Automation.Deploy = $true (padrão: Day-N)
    O 9.1 não usa mais chave de licença no JSON: entra em avaliação e licencia pelo License Server.
    Saída: <WorkDir>\vcf911-deploy.json
#>
[CmdletBinding()]
param([string]$ConfigPath = (Join-Path $PSScriptRoot '../config/lab-config.psd1'))

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'LabCommon.psm1') -Force
$cfg = Get-LabConfig -Path $ConfigPath
$v   = $cfg.Vcf
$n   = $cfg.Network
$vl  = $n.Vlans
$mtu = [string]$n.JumboMtu
$dom = $cfg.Domain.ToLower()
$lay = Get-EsxiNicLayout -Config $cfg
if (-not $lay.Vsan.Count) { throw 'Este gerador espera o desenho de 3 VDS (Network.VsanPortgroup definido), como no lab 5.2.' }

$uplinks = { param($idx) $u = 1; @($idx | ForEach-Object { [ordered]@{ id = "vmnic$_"; uplink = "uplink$u" }; $u++ }) }
$vmnics  = { param($idx) @($idx | ForEach-Object { "vmnic$_" }) }

function New-Net([string]$type, [string]$cidr, [string]$gw, [string]$vds, [string]$mtuVal, $range) {
    $o = [ordered]@{
        networkType            = $type
        subnet                 = $cidr
        gateway                = $gw
        subnetMask             = $null
        includeIpAddress       = $null
        includeIpAddressRanges = $null
        vlanId                 = '0'
        mtu                    = $mtuVal
        teamingPolicy          = 'loadbalance_loadbased'
        activeUplinks          = @('uplink1', 'uplink2')
        standbyUplinks         = @()
        portGroupKey           = "$vds-pg-$($type.ToLower() -replace '_','-')"
    }
    if ($range) { $o.includeIpAddressRanges = @([ordered]@{ startIpAddress = $range[0]; endIpAddress = $range[1] }) }
    $o
}

$m = $v.ManagementServices
$o = $v.Operations
# versão exata que o depot oferece (a etapa 6 grava); sem ela usa a do config
$relFile = Join-Path $cfg.Paths.WorkDir 'release-version.txt'
$release = if (Test-Path $relFile) { (Get-Content $relFile -Raw).Trim() } else { $v.Version }

$spec = [ordered]@{
    sddcId                      = $v.SddcId
    vcfInstanceName             = $v.InstanceName
    workflowType                = $v.Sku
    version                     = $release
    ceipEnabled                 = [bool]$v.CeipEnabled
    fipsEnabled                 = [bool]$v.FipsEnabled
    skipEsxThumbprintValidation = $true
    skipGatewayPingValidation   = $true
    sddcManagerSpec = [ordered]@{
        hostname              = $v.SddcManager.Hostname
        rootUserCredentials   = [ordered]@{ username = 'root'; password = $v.SddcManager.RootPassword }
        secondUserCredentials = [ordered]@{ username = 'vcf';  password = $v.SddcManager.VcfPassword }
        rootPassword          = $v.SddcManager.RootPassword
        sshPassword           = $v.SddcManager.SshPassword
        localUserPassword     = $v.SddcManager.LocalPassword
        useExistingDeployment = $false
    }
    dnsSpec    = [ordered]@{ nameservers = @($n.DnsServer); subdomain = $dom }
    ntpServers = @($n.NtpServer)
    vcenterSpec = [ordered]@{
        vcenterHostname       = $v.Vcenter.Hostname
        rootVcenterPassword   = $v.Vcenter.RootPassword
        vmSize                = $v.Vcenter.Size
        storageSize           = $v.Vcenter.StorageSize
        adminUserSsoPassword  = $v.Vcenter.SsoPassword
        ssoDomain             = 'vsphere.local'
        useExistingDeployment = $false
    }
    hostSpecs = @($cfg.Esxi.Hosts | ForEach-Object {
        [ordered]@{ hostname = "$($_.Name).$dom".ToLower(); credentials = [ordered]@{ username = 'root'; password = $cfg.Esxi.Password } }
    })
    clusterSpec   = [ordered]@{ clusterName = $v.Cluster; datacenterName = $v.Datacenter }
    datastoreSpec = [ordered]@{
        vsanSpec = [ordered]@{
            failuresToTolerate = [int]$v.VsanFtt
            vsanDedup          = $false
            esaConfig          = [ordered]@{ enabled = ($v.VsanMode -eq 'ESA') }   # OSA: PVSCSI marcado SSD | ESA: NVMe
            datastoreName      = $v.VsanDatastore
        }
    }
    nsxtSpec = [ordered]@{
        nsxtManagerSize                     = $v.Nsx.Size
        nsxtManagers                        = @($v.Nsx.Nodes | ForEach-Object { [ordered]@{ hostname = $_.Hostname } })
        vipFqdn                             = $v.Nsx.VipHostname
        useExistingDeployment               = $false
        nsxtAdminPassword                   = $v.Nsx.AdminPassword
        nsxtAuditPassword                   = $v.Nsx.AuditPassword
        rootNsxtManagerPassword             = $v.Nsx.RootPassword
        skipNsxOverlayOverManagementNetwork = $true
        ipAddressPoolSpec = [ordered]@{
            name        = "$($v.Cluster)-tep01"
            description = 'ESX Host Overlay TEP IP Pool'
            subnets     = @([ordered]@{
                cidr                = $vl.HostTep.Cidr
                gateway             = $vl.HostTep.Gateway
                ipAddressPoolRanges = @([ordered]@{ start = $vl.HostTep.PoolStart; end = $vl.HostTep.PoolEnd })
            })
        }
        transportVlanId = [string]$vl.HostTep.Id
    }
    vcfOperationsSpec = [ordered]@{
        nodes                 = @([ordered]@{ hostname = $o.Hostname; rootUserPassword = $o.RootPassword; type = 'master' })
        adminUserPassword     = $o.AdminPassword
        applianceSize         = $o.Size
        useExistingDeployment = $false
        loadBalancerFqdn      = ''
    }
    vcfOperationsCollectorSpec = [ordered]@{
        hostname              = $o.CollectorHostname
        applicationSize       = $o.CollectorSize
        rootUserPassword      = $o.RootPassword
        useExistingDeployment = $false
    }
}

if ($v.Automation.Deploy) {
    $a = $v.Automation
    $spec.vcfAutomationSpec = [ordered]@{
        platformFqdn          = $a.RuntimeHostname
        hostname              = $a.Hostname
        adminUserPassword     = $a.AdminPassword
        ipPool                = @($a.IpPool)
        nodePrefix            = $a.NodePrefix
        internalClusterCidr   = $m.InternalClusterCidr
        useExistingDeployment = $false
        size                  = $a.Size
    }
}

$spec.saltSpec      = @{}
$spec.vidbSpec      = [ordered]@{ hostname = $m.IdentityHostname }
$spec.saltRaasSpec  = @{}
$spec.vspClusterSpec = [ordered]@{
    platformFqdn            = $m.RuntimeHostname
    instanceFqdn            = $m.InstanceHostname
    fleetFqdn               = $m.FleetHostname
    systemUserPassword      = $m.SystemPassword
    size                    = $m.Size
    internalClusterCidrIpv4 = $m.InternalClusterCidr
    ipv4Pool                = @{ ipRange = [ordered]@{ startIpAddress = $m.PoolStart; endIpAddress = $m.PoolEnd } }
}
$spec.telemetryAcceptorSpec = @{}
$spec.licenseServerSpec     = [ordered]@{ hostname = $m.LicenseHostname }
$spec.sddcLcmSpec           = [ordered]@{ hostname = $m.InstanceHostname }
$spec.fleetLcmSpec          = [ordered]@{ hostname = $m.FleetHostname }
$spec.fleetDepotSpec        = @{}

$spec.networkSpecs = @(
    (New-Net 'MANAGEMENT'    $n.MgmtCidr      $n.MgmtGateway      $v.Vds     '1500' $null)
    (New-Net 'VM_MANAGEMENT' $n.MgmtCidr      $n.MgmtGateway      $v.Vds     '1500' $null)
    (New-Net 'VMOTION'       $vl.VMotion.Cidr $vl.VMotion.Gateway $v.Vds     $mtu   @($vl.VMotion.PoolStart, $vl.VMotion.PoolEnd))
    (New-Net 'VSAN'          $vl.VSAN.Cidr    $vl.VSAN.Gateway    $v.VsanVds $mtu   @($vl.VSAN.PoolStart, $vl.VSAN.PoolEnd))
)

$spec.dvsSpecs = @(
    [ordered]@{
        dvsName         = $v.Vds
        networks        = @('MANAGEMENT', 'VM_MANAGEMENT', 'VMOTION')
        mtu             = $mtu
        vmnicsToUplinks = (& $uplinks $lay.Mgmt)
        lagSpecs        = $null
        vmnics          = (& $vmnics $lay.Mgmt)
    }
    [ordered]@{
        dvsName         = $v.VsanVds
        networks        = @('VSAN')
        mtu             = $mtu
        vmnicsToUplinks = (& $uplinks $lay.Vsan)
        lagSpecs        = $null
        vmnics          = (& $vmnics $lay.Vsan)
    }
    [ordered]@{
        dvsName          = $v.NsxVds
        networks         = @()
        mtu              = $mtu
        nsxtSwitchConfig = [ordered]@{
            transportZones = @(
                [ordered]@{ transportType = 'OVERLAY'; name = "$($v.SddcId)-tz-overlay01" }
                [ordered]@{ transportType = 'VLAN';    name = "$($v.SddcId)-tz-vlan01" }
            )
            hostSwitchOperationalMode = 'STANDARD'
        }
        vmnicsToUplinks  = (& $uplinks $lay.Nsx)
        nsxTeamings      = @([ordered]@{ policy = 'LOADBALANCE_SRCID'; activeUplinks = @('uplink1', 'uplink2'); standByUplinks = @() })
        lagSpecs         = $null
        vmnics           = (& $vmnics $lay.Nsx)
    }
)

$out = Join-Path $cfg.Paths.WorkDir 'vcf911-deploy.json'
$spec | ConvertTo-Json -Depth 20 | Set-Content -Path $out -Encoding utf8NoBOM
Write-LabLog "JSON de deploy gerado: $out" 'OK'
Write-LabLog ("  {0} {1} | hosts: {2} | vCenter {3} | NSX {4} nó(s) {5} | Ops {6} | VCFMS {7} ({8}-{9}) | Automation: {10}" -f `
    $v.Sku, $release, ($cfg.Esxi.Hosts.Name -join ','), $v.Vcenter.Size, $v.Nsx.Nodes.Count, $v.Nsx.Size, $o.Size, `
    $m.Size, $m.PoolStart, $m.PoolEnd, $(if ($v.Automation.Deploy) { 'sim' } else { 'Day-N' }))
$out

exit 0
