#Requires -Version 7.2
<#
.SYNOPSIS
    Testa, ANTES do deploy, o que mais derruba VCF nested (agora no ESXi físico).
.DESCRIPTION
    1. DNS direto e reverso de todos os nomes (contra o DNS do lab)
    2. NTP da svc01 (chrony) respondendo
    3. Em cada ESXi: cria vmkernels temporários nas VLANs de vMotion, vSAN e TEP e faz
       vmkping sem fragmentação com payload de (MTU - 28) entre todos os hosts e até o gateway
       (vMotion/vSAN sem tag na vmnet10; TEP com tag no LAN Segment, via vmnic2).
       Isso prova, de uma vez, que:
         - as tags 802.1Q atravessam o port group trunk (VLAN 4095) do ESXi físico
         - o VyOS está roteando/respondendo nas VIFs
         - jumbo frames funcionam com o tipo de placa escolhido (vmxnet3/e1000e)
    4. Remove tudo que criou (vSwitch0 volta a MTU 1500)
    5. 9.1: pool do VCF Management Services inteiro sem resposta a ping (KB 443604) e
       depot offline respondendo no IP que o Installer usa
    Se falhar só no teste de MTU: ajuste Network.JumboMtu (ex.: 1700) e/ou Esxi.NicType
    no lab-config.psd1, regenere o JSON (06) e rode este teste de novo.
#>
[CmdletBinding()]
param([string]$ConfigPath = (Join-Path $PSScriptRoot '../config/lab-config.psd1'))

$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'LabCommon.psm1') -Force
Import-Module Posh-SSH
$cfg = Get-LabConfig -Path $ConfigPath
$n   = $cfg.Network
$e   = $cfg.Esxi
$results = [System.Collections.Generic.List[object]]::new()
function Add-Result($Test, $Ok, $Detail) { $results.Add([pscustomobject]@{ Teste = $Test; OK = [bool]$Ok; Detalhe = $Detail }) }

Write-LabLog 'Teste de prontidão do lab' 'STEP'

# ---------- 1. DNS
foreach ($r in (Get-LabDnsRecords -Config $cfg)) {
    $fqdn = "$($r.Name).$($cfg.Domain)"
    $fwd = Resolve-LabDns -Name $fqdn -Server $n.DnsServer -Type A
    $rev = Resolve-LabDns -Name $r.Ip -Server $n.DnsServer -Type PTR
    $ok = ($fwd -eq $r.Ip) -and ($rev -eq $fqdn)
    Add-Result "DNS $fqdn" $ok "A=$fwd PTR=$rev"
}

# ---------- 2. NTP
$ntp = Test-LabNtp -Server $n.NtpServer
Add-Result "NTP $($n.NtpServer)" ($ntp.Ok -and [math]::Abs($ntp.OffsetSec) -lt 5) $(if ($ntp.Ok) { "stratum $($ntp.Stratum), diferença $($ntp.OffsetSec) s" } else { $ntp.Error })

# ---------- 2b. Pool do VCFMS livre (o bootstrap reprova se algum IP responder) e depot
$m = $cfg.Vcf.ManagementServices
$busy = @()
foreach ($ip in (Get-IpRange -Start $m.PoolStart -End $m.PoolEnd)) {
    if (Test-Connection -TargetName $ip -Count 1 -TimeoutSeconds 1 -Quiet -ErrorAction SilentlyContinue) { $busy += $ip }
}
Add-Result "Pool VCFMS $($m.PoolStart)-$($m.PoolEnd) livre" ($busy.Count -eq 0) ($busy -join ', ')
$depotUrl = "http://$($cfg.Depot.BindIp):$($cfg.Depot.Port)/PROD/metadata/manifest/v1/vcfManifest.json"
try { $r = Invoke-WebRequest -Uri $depotUrl -Method Head -UseBasicParsing -TimeoutSec 10; Add-Result 'Depot offline (vcfManifest.json)' ($r.StatusCode -eq 200) $depotUrl }
catch { Add-Result 'Depot offline (vcfManifest.json)' $false "$depotUrl $($_.Exception.Message)" }

# ---------- 3. VLAN + MTU via vmkernels temporários
# vMotion (e vSAN, se não tiver vmnet própria): vSwitch0/vmnic0 na vmnet10, sem tag.
# vSAN com vmnet própria: vSwitch temporário labtestVsan com a primeira vmnic do vSAN, sem tag.
# Redes NSX (Id > 0): vSwitch temporário labtestNsx com a primeira vmnic do NSX, com tag.
$lay = Get-EsxiNicLayout -Config $cfg
$nsxNic  = "vmnic$($lay.Nsx[0])"
$vsanNic = if ($lay.Vsan.Count) { "vmnic$($lay.Vsan[0])" } else { $null }
$cred = [pscredential]::new('root', (ConvertTo-SecureString $e.Password -AsPlainText -Force))
$testVlans = @(
    @{ Name = 'vMotion'; Vlan = $n.Vlans.VMotion; Vmk = 'vmk7' }
    @{ Name = 'vSAN';    Vlan = $n.Vlans.VSAN;    Vmk = 'vmk8' }
    @{ Name = 'HostTEP'; Vlan = $n.Vlans.HostTep; Vmk = 'vmk9' }
)
foreach ($tv in $testVlans) {
    $tv.Switch = if ([int]$tv.Vlan.Id -gt 0) { 'labtestNsx' } elseif ($tv.Name -eq 'vSAN' -and $vsanNic) { 'labtestVsan' } else { 'vSwitch0' }
}
$payload = [int]$n.JumboMtu - 28
$sessions = @{}

function Get-TestIp([string]$cidr, [int]$hostIndex) {
    $o = $cidr.Split('/')[0].Split('.'); "$($o[0]).$($o[1]).$($o[2]).$(200 + $hostIndex)"
}
function Invoke-Esx($s, [string]$cmd, [int]$TimeOut = 120) { (Invoke-SSHCommand -SSHSession $s -Command $cmd -TimeOut $TimeOut) }
function Get-CleanupCmd {
    $parts = @($testVlans | ForEach-Object {
        "esxcli network ip interface remove -i $($_.Vmk) 2>/dev/null"
        "esxcli network vswitch standard portgroup remove -v $($_.Switch) -p labtest-$($_.Name) 2>/dev/null"
    })
    $parts += 'esxcli network vswitch standard remove -v labtestNsx 2>/dev/null'
    $parts += 'esxcli network vswitch standard remove -v labtestVsan 2>/dev/null'
    $parts += 'esxcli network vswitch standard set -v vSwitch0 -m 1500'
    $parts += 'true'
    return ($parts -join '; ')
}

try {
    for ($i = 0; $i -lt $e.Hosts.Count; $i++) {
        $h = $e.Hosts[$i]
        Write-LabLog "Preparando interfaces de teste em $($h.Name)..."
        $s = New-SSHSession -ComputerName $h.Ip -Credential $cred -AcceptKey -Force -ConnectionTimeout 30 -WarningAction SilentlyContinue
        $sessions[$h.Name] = $s
        $c = [System.Collections.Generic.List[string]]::new()
        $c.Add((Get-CleanupCmd))
        $c.Add("esxcli network vswitch standard set -v vSwitch0 -m $($n.JumboMtu)")
        $c.Add("esxcli network vswitch standard add -v labtestNsx")
        $c.Add("esxcli network vswitch standard uplink add -v labtestNsx -u $nsxNic")
        $c.Add("esxcli network vswitch standard set -v labtestNsx -m $($n.JumboMtu)")
        if ($vsanNic) {
            $c.Add("esxcli network vswitch standard add -v labtestVsan")
            $c.Add("esxcli network vswitch standard uplink add -v labtestVsan -u $vsanNic")
            $c.Add("esxcli network vswitch standard set -v labtestVsan -m $($n.JumboMtu)")
        }
        foreach ($tv in $testVlans) {
            $pg = "labtest-$($tv.Name)"
            $ip = Get-TestIp $tv.Vlan.Cidr ($i + 1)
            $mask = (ConvertFrom-Cidr $tv.Vlan.Cidr).Netmask
            $c.Add("esxcli network vswitch standard portgroup add -v $($tv.Switch) -p $pg")
            $c.Add("esxcli network vswitch standard portgroup set -p $pg --vlan-id $($tv.Vlan.Id)")
            $c.Add("esxcli network ip interface add -i $($tv.Vmk) -p $pg -m $($n.JumboMtu)")
            $c.Add("esxcli network ip interface ipv4 set -i $($tv.Vmk) -t static -I $ip -N $mask")
        }
        $r = Invoke-Esx $s ($c -join '; ') 300
        # confere se as vmkernels de teste existem com o IP certo (um erro aqui invalida todos os pings)
        $ipv4 = (Invoke-Esx $s 'esxcli network ip interface ipv4 get').Output -join "`n"
        $missing = @($testVlans | Where-Object { $ipv4 -notmatch "$($_.Vmk)\s+$([regex]::Escape((Get-TestIp $_.Vlan.Cidr ($i + 1))))" } | ForEach-Object Vmk)
        Add-Result "$($h.Name) vmks de teste criadas" ($missing.Count -eq 0) ($(if ($missing) { "faltam: $($missing -join ', ') | $((@($r.Output) + @($r.Error) | Select-Object -Last 3) -join ' ')" } else { '' }))
        $nicList = (Invoke-Esx $s 'esxcli network nic list').Output -join "`n"
        $faltam = @(0..($lay.NicCount - 1) | Where-Object { $nicList -notmatch "vmnic$_\s" } | ForEach-Object { "vmnic$_" })
        Add-Result "$($h.Name) vmnic0-$($lay.NicCount - 1) presentes" ($faltam.Count -eq 0) ($faltam -join ', ')
        $mm = (Invoke-Esx $s 'esxcli system maintenanceMode get').Output -join ''
        Add-Result "$($h.Name) fora do modo manutenção" ($mm -match 'Disabled') $mm
        # gerência: gateway e DNS
        $r = Invoke-Esx $s "vmkping -I vmk0 -c 2 $($n.MgmtGateway)"
        Add-Result "$($h.Name) mgmt -> gateway" (($r.Output -join ' ') -match ' 0% packet loss') ''
        $r = Invoke-Esx $s "nslookup $($e.Hosts[0].Name).$($cfg.Domain) $($n.DnsServer)"
        Add-Result "$($h.Name) DNS via $($n.DnsServer)" (($r.Output -join ' ') -match [regex]::Escape($e.Hosts[0].Ip)) ''
    }
    Start-Sleep -Seconds 5

    for ($i = 0; $i -lt $e.Hosts.Count; $i++) {
        $h = $e.Hosts[$i]; $s = $sessions[$h.Name]
        Write-LabLog "Pings de teste a partir de $($h.Name)..."
        foreach ($tv in $testVlans) {
            $targets = @($tv.Vlan.Gateway)
            for ($j = 0; $j -lt $e.Hosts.Count; $j++) { if ($j -ne $i) { $targets += Get-TestIp $tv.Vlan.Cidr ($j + 1) } }
            $tag = if ([int]$tv.Vlan.Id -eq 0) { 'sem tag' } else { "VLAN $($tv.Vlan.Id)" }
            foreach ($dst in $targets) {
                # gateway do vSAN isolado = placa LAB-VSAN da svc01: só conectividade, sem jumbo
                $hostGw = ($tv.Name -eq 'vSAN' -and $vsanNic -and $dst -eq $tv.Vlan.Gateway)
                $r = if ($hostGw) { Invoke-Esx $s "vmkping -I $($tv.Vmk) -c 2 $dst" } else { Invoke-Esx $s "vmkping -I $($tv.Vmk) -d -s $payload -c 2 $dst" }
                $ok = ($r.Output -join ' ') -match ' 0% packet loss'
                if (-not $ok) {
                    $r2 = Invoke-Esx $s "vmkping -I $($tv.Vmk) -c 2 $dst"
                    $detail = if (($r2.Output -join ' ') -match ' 0% packet loss') { 'só o jumbo falha (rede ok)' } else { 'sem conectividade' }
                } else { $detail = '' }
                $mtuTxt = if ($hostGw) { 'MTU padrão (svc01)' } else { "MTU $($n.JumboMtu)" }
                Add-Result "$($h.Name) $($tv.Name) $tag $mtuTxt -> $dst" $ok $detail
            }
        }
    }
}
finally {
    foreach ($name in $sessions.Keys) {
        $s = $sessions[$name]
        Invoke-Esx $s (Get-CleanupCmd) | Out-Null
        Remove-SSHSession -SSHSession $s | Out-Null
    }
}

# ---------- resultado
$results | Format-Table -AutoSize | Out-String -Width 200 | Write-Host
$bad = @($results | Where-Object { -not $_.OK })
if ($bad.Count) {
    Write-LabLog "$($bad.Count) teste(s) falharam." 'ERROR'
    if (($bad | Where-Object Detalhe -eq 'só o jumbo falha (rede ok)') -and -not ($bad | Where-Object Detalhe -eq 'sem conectividade')) {
        Write-LabLog "A rede funciona e só o jumbo falha: use Network.JumboMtu = 1700, regenere o JSON (06) e teste de novo." 'WARN'
    }
    exit 1
}
Write-LabLog 'Lab pronto para o deploy.' 'OK'

exit 0
