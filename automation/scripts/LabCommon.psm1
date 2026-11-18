#Requires -Version 7.2
<#
    LabCommon.psm1 - funções compartilhadas pelos scripts do lab VCF 9.1.1 (ESXi 8 físico).
#>

Set-StrictMode -Version Latest
$script:LogFile = $null

# ----------------------------------------------------------------- Log
function Write-LabLog {
    param(
        [Parameter(Mandatory)][string]$Message,
        [ValidateSet('INFO', 'OK', 'WARN', 'ERROR', 'STEP')][string]$Level = 'INFO'
    )
    $ts = Get-Date -Format 'yyyy-MM-dd HH:mm:ss'
    $color = @{ INFO = 'Gray'; OK = 'Green'; WARN = 'Yellow'; ERROR = 'Red'; STEP = 'Cyan' }[$Level]
    Write-Host "[$ts] [$Level] $Message" -ForegroundColor $color
    if ($script:LogFile) { "[$ts] [$Level] $Message" | Out-File -FilePath $script:LogFile -Append -Encoding utf8 }
}

# ----------------------------------------------------------------- Rede (CIDR)
function ConvertFrom-Cidr {
    param([Parameter(Mandatory)][string]$Cidr)
    $ip, $prefix = $Cidr.Split('/')
    $prefix = [int]$prefix
    $maskBits = ([uint32]::MaxValue) -shl (32 - $prefix)
    $bytes = [BitConverter]::GetBytes([uint32]$maskBits)
    [array]::Reverse($bytes)
    [pscustomobject]@{
        Network = $ip
        Prefix  = $prefix
        Netmask = ([System.Net.IPAddress]::new($bytes)).ToString()
    }
}

function Get-ReverseZoneName {
    # 10.52.10.0/24 -> 10.52.10.in-addr.arpa (somente /24, que é o que o lab usa)
    param([Parameter(Mandatory)][string]$Cidr)
    $o = $Cidr.Split('/')[0].Split('.')
    "$($o[2]).$($o[1]).$($o[0]).in-addr.arpa"
}

# ----------------------------------------------------------------- Config
function Get-LabConfig {
    param([Parameter(Mandatory)][string]$Path)

    if (-not (Test-Path $Path)) { throw "Arquivo de configuração não encontrado: $Path" }
    $cfg = Import-PowerShellDataFile -Path $Path

    if (-not $cfg.Domain -or $cfg.Domain -eq 'auto') {
        throw "Defina Domain no lab-config.psd1 (ex.: 'vcf.lab'): a svc01 Ubuntu não tem AD para descobrir o domínio."
    }

    # Mídias: resolve curingas para um arquivo real
    foreach ($k in 'IsoEsxi', 'IsoVyos', 'OvaVcfInstaller') {
        $p = $cfg.Paths[$k]
        if ($p -and $p.Contains('*')) {
            $found = @(Get-ChildItem -Path $p -File -ErrorAction SilentlyContinue | Sort-Object LastWriteTime -Descending)
            if ($found.Count -ge 1) {
                if ($found.Count -gt 1) {
                    Write-Warning "$k : '$p' casou com $($found.Count) arquivos; usando o mais novo: $($found[0].Name)"
                }
                $cfg.Paths[$k] = $found[0].FullName
            }
        }
    }

    # Quantidade de ESX: 3 ou 4 (Deploy-Lab -HostCount passa pela variável de ambiente)
    $e = $cfg.Esxi
    $e.AllHosts = @($e.Hosts)
    $count = if ($env:VCF911_HOSTCOUNT) { [int]$env:VCF911_HOSTCOUNT } elseif ($e.ContainsKey('HostCount')) { [int]$e.HostCount } else { $e.Hosts.Count }
    if ($count -lt 3 -or $count -gt $e.AllHosts.Count) { throw "Esxi.HostCount = ${count}: use 3 a $($e.AllHosts.Count) (vSAN no VCF 9.x pede no mínimo 3)." }
    $e.Hosts = @($e.AllHosts[0..($count - 1)])
    $e.HostCount = $count
    if ($count -eq 3 -and $e.ContainsKey('MemoryGB3') -and $e.MemoryGB3) { $e.MemoryGB = $e.MemoryGB3 }
    if ($count -eq 3 -and $e.ContainsKey('CpuCount3') -and $e.CpuCount3) { $e.CpuCount = $e.CpuCount3 }
    # 2 sockets virtuais (como o host físico) quando o número de vCPU é par
    if (-not $e.ContainsKey('CoresPerSocket') -or -not $e.CoresPerSocket) { $e.CoresPerSocket = if ($e.CpuCount % 2 -eq 0) { $e.CpuCount / 2 } else { $e.CpuCount } }

    $mgmt = ConvertFrom-Cidr $cfg.Network.MgmtCidr
    $cfg.Network.MgmtNetmask = $mgmt.Netmask
    $cfg.Network.MgmtPrefix  = $mgmt.Prefix

    if (-not (Test-Path $cfg.Paths.WorkDir)) { New-Item -ItemType Directory -Path $cfg.Paths.WorkDir -Force | Out-Null }
    $script:LogFile = Join-Path $cfg.Paths.WorkDir ("lab-{0}.log" -f (Get-Date -Format 'yyyyMMdd'))
    return $cfg
}

function Get-LabDnsRecords {
    # Lista única de todos os nomes que precisam existir no DNS (A + PTR), em minúsculas
    # (o bootstrap do VCFMS falha com registro em maiúscula - KB 445179)
    param([Parameter(Mandatory)]$Config)
    $c = $Config; $v = $c.Vcf
    $list = [System.Collections.Generic.List[object]]::new()
    $add = { param($n, $ip, $role) $list.Add([pscustomobject]@{ Name = "$n".ToLower(); Ip = $ip; Role = $role }) }
    & $add $c.VyOS.Hostname        $c.Network.MgmtGateway 'Gateway VyOS'
    if ($c.ContainsKey('Svc01') -and $c.Svc01.VmName) { & $add $c.Svc01.VmName $c.Network.HostAdapterIp 'svc01 (DNS/NTP/depot/kickstart)' }
    & $add $c.Installer.Hostname   $c.Installer.Ip        'VCF Installer'
    foreach ($h in $c.Esxi.Hosts) { & $add $h.Name $h.Ip 'ESX nested' }
    & $add $v.Vcenter.Hostname     $v.Vcenter.Ip          'vCenter'
    & $add $v.Nsx.VipHostname      $v.Nsx.VipIp           'NSX VIP'
    foreach ($n in $v.Nsx.Nodes) { & $add $n.Hostname $n.Ip 'NSX Manager' }
    & $add $v.SddcManager.Hostname $v.SddcManager.Ip      'SDDC Manager'
    $o = $v.Operations
    & $add $o.Hostname             $o.Ip                  'VCF Operations'
    & $add $o.CollectorHostname    $o.CollectorIp         'VCF Operations collector'
    $m = $v.ManagementServices
    & $add $m.RuntimeHostname      $m.RuntimeIp           'VCFMS runtime (platform)'
    & $add $m.FleetHostname        $m.FleetIp             'Fleet LCM'
    & $add $m.InstanceHostname     $m.InstanceIp          'SDDC LCM (instance)'
    & $add $m.IdentityHostname     $m.IdentityIp          'Identity Broker'
    & $add $m.LicenseHostname      $m.LicenseIp           'License Server'
    if ($v.ContainsKey('Automation')) {
        & $add $v.Automation.Hostname        $v.Automation.Ip        'VCF Automation (Day-N)'
        & $add $v.Automation.RuntimeHostname $v.Automation.RuntimeIp 'VCF Automation runtime (Day-N)'
    }
    if ($v.ContainsKey('Edge')) { foreach ($en in $v.Edge.Nodes) { & $add $en.Name $en.MgmtIp 'NSX Edge (Day-N)' } }
    return $list
}

function Get-LabFwPrefix {
    # prefixo das regras de firewall do lab (VCF911-LAB-...), para não colidir com as do 5.2
    param([Parameter(Mandatory)]$Config)
    "$($Config.LabName.ToUpper())-LAB"
}

function Get-IpRange {
    # todos os IPs entre Start e End (mesma /24 ou não)
    param([Parameter(Mandatory)][string]$Start, [Parameter(Mandatory)][string]$End)
    $toInt = { param($ip) $b = ([ipaddress]$ip).GetAddressBytes(); [array]::Reverse($b); [BitConverter]::ToUInt32($b, 0) }
    $a = & $toInt $Start; $z = & $toInt $End
    for ($i = $a; $i -le $z; $i++) {
        $b = [BitConverter]::GetBytes([uint32]$i); [array]::Reverse($b); [ipaddress]::new($b).ToString()
    }
}

# ----------------------------------------------------------------- Placas dos ESX nested
function Get-EsxiNicLayout {
    # Qual vmnic vai para qual rede/VDS (port groups do ESXi físico).
    #   Com Network.VsanPortgroup: vmnic0/1 gerência+vMotion | vmnic2/3 vSAN | vmnic4/5 NSX (trunk)
    #   Sem:                       vmnic0/1 gerência+vMotion+vSAN | vmnic2/3 NSX (trunk)
    param([Parameter(Mandatory)]$Config)
    $n = $Config.Network
    if ($n.ContainsKey('VsanPortgroup') -and $n.VsanPortgroup) {
        [pscustomobject]@{ Mgmt = @(0, 1); Vsan = @(2, 3); Nsx = @(4, 5); NicCount = 6 }
    } else {
        [pscustomobject]@{ Mgmt = @(0, 1); Vsan = @(); Nsx = @(2, 3); NicCount = 4 }
    }
}

function Get-EsxiNicPlan {
    # Placas do ESX nested: índice, MAC estático e port group (conforme Get-EsxiNicLayout)
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][int]$HostIndex)
    $e = $Config.Esxi; $n = $Config.Network
    $lay = Get-EsxiNicLayout -Config $Config
    if ([int]$e.NicCount -lt $lay.NicCount) { throw "Esxi.NicCount=$($e.NicCount), mas o desenho de rede pede $($lay.NicCount) placas." }
    for ($nic = 0; $nic -lt $e.NicCount; $nic++) {
        $pg = if ($nic -in $lay.Mgmt) { $n.MgmtPortgroup } elseif ($nic -in $lay.Vsan) { $n.VsanPortgroup } else { $n.TrunkPortgroup }
        [pscustomobject]@{ Index = $nic; Mac = (Get-EsxiNicMac -Prefix $e.MacPrefix -HostIndex $HostIndex -NicIndex $nic); Portgroup = $pg }
    }
}

function Get-VyosConfigCommands {
    # Configuração completa do VyOS a partir do lab-config.psd1.
    # -Reset limpa antes as interfaces do lab (para reconfigurar um VyOS já existente).
    param([Parameter(Mandatory)]$Config, [switch]$Reset)
    $c = $Config; $n = $c.Network; $v = $c.VyOS
    $cmds = [System.Collections.Generic.List[string]]::new()
    if ($Reset) {
        $cmds.Add('delete interfaces ethernet eth1 vif')
        $cmds.Add('delete interfaces ethernet eth1 address')
        $cmds.Add('delete interfaces ethernet eth2')
    }
    $cmds.Add("set system host-name '$($v.Hostname)'")
    $cmds.Add("set system domain-name '$($c.Domain)'")
    $cmds.Add("set system name-server '$($n.DnsServer)'")
    $cmds.Add("set system time-zone '$($c.TimeZone)'")
    $cmds.Add('delete service ntp')
    $cmds.Add("set service ntp server '$($n.NtpServer)'")
    $cmds.Add("set service ssh port '22'")
    $cmds.Add("set interfaces ethernet eth0 description 'WAN rede de casa (DHCP)'")
    $cmds.Add("set interfaces ethernet eth0 address 'dhcp'")
    # eth1 = port group de gerência sem tag: gerência + IPs secundários das redes Id 0 (vMotion; vSAN só se não tiver port group próprio)
    $cmds.Add("set interfaces ethernet eth1 description '$($n.MgmtPortgroup) mgmt/vMotion (sem tag)'")
    $cmds.Add("set interfaces ethernet eth1 address '$($n.MgmtGateway)/$($n.MgmtPrefix)'")
    $cmds.Add("set interfaces ethernet eth1 mtu '$($n.JumboMtu)'")
    # eth2 = port group trunk (VLAN 4095): redes NSX com tag
    $cmds.Add("set interfaces ethernet eth2 description '$($n.TrunkPortgroup) (NSX com tag)'")
    $cmds.Add("set interfaces ethernet eth2 mtu '$($n.JumboMtu)'")
    foreach ($name in 'VMotion', 'VSAN', 'HostTep', 'EdgeTep', 'Uplink1', 'Uplink2') {
        $vl = $n.Vlans[$name]
        if ($name -eq 'VSAN' -and $n.ContainsKey('VsanPortgroup') -and $n.VsanPortgroup) { continue }   # vSAN isolado no port group próprio, sem VyOS
        $p  = (ConvertFrom-Cidr $vl.Cidr).Prefix
        if ([int]$vl.Id -eq 0) {
            $cmds.Add("set interfaces ethernet eth1 address '$($vl.Gateway)/$p'")
        } else {
            $cmds.Add("set interfaces ethernet eth2 vif $($vl.Id) description '$name'")
            $cmds.Add("set interfaces ethernet eth2 vif $($vl.Id) address '$($vl.Gateway)/$p'")
            $cmds.Add("set interfaces ethernet eth2 vif $($vl.Id) mtu '$($n.JumboMtu)'")
        }
    }
    if ($c.Vcf.ContainsKey('Edge')) { foreach ($b in (Get-VyosBgpCommands -Config $c)) { $cmds.Add($b) } }
    $cmds.Add("set nat source rule 100 description 'Lab -> internet'")
    $cmds.Add("set nat source rule 100 outbound-interface name 'eth0'")
    $cmds.Add("set nat source rule 100 source address '$($n.LabSupernet)'")
    $cmds.Add("set nat source rule 100 translation address 'masquerade'")
    return $cmds
}

function Get-VyosBgpCommands {
    # VyOS como ToR: eBGP com cada Edge nas duas VLANs de uplink, rota padrão para o NSX, ECMP.
    param([Parameter(Mandatory)]$Config)
    $c = $Config; $n = $c.Network; $ed = $c.Vcf.Edge
    $cmds = [System.Collections.Generic.List[string]]::new()
    $cmds.Add('delete protocols bgp')
    $cmds.Add("set protocols bgp system-as '$($ed.TorAsn)'")
    $cmds.Add("set protocols bgp parameters router-id '$($n.MgmtGateway)'")
    $cmds.Add('set protocols bgp parameters bestpath as-path multipath-relax')
    $cmds.Add("set protocols bgp address-family ipv4-unicast maximum-paths ebgp '8'")
    foreach ($en in $ed.Nodes) {
        foreach ($pair in @(@{ Ip = $en.Uplink1; Vlan = $n.Vlans.Uplink1.Id }, @{ Ip = $en.Uplink2; Vlan = $n.Vlans.Uplink2.Id })) {
            $nb = "set protocols bgp neighbor $($pair.Ip)"
            $cmds.Add("$nb remote-as '$($ed.Asn)'")
            $cmds.Add("$nb description '$($en.Name) vlan $($pair.Vlan)'")
            $cmds.Add("$nb password '$($ed.BgpPassword)'")
            $cmds.Add("$nb update-source 'eth2.$($pair.Vlan)'")
            $cmds.Add("$nb timers keepalive '4'")
            $cmds.Add("$nb timers holdtime '12'")
            $cmds.Add("$nb address-family ipv4-unicast default-originate")
            $cmds.Add("$nb address-family ipv4-unicast soft-reconfiguration inbound")
        }
    }
    if ($n.ContainsKey('OverlaySupernet')) {
        $cmds.Add("set nat source rule 110 description 'Overlay NSX -> internet'")
        $cmds.Add("set nat source rule 110 outbound-interface name 'eth0'")
        $cmds.Add("set nat source rule 110 source address '$($n.OverlaySupernet)'")
        $cmds.Add("set nat source rule 110 translation address 'masquerade'")
    }
    return $cmds
}

function ConvertTo-VyosScript {
    param([Parameter(Mandatory)][string[]]$Commands)
    @(
        '#!/bin/vbash'
        'source /opt/vyatta/etc/functions/script-template'
        'configure'
        $Commands
        'commit'
        'save'
        'exit'
        'echo "VyOS configurado"'
    ) -join "`n"
}

function Get-EsxiNicMac {
    # MAC estático determinístico: <prefixo>:<0x10+host>:<nic> (faixa manual da VMware 00:50:56:00-3F)
    param([string]$Prefix, [int]$HostIndex, [int]$NicIndex)
    '{0}:{1:X2}:{2:X2}' -f $Prefix, (0x10 + $HostIndex), $NicIndex
}

# ----------------------------------------------------------------- Espera / testes
function Wait-TcpPort {
    param(
        [Parameter(Mandatory)][string]$ComputerName,
        [Parameter(Mandatory)][int]$Port,
        [int]$TimeoutSec = 1800,
        [int]$IntervalSec = 15
    )
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    while ((Get-Date) -lt $deadline) {
        $client = [System.Net.Sockets.TcpClient]::new()
        try {
            $task = $client.ConnectAsync($ComputerName, $Port)
            if ($task.Wait(3000) -and $client.Connected) { return $true }
        } catch { } finally { $client.Dispose() }
        Start-Sleep -Seconds $IntervalSec
    }
    return $false
}

function Exit-EsxiMaintenanceMode {
    # Repete até o host confirmar 'Disabled': logo após o boot o hostd ainda não aceita o comando.
    param([Parameter(Mandatory)]$Session, [int]$TimeoutSec = 300)
    $deadline = (Get-Date).AddSeconds($TimeoutSec)
    do {
        Invoke-SSHCommand -SSHSession $Session -Command 'esxcli system maintenanceMode set --enable false' -TimeOut 120 -ErrorAction SilentlyContinue | Out-Null
        $state = (Invoke-SSHCommand -SSHSession $Session -Command 'esxcli system maintenanceMode get' -TimeOut 60 -ErrorAction SilentlyContinue).Output -join ''
        if ($state -match 'Disabled') { return $true }
        Start-Sleep -Seconds 15
    } while ((Get-Date) -lt $deadline)
    return $false
}

function Get-BasicAuthHeader {
    param([string]$User, [string]$Password)
    $b64 = [Convert]::ToBase64String([Text.Encoding]::ASCII.GetBytes("${User}:${Password}"))
    @{ Authorization = "Basic $b64" }
}

function Assert-Admin {
    if ($IsLinux) {
        if ((& id -u) -ne '0') { throw 'Rode como root na svc01: sudo pwsh, ou sudo -i e depois pwsh.' }
        return
    }
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    if (-not ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)) {
        throw 'Execute este script em um PowerShell 7 aberto como Administrador.'
    }
}

# ----------------------------------------------------------------- svc01 Linux (Ubuntu 24.04)
function Invoke-LabNative {
    # Roda um comando do Linux e devolve a saída; com -Check, falha se o código de saída não for 0.
    param([Parameter(Mandatory)][string]$File, [string[]]$Arguments = @(), [switch]$Check)
    $out = & $File @Arguments 2>&1
    if ($Check -and $LASTEXITCODE) { throw "$File $($Arguments -join ' ') falhou ($LASTEXITCODE): $($out -join ' ')" }
    $out
}

function Write-LabTextFile {
    # Arquivo texto com fim de linha LF e sem BOM (configs do Linux, kickstart)
    param([Parameter(Mandatory)][string]$Path, [Parameter(Mandatory)][AllowEmptyString()][string]$Content)
    $dir = Split-Path $Path -Parent
    if ($dir -and -not (Test-Path $dir)) { New-Item -ItemType Directory -Path $dir -Force | Out-Null }
    [System.IO.File]::WriteAllText($Path, ($Content -replace "`r`n", "`n"), [System.Text.UTF8Encoding]::new($false))
}

function Set-LabNginxSite {
    <#
        Site estático no nginx da svc01 (depot e kickstart). Sem compressão (arquivos já comprimidos), sem
        cache/ETag (metadata velho em cache trava o Installer - KB 447589), listagem de pasta ligada e qualquer
        extensão servida como binário (o problema de MIME do IIS não existe aqui).
    #>
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Listen,
          [Parameter(Mandatory)][string]$Root)
    if (-not (Test-Path $Root)) { throw "Pasta do site $Name não existe: $Root" }
    $avail = $Config.Svc01.NginxSites
    $conf = @"
# gerado pela automação do lab VCF 9.1.1 (site $Name) - rodar a etapa de novo sobrescreve
server {
    listen $Listen;
    server_name _;
    root $Root;
    autoindex on;
    gzip off;
    sendfile on;
    tcp_nopush on;
    etag off;
    if_modified_since off;
    add_header Cache-Control "no-store, no-cache, must-revalidate" always;
    default_type application/octet-stream;
    types {
        application/json json;
        application/xml  xml ovf;
        text/plain       cfg txt mf sha256 asc;
        text/yaml        yaml yml;
    }
    location / { try_files `$uri `$uri/ =404; }
    access_log /var/log/nginx/$Name.access.log;
    error_log  /var/log/nginx/$Name.error.log;
}
"@
    $file = Join-Path $avail $Name
    Write-LabTextFile -Path $file -Content $conf
    $link = Join-Path (Join-Path (Split-Path $avail -Parent) 'sites-enabled') $Name
    if (-not (Test-Path $link)) { New-Item -ItemType SymbolicLink -Path $link -Target $file | Out-Null }
    # o nginx (www-data) precisa atravessar cada pasta até o Root
    $p = $Root
    while ($p -and $p -ne '/') { Invoke-LabNative chmod @('o+rx', $p) | Out-Null; $p = Split-Path $p -Parent }
    Invoke-LabNative nginx @('-t') -Check | Out-Null
    Invoke-LabNative systemctl @('reload', 'nginx') -Check | Out-Null
    Write-LabLog "nginx: site $Name em http://$Listen/ -> $Root" 'OK'
}

function Remove-LabNginxSite {
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][string]$Name)
    $avail = $Config.Svc01.NginxSites
    $link = Join-Path (Join-Path (Split-Path $avail -Parent) 'sites-enabled') $Name
    Remove-Item $link, (Join-Path $avail $Name) -Force -ErrorAction SilentlyContinue
    Invoke-LabNative systemctl @('reload', 'nginx') | Out-Null
}

function Resolve-LabDns {
    # Consulta direta no DNS do lab (dig), sem cache local. Devolve o primeiro resultado ou $null.
    param([Parameter(Mandatory)][string]$Name, [Parameter(Mandatory)][string]$Server, [ValidateSet('A', 'PTR')][string]$Type = 'A')
    $q = if ($Type -eq 'PTR') { @('+short', '-x', $Name, "@$Server") } else { @('+short', $Name, 'A', "@$Server") }
    $out = & dig @q 2>$null
    $r = @($out | Where-Object { $_ -and $_ -notmatch '^;' }) | Select-Object -First 1
    if ($r) { $r.TrimEnd('.') } else { $null }
}

function Test-LabNtp {
    # Pergunta SNTP (UDP 123) ao servidor e devolve stratum e diferença de hora em segundos.
    param([Parameter(Mandatory)][string]$Server, [int]$TimeoutMs = 3000)
    $udp = [System.Net.Sockets.UdpClient]::new()
    try {
        $udp.Client.ReceiveTimeout = $TimeoutMs
        $req = [byte[]]::new(48); $req[0] = 0x1B
        $udp.Connect($Server, 123); [void]$udp.Send($req, 48)
        $ep = [System.Net.IPEndPoint]::new([System.Net.IPAddress]::Any, 0)
        $resp = $udp.Receive([ref]$ep)
        [uint64]$sec = 0; for ($i = 40; $i -lt 44; $i++) { $sec = ($sec * 256) + $resp[$i] }
        [uint64]$frac = 0; for ($i = 44; $i -lt 48; $i++) { $frac = ($frac * 256) + $resp[$i] }
        $t = [datetime]::new(1900, 1, 1, 0, 0, 0, [DateTimeKind]::Utc).AddSeconds($sec + ($frac / 4294967296.0))
        [pscustomobject]@{ Ok = ($resp[1] -gt 0 -and $resp[1] -lt 16); Stratum = $resp[1]; OffsetSec = [math]::Round(($t - [datetime]::UtcNow).TotalSeconds, 3); Error = $null }
    } catch {
        [pscustomobject]@{ Ok = $false; Stratum = $null; OffsetSec = $null; Error = $_.Exception.Message }
    } finally { $udp.Dispose() }
}

function Get-LabLocalIps {
    # IPv4 configurados nesta máquina (Linux: ip; Windows: Get-NetIPAddress)
    if ($IsLinux) { @((& ip -4 -o addr show 2>$null) | ForEach-Object { if ($_ -match 'inet (\d+\.\d+\.\d+\.\d+)/') { $Matches[1] } }) }
    else { @(Get-NetIPAddress -AddressFamily IPv4 -ErrorAction SilentlyContinue | ForEach-Object IPAddress) }
}

# ----------------------------------------------------------------- DRS durante o deploy (lição do Workstation, 14/11)
function Set-LabVsanDefaultPolicyRules {
    <#
        Ajusta regras da política padrão do datastore vSAN (a que as VMs do deploy usam), mantendo as outras.
        -Rules: nome da capability SPBM -> valor. Ex.: @{ 'VSAN.checksumDisabled' = $true; 'VSAN.hostFailuresToTolerate' = 0 }
        Só a política muda: as VMs existentes ficam "fora de data" até um REAPPLY no vCenter
        (VM Storage Policies > política > VM Compliance), para não gerar resync sem você decidir.
        Devolve: ok (nome) | alterado (nome) | vcenter-indisponivel | sem-vm | erro: ...
    #>
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][hashtable]$Rules)
    $v = $Config.Vcf
    $vc = "$($v.Vcenter.Hostname).$($Config.Domain)"
    if (-not (Wait-TcpPort -ComputerName $vc -Port 443 -TimeoutSec 5 -IntervalSec 1)) { return 'vcenter-indisponivel' }
    $srv = $null
    try {
        Import-Module VMware.VimAutomation.Core, VMware.VimAutomation.Storage -ErrorAction Stop -WarningAction SilentlyContinue | Out-Null
        $srv = Connect-VIServer -Server $vc -User 'administrator@vsphere.local' -Password $v.Vcenter.SsoPassword -NotDefault -Force -ErrorAction Stop -WarningAction SilentlyContinue
        # a política padrão do datastore é a que o deploy aplicou nas VMs dele (vCenter primeiro)
        $vm = Get-VM -Server $srv -Name $v.Vcenter.Hostname -ErrorAction SilentlyContinue
        if (-not $vm) { $vm = Get-Datastore -Server $srv | Where-Object Type -eq 'vsan' | Get-VM -Server $srv | Select-Object -First 1 }
        if (-not $vm) { return 'sem-vm' }
        $pol = (Get-SpbmEntityConfiguration -VM $vm -Server $srv).StoragePolicy
        if (-not $pol) { return 'erro: a VM de referência está sem política de armazenamento' }
        $rs = @($pol.AnyOfRuleSets)[0]
        $have = @{}; foreach ($r in $rs.AllOfRules) { if ($r.Capability) { $have[$r.Capability.Name] = $r.Value } }
        $diff = @($Rules.Keys | Where-Object { -not $have.ContainsKey($_) -or "$($have[$_])" -ne "$($Rules[$_])" })
        if (-not $diff) { return "ok ($($pol.Name))" }
        $newRules = @(foreach ($r in $rs.AllOfRules) {
            if ($r.Capability -and $Rules.ContainsKey($r.Capability.Name)) { New-SpbmRule -Capability $r.Capability -Value $Rules[$r.Capability.Name] }
            elseif ($r.Capability) { New-SpbmRule -Capability $r.Capability -Value $r.Value }
            else { New-SpbmRule -AnyOfTags $r.AnyOfTags }
        })
        foreach ($k in $Rules.Keys | Where-Object { -not $have.ContainsKey($_) }) {
            $newRules += New-SpbmRule -Capability (Get-SpbmCapability -Server $srv -Name $k) -Value $Rules[$k]
        }
        Set-SpbmStoragePolicy -StoragePolicy $pol -AnyOfRuleSets (New-SpbmRuleSet -AllOfRules $newRules) -Confirm:$false -ErrorAction Stop | Out-Null
        return "alterado ($($pol.Name): $($diff -join ', '))"
    } catch {
        return "erro: $($_.Exception.Message)"
    } finally {
        if ($srv) { Disconnect-VIServer -Server $srv -Confirm:$false -ErrorAction SilentlyContinue }
    }
}

function Disable-LabVdsTrafficShaping {
    <#
        Desliga o traffic shaping (entrada e saída) de todas as port groups dos VDS do vCenter conectado.
        O shaping ligado com os valores sugeridos pelo vSphere (média = pico = 100.000 Kbit/s) segura vSAN e
        vMotion em ~12 MB/s - a mesma velocidade do clone travado no lab do Workstation. O VCF não liga shaping;
        isto só desfaz um shaping ligado à mão. Devolve quantas políticas foram desligadas.
    #>
    param([Parameter(Mandatory)]$Server)
    Import-Module VMware.VimAutomation.Vds -ErrorAction Stop -WarningAction SilentlyContinue | Out-Null
    $n = 0
    foreach ($pg in @(Get-VDPortgroup -Server $Server -ErrorAction SilentlyContinue | Where-Object { -not $_.IsUplink })) {
        foreach ($dir in 'In', 'Out') {
            $p = Get-VDTrafficShapingPolicy -VDPortgroup $pg -Direction $dir -ErrorAction SilentlyContinue
            if ($p -and $p.Enabled) {
                $p | Set-VDTrafficShapingPolicy -Enabled $false -ErrorAction Stop | Out-Null
                $script:LabShapingLog += "$($pg.Name) ($dir, $([int]($p.AverageBandwidth / 1000)) Kbit/s)"
                $n++
            }
        }
    }
    $n
}

function Set-LabClusterDrs {
    <#
        Põe o DRS do cluster de gerência no nível pedido, se o vCenter e o cluster já existirem.
        Devolve: ok | alterado | vcenter-indisponivel | cluster-ausente | drs-desligado | erro: ...
        Abre uma conexão separada (não mexe na conexão com o ESXi físico).
    #>
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][ValidateSet('FullyAutomated', 'PartiallyAutomated', 'Manual')][string]$Level)
    $v = $Config.Vcf
    $vc = "$($v.Vcenter.Hostname).$($Config.Domain)"
    if (-not (Wait-TcpPort -ComputerName $vc -Port 443 -TimeoutSec 5 -IntervalSec 1)) { return 'vcenter-indisponivel' }
    $srv = $null
    try {
        Import-Module VMware.VimAutomation.Core -ErrorAction Stop -WarningAction SilentlyContinue | Out-Null
        $srv = Connect-VIServer -Server $vc -User 'administrator@vsphere.local' -Password $v.Vcenter.SsoPassword -NotDefault -Force -ErrorAction Stop -WarningAction SilentlyContinue
        # traffic shaping nas port groups dos VDS (Vcf.DisableTrafficShaping, padrão: desliga)
        if (-not ($v.ContainsKey('DisableTrafficShaping') -and $v.DisableTrafficShaping -eq $false)) {
            try { [void](Disable-LabVdsTrafficShaping -Server $srv) } catch { $script:LabShapingLog += "erro: $($_.Exception.Message)" }
        }
        $cl = Get-Cluster -Server $srv -Name $v.Cluster -ErrorAction SilentlyContinue
        if (-not $cl) { return 'cluster-ausente' }
        if (-not $cl.DrsEnabled) { return 'drs-desligado' }
        if ("$($cl.DrsAutomationLevel)" -eq $Level) { return 'ok' }
        Set-Cluster -Cluster $cl -DrsAutomationLevel $Level -Confirm:$false -ErrorAction Stop | Out-Null
        return 'alterado'
    } catch {
        return "erro: $($_.Exception.Message)"
    } finally {
        if ($srv) { Disconnect-VIServer -Server $srv -Confirm:$false -ErrorAction SilentlyContinue }
    }
}

function Invoke-LabDrsGuard {
    # Chamado a cada volta do acompanhamento do deploy. Loga só quando o estado muda.
    param([Parameter(Mandatory)]$Config, [Parameter(Mandatory)][hashtable]$State, [string]$Level)
    if ($State.Disabled -or -not $Level) { return }
    try { $res = Set-LabClusterDrs -Config $Config -Level $Level } catch { $res = "erro: $($_.Exception.Message)" }
    if ($script:LabShapingLog) {
        foreach ($x in $script:LabShapingLog) {
            if ($x -like 'erro:*') { Write-LabLog "  traffic shaping: $x" 'WARN' }
            else { Write-LabLog "  traffic shaping desligado: $x" 'WARN' }
        }
        $script:LabShapingLog = @()
    }
    $key = $res -replace '^erro.*', 'erro'
    if ($key -eq $State.Last) { return }
    $State.Last = $key
    switch -Regex ($res) {
        '^alterado$' { Write-LabLog "  DRS do cluster $($Config.Vcf.Cluster) -> $Level (sem vMotion automático durante o deploy)" 'OK' }
        '^ok$'       { Write-LabLog "  DRS do cluster em $Level" }
        '^erro'      { Write-LabLog "  DRS: $res (tento de novo na próxima volta)" 'WARN' }
        default      { }
    }
}

$script:LabShapingLog = @()
Export-ModuleMember -Function *
