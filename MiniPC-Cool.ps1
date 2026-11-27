<#
  미니PC 발열관리 v1.1 - Firebat F1 (Ryzen 5 7640HS / Ryzen 7 H 255)
  MIT License (LICENSE.txt). Firebat 공식 프로그램이 아니며, 사용에 따른 책임은 사용자에게 있다.

  미니PC 발열을 줄이는 윈도우 전원 설정을 버튼 하나로 적용한다. 방법은 두 가지.
  - 부스트 끄기 (99%)  : 부스트를 끄고 최대 프로세서 상태 99% → 기본 클럭 근처까지만
  - 최대 클럭 제한     : 최대 프로세서 주파수(MHz)만 낮춘다. 값은 직접 정할 수 있다
  윈도우 전원 계획만 바꾼다(드라이버·외부 프로그램 없음). '원래대로'로 언제든 되돌린다.
  전력 제한(W)은 바이오스에서 거는 게 확실해서 방법 안내와 '바이오스로 재부팅' 버튼만 둔다.

  사용: 같은 폴더의 '발열관리 실행.bat' 더블클릭
  명령줄(관리자 PowerShell): -RunAction boostoff | quiet | base | game | clock -Clock <MHz> | restore | status
  시험: -DryRun 을 붙이면 실제로 바꾸지 않고 실행할 명령만 출력한다
#>
param(
    [switch]$DryRun,
    [ValidateSet('', 'boostoff', 'recommend', 'quiet', 'base', 'game', 'clock', 'restore', 'status')]
    [string]$RunAction = '',
    [int]$Clock = 0,            # -RunAction clock 일 때 최대 클럭(MHz)
    [switch]$Elevated,          # 내부용: 관리자 권한으로 다시 띄운 창임을 표시
    [string]$UserDesktop = '',  # 내부용: 처음 실행한 사용자의 바탕화면 경로
    [string]$Snapshot = '',     # 시험용: 화면을 그림 파일로 저장하고 끝낸다
    [string]$FakeCpu = ''       # 시험용: 다른 PC에서 F1 화면을 미리 볼 때 CPU 이름을 대신 넣는다
)

$ErrorActionPreference = 'Stop'
# 숫자 표기를 윈도우 언어·지역 설정과 상관없이 같게 한다(4,600 MHz, 4.3GHz)
try { [System.Threading.Thread]::CurrentThread.CurrentCulture = [System.Globalization.CultureInfo]::InvariantCulture } catch { }
$ScriptPath = $MyInvocation.MyCommand.Path
$AppDir = Split-Path -Parent $ScriptPath
$AppName = '미니PC 발열관리'   # 전원 계획·바로가기 이름에도 쓰므로 버전은 넣지 않는다
$AppVersion = 'v1.1'
$Disclaimer = 'Firebat 공식 프로그램이 아니에요. 있는 그대로 제공되며, 사용에 따른 책임은 사용자에게 있어요.'

# 관리자 권한으로 도는 프로그램이라 윈도우에 들어 있는 실행 파일은 경로째로 부른다
$SysDir = Join-Path $env:SystemRoot 'System32'
$PowerCfgExe = Join-Path $SysDir 'powercfg.exe'
$ShutdownExe = Join-Path $SysDir 'shutdown.exe'
$NotepadExe = Join-Path $SysDir 'notepad.exe'
$PsExe = Join-Path $SysDir 'WindowsPowerShell\v1.0\powershell.exe'
if (-not (Test-Path -LiteralPath $PsExe)) { $PsExe = Join-Path $PSHOME 'powershell.exe' }

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ---------- 관리자 권한으로 다시 실행 ----------
if (-not (Test-Admin) -and -not $DryRun -and -not $Snapshot -and $RunAction -ne 'status') {
    if ($RunAction) {
        # 명령줄에서는 숨은 창으로 넘기지 않는다(결과가 안 보이게 되므로)
        Write-Host '전원 설정을 바꾸려면 관리자 PowerShell에서 실행해 주세요. (-DryRun 을 붙이면 바꾸지 않고 명령만 볼 수 있어요)'
        exit 1
    }
    Add-Type -AssemblyName System.Windows.Forms
    if ($Elevated) {
        # 관리자 권한으로 다시 띄웠는데도 관리자가 아니면 계속 되풀이하지 않고 멈춘다
        [void][System.Windows.Forms.MessageBox]::Show("관리자 권한을 얻지 못했어요.`n관리자 계정으로 로그인한 뒤 다시 실행해 주세요.", $AppName)
        exit 1
    }
    # 네트워크 위치(공유 폴더, 네트워크 드라이브)에 있으면 관리자 권한 쪽에서 파일을 찾지 못할 수 있다
    $onNetwork = $false
    try {
        $root = [System.IO.Path]::GetPathRoot($ScriptPath)
        if ($root -and $root.StartsWith('\\')) { $onNetwork = $true }
        elseif ($root) { $onNetwork = ((New-Object System.IO.DriveInfo($root)).DriveType -eq [System.IO.DriveType]::Network) }
    } catch { }
    if ($onNetwork) {
        [void][System.Windows.Forms.MessageBox]::Show("네트워크 위치에서는 실행할 수 없어요.`n폴더를 이 PC(바탕화면 등)로 복사한 뒤 다시 실행해 주세요.", $AppName)
        exit 1
    }
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', "`"$ScriptPath`"", '-Elevated')
    # 바로가기는 처음 실행한 사용자의 바탕화면에 만들어야 하므로 그 경로를 넘긴다
    $desk = ''
    try { $desk = ([Environment]::GetFolderPath('Desktop')).TrimEnd('\') } catch { }
    if ($desk -and $desk -notmatch '"') { $argList += @('-UserDesktop', "`"$desk`"") }
    try {
        Start-Process -FilePath $PsExe -Verb RunAs -ArgumentList $argList | Out-Null
    } catch {
        [void][System.Windows.Forms.MessageBox]::Show('관리자 권한을 허용해야 전원 설정을 바꿀 수 있어요.', $AppName)
    }
    exit
}

# ---------- 상수 ----------
$GUID_MINE     = 'f1c0011e-7640-4255-a1c3-0d1ce0c0ffee'   # 이 프로그램이 만드는 전원 계획
$GUID_BALANCED = '381b4222-f694-41f0-9685-ff5bb260df2e'   # 윈도우 기본 '균형 조정'
$SUB_PROCESSOR = '54533251-82be-4824-96c1-47b60b740d00'   # 프로세서 전원 관리
$S_BOOST       = 'be337238-0d82-4146-a960-4f3749d470c7'   # 프로세서 성능 강화 모드(숨김 항목)
$S_MAXSTATE    = 'bc5038f7-23e0-4960-96da-33abaf5935ec'   # 최대 프로세서 상태(%)
$S_MAXFREQ     = '75b0ae3f-bce0-45a7-8c89-c9611c25e100'   # 최대 프로세서 주파수(MHz, 숨김 항목)
$S_MINSTATE    = '893dee8e-2bef-41e0-89c6-b55d0929964c'   # 최소 프로세서 상태(%)
# 코어 종류가 여럿인 CPU(성능·효율 코어)에는 같은 항목이 코어 등급별로 따로 있다(등급 1, 2)
$S_MAXSTATE_MORE = @('bc5038f7-23e0-4960-96da-33abaf5935ed', 'bc5038f7-23e0-4960-96da-33abaf5935ee')
$S_MAXFREQ_MORE  = @('75b0ae3f-bce0-45a7-8c89-c9611c25e101', '75b0ae3f-bce0-45a7-8c89-c9611c25e102')
$S_MINSTATE_MORE = @('893dee8e-2bef-41e0-89c6-b55d0929964d', '893dee8e-2bef-41e0-89c6-b55d0929964e')
$BOOST_OFF = 0   # 사용 안 함
$BOOST_ON  = 1   # 사용 - 부스트를 쓰되 윈도우가 정한 상한(최대 주파수)을 지키는 방식
$GuidRx = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'
# 되돌릴 때 쓸 '이전 전원 계획'을 기억해 두는 곳(관리자만 쓸 수 있는 레지스트리)
$StateKey = 'HKLM:\SOFTWARE\MiniPCCool'
# 예전 버전(v1.0)이 기억해 두던 파일. 읽기만 하고, 되돌릴 때 치운다
$LegacyStateDir  = Join-Path $env:ProgramData 'MiniPCCool'
$LegacyStateFile = Join-Path $LegacyStateDir 'previous-scheme.txt'

$BoostNames = @{
    0 = '사용 안 함'; 1 = '사용'; 2 = '적극적(윈도우 기본)'; 3 = '효율적으로 활성화됨'
    4 = '적극적으로 효율화됨'; 5 = '보장될 때 적극적'; 6 = '보장될 때 적극적으로 효율화됨'
}
$script:Log = New-Object System.Collections.Generic.List[string]
$script:LastSetError = ''

# ---------- powercfg ----------
function Invoke-PowerCfg {
    param([string[]]$A, [switch]$Change)
    if ($Change) { $script:Log.Add('powercfg ' + ($A -join ' ')) }
    if ($Change -and $DryRun) { return @() }
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $out = & $PowerCfgExe @A 2>&1 } finally { $ErrorActionPreference = $old }
    if ($LASTEXITCODE -ne 0) { throw ("powercfg {0} 실패: {1}" -f ($A -join ' '), (($out | ForEach-Object { "$_" }) -join ' ')) }
    return $out
}

function Get-ActiveSchemeGuid {
    $o = (Invoke-PowerCfg @('/getactivescheme')) -join ' '
    if ($o -match "($GuidRx)") { return $Matches[1].ToLower() }
    throw '지금 쓰는 전원 계획을 알아내지 못했어요.'
}

function Get-SchemeList {
    $list = @()
    foreach ($line in (Invoke-PowerCfg @('/list'))) {
        if ("$line" -match "($GuidRx)\s*\((.*)\)") {
            $list += [pscustomobject]@{ Guid = $Matches[1].ToLower(); Name = $Matches[2].Trim() }
        }
    }
    return $list
}

function Test-Scheme([string]$g) { return [bool](Get-SchemeList | Where-Object { $_.Guid -eq $g }) }

# /qh 출력의 마지막 두 0x 값이 현재 AC(전원 연결)·DC(배터리) 값이다. 언어와 상관없이 읽힌다.
# 이 PC에 없는 항목이면 $null.
function Get-SettingValue([string]$scheme, [string]$setting) {
    try { $o = (Invoke-PowerCfg @('/qh', $scheme, $SUB_PROCESSOR, $setting)) -join "`n" } catch { return $null }
    $hex = @([regex]::Matches($o, '0x([0-9a-fA-F]{8})') | ForEach-Object { [Convert]::ToInt64($_.Groups[1].Value, 16) })
    if ($hex.Count -lt 2) { return $null }
    return [pscustomobject]@{ AC = $hex[$hex.Count - 2]; DC = $hex[$hex.Count - 1] }
}

function Get-CurrentState {
    $active = Get-ActiveSchemeGuid
    $name = (Get-SchemeList | Where-Object { $_.Guid -eq $active } | Select-Object -First 1).Name
    $b = Get-SettingValue $active $S_BOOST
    $m = Get-SettingValue $active $S_MAXSTATE
    $f = Get-SettingValue $active $S_MAXFREQ
    return [pscustomobject]@{
        Guid = $active; Name = $name; IsMine = ($active -eq $GUID_MINE)
        Boost = $(if ($b) { [int]$b.AC } else { -1 })
        MaxState = $(if ($m) { [int]$m.AC } else { -1 })
        MaxFreq = $(if ($f -and $f.AC -le 100000) { [int]$f.AC } else { 0 })
    }
}

# ---------- 이전 전원 계획 기억 ----------
function Save-PreviousScheme([string]$guid) {
    if (-not (Test-Path -LiteralPath $StateKey)) { New-Item -Path $StateKey -Force | Out-Null }
    New-ItemProperty -LiteralPath $StateKey -Name 'PreviousScheme' -Value $guid -PropertyType String -Force | Out-Null
}

# 기억해 둔 계획의 GUID. 없거나 GUID 모양이 아니면 $null.
function Get-PreviousScheme {
    $v = $null
    try { $v = (Get-ItemProperty -LiteralPath $StateKey -Name 'PreviousScheme' -ErrorAction Stop).PreviousScheme } catch { }
    if (-not $v) {
        try { if (Test-Path -LiteralPath $LegacyStateFile) { $v = Get-Content -LiteralPath $LegacyStateFile -Raw -ErrorAction Stop } } catch { }
    }
    if (-not $v) { return $null }
    $v = "$v".Trim().ToLower()
    if ($v -notmatch "^$GuidRx$") { return $null }
    return $v
}

function Clear-PreviousScheme {
    try { if (Test-Path -LiteralPath $StateKey) { Remove-Item -LiteralPath $StateKey -Recurse -Force } } catch { }
    # 예전 버전이 남긴 파일·폴더도 치운다. 다른 곳으로 이어진 폴더(링크)면 건드리지 않는다.
    try {
        if (Test-Path -LiteralPath $LegacyStateDir) {
            $d = Get-Item -LiteralPath $LegacyStateDir -Force
            if (-not ($d.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
                if (Test-Path -LiteralPath $LegacyStateFile) { Remove-Item -LiteralPath $LegacyStateFile -Force }
                if (-not (Get-ChildItem -LiteralPath $LegacyStateDir -Force)) { Remove-Item -LiteralPath $LegacyStateDir -Force }
            }
        }
    } catch { }
}

# ---------- CPU ----------
function Get-CpuInfo {
    $name = ''; $mhz = 0
    try {
        $p = Get-CimInstance Win32_Processor -Property Name, MaxClockSpeed -ErrorAction Stop | Select-Object -First 1
        $name = ("$($p.Name)" -replace '\s+', ' ').Trim()
        $mhz = [int]$p.MaxClockSpeed
    } catch { }
    if ($FakeCpu) { $name = $FakeCpu }
    if (-not $name) { $name = '알 수 없는 CPU' }
    if ($name -match 'Ryzen.*\b7640HS\b') {
        return [pscustomobject]@{ Name = $name; Model = '7640HS'; Label = 'Ryzen 5 7640HS (6코어)'
            Base = 4300; Boost = 5000; Quiet = 3400; Game = 4600; Min = 2000; Max = 5000 }
    }
    if ($name -match 'Ryzen.*\bH ?255\b') {
        return [pscustomobject]@{ Name = $name; Model = 'H255'; Label = 'Ryzen 7 H 255 (8코어)'
            Base = 3800; Boost = 4900; Quiet = 3000; Game = 4400; Min = 2000; Max = 4900 }
    }
    # 그 밖의 CPU: 윈도우가 알려 주는 기본 클럭을 그대로 쓴다. 모르면 0(부스트 최대값은 알 수 없음).
    $base = 0
    if ($mhz -ge 400 -and $mhz -le 6000) { $base = [int]([math]::Round($mhz / 100.0) * 100) }
    # 빠른 선택 값은 기본 클럭이 충분히 높을 때만 만든다(낮은 CPU에서 엉뚱하게 느려지지 않게)
    $quiet = 0
    if ($base -ge 2000) { $quiet = [int]([math]::Round($base * 0.8 / 100.0) * 100) }
    return [pscustomobject]@{ Name = $name; Model = 'other'; Label = $name
        Base = $base; Boost = 0; Quiet = $quiet; Game = 0; Min = 1000; Max = 6000 }
}

# ---------- 적용할 설정(모드) ----------
function New-BoostOffMode {
    return [pscustomobject]@{ Kind = 'boostoff'; Title = '부스트 끄기 (99%)'; Boost = $BOOST_OFF; MaxState = 99; MaxFreq = 0 }
}

# 최대 클럭 제한. 기본 클럭 이하면 부스트가 필요 없으니 끄고, 그보다 높으면 부스트를 켜되 상한을 지키게 한다.
# 기본 클럭을 모르는 CPU에서는 부스트를 끄지 않는다(끄면 기본 클럭에 묶여 정한 값까지 못 올라갈 수 있으므로).
function New-ClockMode([int]$mhz) {
    $cpu = $script:Cpu
    if ($mhz -lt $cpu.Min -or $mhz -gt $cpu.Max) {
        throw ('최대 클럭은 {0}~{1} MHz 사이로 정해 주세요.' -f $cpu.Min, $cpu.Max)
    }
    $boost = if ($cpu.Base -gt 0 -and $mhz -le $cpu.Base) { $BOOST_OFF } else { $BOOST_ON }
    return [pscustomobject]@{ Kind = 'clock'; Title = ('최대 클럭 {0:N0} MHz' -f $mhz); Boost = $boost; MaxState = 100; MaxFreq = $mhz }
}

# 지금 상태가 어느 모드인지: boostoff / clock / custom(우리 계획인데 값이 다름) / none(우리 계획이 아님)
function Get-StateMode($st) {
    if (-not $st.IsMine) { return [pscustomobject]@{ Kind = 'none'; MaxFreq = 0 } }
    if ($st.MaxFreq -gt 0 -and $st.MaxState -eq 100) { return [pscustomobject]@{ Kind = 'clock'; MaxFreq = $st.MaxFreq } }
    if ($st.MaxFreq -eq 0 -and $st.Boost -eq $BOOST_OFF -and $st.MaxState -eq 99) { return [pscustomobject]@{ Kind = 'boostoff'; MaxFreq = 0 } }
    return [pscustomobject]@{ Kind = 'custom'; MaxFreq = $st.MaxFreq }
}

# 지금 설정으로 CPU가 올라갈 수 있는 클럭 상한(MHz, 대략). 제한이 없거나 알 수 없으면 0.
function Get-LimitMHz($st) {
    $base = $script:Cpu.Base
    $lim = 0
    if ($base -gt 0 -and ($st.Boost -eq $BOOST_OFF -or ($st.MaxState -ge 1 -and $st.MaxState -le 99))) {
        $lim = $base
        if ($st.MaxState -ge 1 -and $st.MaxState -lt 99) { $lim = [int]($base * $st.MaxState / 100) }
    }
    if ($st.MaxFreq -gt 0 -and ($lim -eq 0 -or $st.MaxFreq -lt $lim)) { $lim = $st.MaxFreq }
    return $lim
}

# ---------- 적용·되돌리기 ----------
# 우리 전원 계획의 한 항목을 AC(전원 연결)·DC(배터리) 둘 다 바꾼다. 이 PC에 없는 항목이면 $false.
function Set-PlanValue([string]$setting, [int]$value) {
    try {
        foreach ($cmd in @('/setacvalueindex', '/setdcvalueindex')) {
            Invoke-PowerCfg -Change @($cmd, $GUID_MINE, $SUB_PROCESSOR, $setting, [string]$value) | Out-Null
        }
        return $true
    } catch {
        $script:LastSetError = $_.Exception.Message
        return $false
    }
}

function Set-Mode($m) {
    $script:Log.Clear()
    $active = Get-ActiveSchemeGuid
    $existed = Test-Scheme $GUID_MINE
    if ($active -ne $GUID_MINE) {
        # 되돌릴 때 쓰려고 지금 쓰던 전원 계획을 기억해 둔다(기억하지 못해도 적용은 계속한다)
        if ($DryRun) { $script:Log.Add("(이전 전원 계획 기억: $active)") }
        else { try { Save-PreviousScheme $active } catch { $script:Log.Add('(이전 전원 계획을 기억하지 못함 - 되돌릴 때 균형 조정으로 돌아감)') } }
        if ($existed) {
            # 우리 계획이 남아 있는데 사용자가 다른 계획을 쓰고 있다면, 옛 복사본은 지우고 지금 계획에서 새로 복사한다.
            # (그래야 절전·화면 꺼짐 시간 같은 설정이 지금 쓰는 계획과 같아진다)
            Invoke-PowerCfg -Change @('-delete', $GUID_MINE) | Out-Null
            $existed = $false
        }
    }
    # 이미 우리 계획을 쓰는 중이면, 바꾸다 실패했을 때 되돌려 놓을 처음 값을 적어 둔다
    $before = $null
    if ($existed -and -not $DryRun) { try { $before = Get-CurrentState } catch { } }
    try {
        if (-not $existed) {
            Invoke-PowerCfg -Change @('-duplicatescheme', $active, $GUID_MINE) | Out-Null
            try { Invoke-PowerCfg -Change @('-changename', $GUID_MINE, $AppName, 'Firebat F1 발열 관리 프로그램이 만든 전원 계획') | Out-Null }
            catch { $script:Log.Add('(전원 계획 이름 바꾸기는 건너뜀 - 적용에는 상관없음)') }
        }
        # 숨김 항목을 제어판에서도 보이게(부스트 모드, 최대 주파수). 실패해도 적용에는 상관없다.
        foreach ($s in @($S_BOOST, $S_MAXFREQ)) {
            try { Invoke-PowerCfg -Change @('-attributes', $SUB_PROCESSOR, $s, '-ATTRIB_HIDE') | Out-Null }
            catch { $script:Log.Add('(제어판 표시 설정은 건너뜀 - 적용에는 상관없음)') }
        }
        # 최대 주파수부터 바꾼다. 이 항목이 없는 PC에서는 여기서 멈춰서 다른 값이 바뀌지 않는다.
        $okFreq = Set-PlanValue $S_MAXFREQ $m.MaxFreq
        if (-not $okFreq -and $m.MaxFreq -gt 0) { throw "이 PC는 최대 클럭 제한을 지원하지 않아요. '부스트 끄기 (99%)'를 써 주세요." }
        if (-not (Set-PlanValue $S_MAXSTATE $m.MaxState)) { throw ('최대 프로세서 상태를 바꾸지 못했어요. ' + $script:LastSetError) }
        if (-not (Set-PlanValue $S_BOOST $m.Boost)) { throw ('프로세서 성능 강화 모드를 바꾸지 못했어요. ' + $script:LastSetError) }
        # 코어 등급별 항목이 따로 있는 PC는 같은 값으로 맞춘다(없으면 넘어감)
        foreach ($s in $S_MAXFREQ_MORE) { [void](Set-PlanValue $s $m.MaxFreq) }
        foreach ($s in $S_MAXSTATE_MORE) { [void](Set-PlanValue $s $m.MaxState) }
        # 최소 프로세서 상태가 높게 잡혀 있으면 쉴 때도 클럭이 안 내려가므로 5%로 낮춘다(이미 낮으면 그대로)
        $probe = if ($DryRun -and -not $existed) { $active } else { $GUID_MINE }
        foreach ($s in (@($S_MINSTATE) + $S_MINSTATE_MORE)) {
            $cur = Get-SettingValue $probe $s
            if (-not $cur) { continue }
            try {
                if ($cur.AC -gt 5) { Invoke-PowerCfg -Change @('/setacvalueindex', $GUID_MINE, $SUB_PROCESSOR, $s, '5') | Out-Null }
                if ($cur.DC -gt 5) { Invoke-PowerCfg -Change @('/setdcvalueindex', $GUID_MINE, $SUB_PROCESSOR, $s, '5') | Out-Null }
            } catch { $script:Log.Add('(최소 프로세서 상태 낮추기는 건너뜀)') }
        }
        Invoke-PowerCfg -Change @('/setactive', $GUID_MINE) | Out-Null
    } catch {
        if (-not $DryRun) {
            if (-not $existed) {
                # 새로 만든 계획인데 적용을 끝내지 못했으면, 쓰지 않는 계획과 기억이 남지 않게 지운다
                try {
                    if ((Get-ActiveSchemeGuid) -ne $GUID_MINE -and (Test-Scheme $GUID_MINE)) {
                        Invoke-PowerCfg -Change @('-delete', $GUID_MINE) | Out-Null
                        Clear-PreviousScheme
                    }
                } catch { }
            } elseif ($before -and $before.IsMine -and $before.Boost -ge 0 -and $before.MaxState -ge 0) {
                # 쓰던 우리 계획을 바꾸다 실패했으면, 저장된 값과 실제 동작이 어긋나지 않게 처음 값으로 되돌려 놓는다
                try {
                    [void](Set-PlanValue $S_MAXFREQ $before.MaxFreq)
                    [void](Set-PlanValue $S_MAXSTATE $before.MaxState)
                    [void](Set-PlanValue $S_BOOST $before.Boost)
                    foreach ($s in $S_MAXFREQ_MORE) { [void](Set-PlanValue $s $before.MaxFreq) }
                    foreach ($s in $S_MAXSTATE_MORE) { [void](Set-PlanValue $s $before.MaxState) }
                    Invoke-PowerCfg -Change @('/setactive', $GUID_MINE) | Out-Null
                } catch { }
            }
        }
        throw
    }
    if (-not $DryRun) {
        $st = Get-CurrentState
        if (-not $st.IsMine -or $st.Boost -ne $m.Boost -or $st.MaxState -ne $m.MaxState -or $st.MaxFreq -ne $m.MaxFreq) {
            throw ('적용 후 다시 읽어 보니 값이 달라요 (부스트 {0}, 최대 {1}%, 주파수 {2})' -f $st.Boost, $st.MaxState, $st.MaxFreq)
        }
    }
}

# 되돌리면 $true, 이 프로그램이 만든 전원 계획이 없으면 $false
function Restore-Default {
    $script:Log.Clear()
    $script:RestoreSwitched = $false   # 쓰던 계획으로 바꿔 줬는지(이미 다른 계획을 쓰고 있었으면 $false)
    $schemes = Get-SchemeList
    if (-not ($schemes | Where-Object { $_.Guid -eq $GUID_MINE })) {
        if (-not $DryRun) { Clear-PreviousScheme }   # 계획 없이 기억만 남아 있으면 치운다
        return $false
    }
    # 이 프로그램 계획을 쓰는 중일 때만 다른 계획으로 바꾼다(사용자가 이미 다른 계획으로 바꿨으면 그대로 둔다)
    if ((Get-ActiveSchemeGuid) -eq $GUID_MINE) {
        $prev = Get-PreviousScheme
        if (-not $prev -or $prev -eq $GUID_MINE -or -not ($schemes | Where-Object { $_.Guid -eq $prev })) {
            $prev = if ($schemes | Where-Object { $_.Guid -eq $GUID_BALANCED }) { $GUID_BALANCED }
                    else { ($schemes | Where-Object { $_.Guid -ne $GUID_MINE } | Select-Object -First 1).Guid }
        }
        if (-not $prev) { throw '돌아갈 다른 전원 계획이 없어요. 제어판의 전원 옵션에서 기본 계획을 먼저 복원해 주세요.' }
        Invoke-PowerCfg -Change @('/setactive', $prev) | Out-Null
        $script:RestoreSwitched = $true
    }
    Invoke-PowerCfg -Change @('-delete', $GUID_MINE) | Out-Null
    if (-not $DryRun) { Clear-PreviousScheme }
    return $true
}

# ---------- 실시간 값 ----------
# 읽는 데 오래 걸려서(CPU 0.3초, 처음엔 10초 가까이) 창과 따로 도는 백그라운드에서 읽는다.
$LiveReader = {
    param([bool]$WithDisks)
    $r = @{ MHz = -1; Util = -1; Disks = $null; Zones = $null }
    try {
        $c = Get-CimInstance Win32_PerfFormattedData_Counters_ProcessorInformation -Filter "Name='_Total'" -ErrorAction Stop |
            Select-Object -First 1
        if ($c -and $c.ProcessorFrequency -gt 0 -and $c.PercentProcessorPerformance -gt 0) {
            $r.MHz = [int]($c.ProcessorFrequency * $c.PercentProcessorPerformance / 100)
            $r.Util = [int][math]::Min(100, $c.PercentProcessorUtility)
        }
    } catch { }
    if ($WithDisks) {
        $disks = @()
        try {
            $i = 0
            foreach ($d in (Get-PhysicalDisk -ErrorAction Stop | Sort-Object { [int]$_.DeviceId })) {
                $i++
                try {
                    $rc = $d | Get-StorageReliabilityCounter -ErrorAction Stop
                    if ($rc.Temperature -gt 0) { $disks += [pscustomobject]@{ No = $i; Name = $d.FriendlyName; Temp = [int]$rc.Temperature } }
                } catch { }
            }
        } catch { }
        $r.Disks = $disks
        $zones = @()
        try {
            foreach ($z in @(Get-CimInstance Win32_PerfFormattedData_Counters_ThermalZoneInformation -ErrorAction Stop)) {
                $k = if ($z.HighPrecisionTemperature) { $z.HighPrecisionTemperature / 10 } else { $z.Temperature }
                $t = [int][math]::Round($k - 273.15)
                if ($t -gt 0 -and $t -lt 120) { $zones += $t }
            }
        } catch { }
        $r.Zones = $zones
    }
    return $r
}

function Start-LiveReader {
    $script:Live = [hashtable]::Synchronized(@{ Stop = $false; Seq = 0; MHz = $null; Util = $null; Disks = $null; Zones = $null })
    # 읽기 함수(Read-LiveValues)를 백그라운드 쪽에 함수로 등록해 두고 부른다
    $iss = [System.Management.Automation.Runspaces.InitialSessionState]::CreateDefault()
    $iss.Commands.Add((New-Object System.Management.Automation.Runspaces.SessionStateFunctionEntry('Read-LiveValues', $LiveReader.ToString())))
    $rs = [runspacefactory]::CreateRunspace($iss)
    $rs.Open()
    $rs.SessionStateProxy.SetVariable('Live', $script:Live)
    $ps = [powershell]::Create()
    $ps.Runspace = $rs
    [void]$ps.AddScript({
        $n = 0
        while (-not $Live.Stop) {
            $v = Read-LiveValues ($n % 5 -eq 0)   # CPU는 2초마다, 디스크·온도는 10초마다
            $Live.MHz = $v.MHz; $Live.Util = $v.Util
            if ($null -ne $v.Disks) { $Live.Disks = $v.Disks; $Live.Zones = $v.Zones }
            $n++
            $Live.Seq = $n   # 새로 읽을 때마다 번호가 하나씩 올라간다
            for ($i = 0; $i -lt 20 -and -not $Live.Stop; $i++) { Start-Sleep -Milliseconds 100 }
        }
    })
    $script:LivePs = $ps
    $script:LiveRs = $rs
    $script:LiveHandle = $ps.BeginInvoke()
}

function Stop-LiveReader {
    if (-not $script:LivePs) { return }
    $script:Live.Stop = $true
    # 읽는 도중이면 멈출 때까지 기다리지 않는다(창을 닫을 때 몇 초씩 걸리지 않게). 프로그램이 끝나면 같이 끝난다.
    try { [void]$script:LivePs.BeginStop($null, $null) } catch { }
    $script:LivePs = $null
}

# ---------- 안내 글 ----------
$BiosGuide = @'
[바이오스에서 전력 제한 거는 법 - Firebat F1 (7640HS / H255 공통)]

※ 바이오스 설정은 잘못 바꾸면 부팅이 안 될 수 있어요. 아래 항목만 바꾸고, 본인 책임으로 진행하세요.

W(와트) 제한은 윈도우가 아니라 바이오스에서 걸어야 확실하게 먹습니다.
한 번 해 두면 계속 유지돼요.

1) 이 프로그램의 '바이오스로 재부팅'을 누르거나, 켤 때 Del 키를 연타합니다.
2) 오른쪽 화살표로 Advanced 탭으로 갑니다.
3) Ctrl + F1 을 누르면 숨은 메뉴가 나옵니다.
4) AMD CBS → SMU Common Options → System Configuration → 35W
   (35W는 이 CPU들의 AMD 사양 최저값입니다.)
5) F10(Save & Exit)으로 저장하고 재부팅합니다.

[선택] 부스트를 바이오스에서 끄기
   AMD CBS → CPU Common Options → Core Performance Boost → Disabled
   - 이 프로그램의 '부스트 끄기 (99%)'와 같은 효과라서, 그 버튼을 쓴다면 하지 않아도 됩니다.
   - 이 항목을 끄면 부스트가 아예 꺼집니다. 이 프로그램에서 기본 클럭보다 높은
     '최대 클럭 제한'(게임 값 등)을 쓰려면 끄지 마세요.

[주의]
- 위 항목 말고 다른 메뉴는 건드리지 마세요. 잘못 바꾸면 부팅이 안 될 수 있습니다.
- 부팅이 안 되면 메인보드 배터리를 잠시 빼서 바이오스를 초기화할 수 있습니다.
- 온도 제한은 기본값 그대로 두세요.
- 바이오스가 최신 버전인지 확인하세요.
'@

$Checklist = @'
[갑자기 안 켜지는 고장을 줄이려면]
작은 미니PC는 열이 쉽게 쌓여서, 오래 뜨겁게 쓰면 부품 수명에 좋지 않습니다.
F1은 상판이 막힌 구조라 상판 쪽(SSD)이 특히 뜨거워지기 쉽습니다.

[소프트웨어로 할 수 있는 것 - 이 프로그램]
- '부스트 끄기 (99%)': 가장 간단합니다. 쉬는 중 전력과 온도가 크게 줄어듭니다.
- '최대 클럭 제한': 성능을 덜 잃으면서 온도를 낮추고 싶을 때 씁니다.
  값을 낮출수록 시원하고, 높일수록 빠릅니다.
- 여러 코어를 오래 쓰는 작업(게임·인코딩)의 온도는 클럭보다 전력(W)의 영향을 더 받습니다.
  이럴 때는 바이오스에서 35W 전력 제한을 같이 하면 효과가 가장 큽니다.
  ('바이오스 설정 방법' 참고)

[하드웨어로 할 수 있는 것]
- 상단에 팬을 다는 교체 케이스나 서멀구리스를 다시 바르는 것으로 온도를 더 낮출 수 있습니다.
- 바닥 흡기구가 막히지 않게 받침을 대고, 위쪽에 바람이 잘 통하게 두세요.
- 동봉된 정품 어댑터를 쓰세요.

[이렇게 확인하세요]
- 이 프로그램의 'SSD 온도'가 60도를 넘으면 주의, 70도를 넘으면 높은 편입니다.
  무거운 작업을 마친 뒤 괄호 안의 '최고' 온도를 확인해 보세요(창을 연 뒤 가장 높았던 값).
  SSD가 느려지기 시작하는 온도는 제품마다 다르고, 보통 70~80도대입니다.
- 상판이 손으로 만져서 뜨거우면 통풍이나 쿨링을 보강하세요.
- CPU 온도를 정확히 보려면 HWiNFO(무료) 같은 모니터링 프로그램을 쓰세요.
  윈도우 기능만으로는 CPU 온도를 정확히 읽기 어렵습니다.
- 무거운 작업 중 온도가 계속 높게 붙어 있으면 바이오스 전력 제한을 더 낮추세요.
'@

# ---------- 화면 ----------
function Show-TextWindow([string]$title, [string]$text) {
    $f = New-Object System.Windows.Forms.Form
    $f.Text = $title
    $f.ClientSize = New-Object System.Drawing.Size(700, 600)
    $f.StartPosition = 'CenterParent'
    $tb = New-Object System.Windows.Forms.TextBox
    $tb.Multiline = $true; $tb.ReadOnly = $true; $tb.ScrollBars = 'Vertical'; $tb.Dock = 'Fill'
    $tb.Font = $script:fN; $tb.BackColor = [System.Drawing.Color]::White
    $tb.Text = ($text -replace "`r?`n", "`r`n")
    $f.Controls.Add($tb)
    $f.Add_Shown({ $tb.SelectionStart = 0; $tb.SelectionLength = 0 })
    [void]$f.ShowDialog($script:form)
    $f.Dispose()
}

function New-Label([string]$text, [int]$x, [int]$y, [int]$w, [int]$h, $font = $null) {
    $l = New-Object System.Windows.Forms.Label
    $l.Text = $text
    $l.UseMnemonic = $false
    $l.Location = New-Object System.Drawing.Point($x, $y)
    $l.Size = New-Object System.Drawing.Size($w, $h)
    $l.Font = $(if ($font) { $font } else { $script:fN })
    return $l
}

function New-Button([string]$text, [int]$x, [int]$y, [int]$w, [int]$h, $font = $null) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text
    $b.UseMnemonic = $false
    $b.Location = New-Object System.Drawing.Point($x, $y)
    $b.Size = New-Object System.Drawing.Size($w, $h)
    $b.Font = $(if ($font) { $font } else { $script:fN })
    return $b
}

function Set-Status([string]$text, $color = $null) {
    $script:lblStatus.Text = $text
    $script:lblStatus.ForeColor = $(if ($color) { $color } else { [System.Drawing.SystemColors]::ControlText })
}

# 적용 중인 버튼은 초록 바탕에 ● 표시
function Set-ButtonOn($b, [bool]$on, [string]$text) {
    $b.Text = $(if ($on) { '● ' + $text } else { $text })
    if ($on) { $b.UseVisualStyleBackColor = $false; $b.BackColor = $script:cOn }
    else { $b.BackColor = [System.Drawing.SystemColors]::Control; $b.UseVisualStyleBackColor = $true }
}

# 숫자 칸의 글자를 MHz 값으로 바꾼다. 숫자가 아니거나 범위 밖이면 $null (고쳐 쓰지 않는다)
function ConvertTo-ClockValue([string]$text) {
    $clean = ("$text" -replace '[,\s]', '')
    if ($clean -notmatch '^[0-9]{1,6}$') { return $null }   # 0-9 만 받는다(전각 숫자 등은 숫자로 바꾸지 못하므로)
    $n = [int]$clean
    if ($n -lt $script:Cpu.Min -or $n -gt $script:Cpu.Max) { return $null }
    return $n
}

# 슬라이더와 숫자 칸을 같은 값으로 맞춘다(범위를 벗어나면 가장 가까운 값으로)
function Set-ClockControls([int]$mhz) {
    $v = [math]::Max([int]$script:Cpu.Min, [math]::Min([int]$script:Cpu.Max, $mhz))
    $script:Syncing = $true
    try {
        $script:txtClock.Text = "$v"
        $t = [int][math]::Round($v / 100.0)
        $script:tbClock.Value = [math]::Max($script:tbClock.Minimum, [math]::Min($script:tbClock.Maximum, $t))
    } finally { $script:Syncing = $false }
    Update-ApplyButton
}

# '적용' 버튼의 초록 표시: 숫자 칸의 값이 지금 적용된 직접 값과 같을 때만 켠다
function Update-ApplyButton {
    $n = ConvertTo-ClockValue $script:txtClock.Text
    Set-ButtonOn $script:btnApply ($script:AppliedCustom -gt 0 -and $null -ne $n -and $n -eq $script:AppliedCustom) '적용'
}

# 속도 막대: 0 ~ 눈금 끝까지가 CPU 클럭. 파란 부분이 지금 실제 클럭, 빗금 부분이 제한으로 막힌 구간.
function Write-SpeedBar($g, [int]$w, [int]$h) {
    $max = [double]$script:ScaleMax
    if ($max -le 0) { return }
    $barH = 16
    $bw = $w - 1
    $g.FillRectangle($script:brTrack, 0, 0, $bw, $barH)
    $lim = [double]$script:BarLimit
    $lx = -1
    if ($lim -gt 0 -and $lim -lt $max) {
        $lx = [int]($lim / $max * $bw)
        $g.FillRectangle($script:brLocked, $lx, 0, $bw - $lx, $barH)
    }
    $mhz = [double]$script:BarActual
    if ($mhz -gt 0) {
        $fw = [int]([math]::Min(1.0, $mhz / $max) * $bw)
        if ($fw -gt 0) { $g.FillRectangle($script:brFill, 0, 0, $fw, $barH) }
    }
    $g.DrawRectangle($script:penBorder, 0, 0, $bw, $barH)
    if ($lx -ge 0) {
        $g.DrawLine($script:penLimit, $lx, 0, $lx, $barH)
        $txt = '제한 {0:0.0#}GHz' -f ($lim / 1000)
        $sz = $g.MeasureString($txt, $script:fT)
        $tx = if (($bw - $lx) -gt ($sz.Width + 8)) { $lx + 4 } else { $lx - $sz.Width - 4 }
        $g.DrawString($txt, $script:fT, $script:brLimitText, [single]$tx, [single]1)
    }
    # 눈금: 1GHz마다
    for ($t = 0; $t -le $max; $t += 1000) {
        $x = [int]($t / $max * $bw)
        $g.DrawLine($script:penBorder, $x, $barH, $x, $barH + 3)
        $lab = if ($t -eq 0) { '0' } elseif (($t + 1000) -gt $max) { '{0}GHz' -f [int]($t / 1000) } else { '{0}' -f [int]($t / 1000) }
        $sz = $g.MeasureString($lab, $script:fT)
        $px = [math]::Max(0, [math]::Min($bw - $sz.Width, $x - $sz.Width / 2))
        $g.DrawString($lab, $script:fT, $script:brTick, [single]$px, [single]($barH + 3))
    }
}

function Update-StateUI([bool]$SyncControls = $false) {
    $script:LastStateTick = [Environment]::TickCount
    try {
        $st = Get-CurrentState
        $mode = Get-StateMode $st
        $freqTxt = if ($st.MaxFreq -gt 0) { '{0:N0}MHz' -f $st.MaxFreq } else { '제한 없음' }
        $boostTxt = if ($BoostNames.ContainsKey($st.Boost)) { $BoostNames[$st.Boost] } else { '알 수 없음' }
        $stateTxt = if ($st.MaxState -ge 0) { "$($st.MaxState)%" } else { '알 수 없음' }
        $planName = if ($st.IsMine) { $AppName } else { $st.Name }   # 우리 계획 이름은 직접 쓴다(다른 언어 윈도우에서 깨져 읽힐 수 있어서)
        $script:lblDetail.Text = "전원 계획: $planName  ·  부스트 $boostTxt  ·  최대 $stateTxt  ·  주파수 $freqTxt"
        switch ($mode.Kind) {
            'boostoff' {
                $script:lblMode.Text = if ($script:Cpu.Base -gt 0) { '● 적용 중: 부스트 끄기 (99%) → 기본 클럭 약 {0:0.0}GHz까지' -f ($script:Cpu.Base / 1000) }
                                       else { '● 적용 중: 부스트 끄기 (99%)' }
                $script:lblMode.ForeColor = $script:cGreen
            }
            'clock' {
                $script:lblMode.Text = ('● 적용 중: 최대 클럭 {0:N0}MHz 제한' -f $mode.MaxFreq)
                $script:lblMode.ForeColor = $script:cGreen
            }
            'custom' {
                $script:lblMode.Text = '적용 중: 이 프로그램 전원 계획 (값을 직접 바꾼 상태)'
                $script:lblMode.ForeColor = [System.Drawing.SystemColors]::ControlText
            }
            default {
                $script:lblMode.Text = '적용 안 함 · 윈도우 설정 그대로'
                $script:lblMode.ForeColor = [System.Drawing.SystemColors]::ControlText
            }
        }
        $newLimit = Get-LimitMHz $st
        $watch = ($mode.Kind -eq 'boostoff' -or $mode.Kind -eq 'clock')
        if ($newLimit -ne $script:BarLimit -or $watch -ne $script:WatchLimit) { $script:OverCount = 0 }   # 설정이 바뀌면 다시 센다
        $script:BarLimit = $newLimit
        $script:WatchLimit = $watch
        # 제한이 눈금 끝이거나 그보다 높으면 빨간 선이 보이게 눈금을 늘린다(제한이 낮아지면 다시 줄어든다)
        $need = if ($newLimit -ge $script:ScaleBase) { [int]([math]::Floor($newLimit / 500.0) * 500 + 500) } else { $script:ScaleBase }
        $script:ScaleMax = [int][math]::Max($need, $script:ScaleLive)
        Set-ButtonOn $script:btnBoostOff ($mode.Kind -eq 'boostoff') ([string]$script:btnBoostOff.Tag)
        $onChip = $false
        foreach ($b in $script:ChipButtons) {
            $isOn = ($mode.Kind -eq 'clock' -and $mode.MaxFreq -eq [int]$b.Tag.MHz)
            if ($isOn) { $onChip = $true }
            Set-ButtonOn $b $isOn ([string]$b.Tag.Title)
        }
        $script:AppliedCustom = if ($mode.Kind -eq 'clock' -and -not $onChip) { [int]$mode.MaxFreq } else { 0 }
        if ($SyncControls -and $mode.Kind -eq 'clock') { Set-ClockControls $mode.MaxFreq } else { Update-ApplyButton }
    } catch {
        $script:lblMode.Text = "상태를 읽지 못했어요: $($_.Exception.Message)"
        $script:lblMode.ForeColor = [System.Drawing.Color]::Red
    }
    $script:bar.Invalidate()
}

# 백그라운드가 읽어 둔 값을 화면에 옮긴다(1초마다, 금방 끝남)
function Update-Live {
    $L = $script:Live
    if (-not $L) { return }
    if ($null -eq $L.MHz) { $script:lblClock.Text = '실제 CPU 클럭: 읽는 중…'; $script:BarActual = 0 }
    elseif ($L.MHz -le 0) { $script:lblClock.Text = '실제 CPU 클럭: 읽을 수 없음'; $script:BarActual = 0 }
    else {
        $script:lblClock.Text = ('실제 CPU 클럭: {0:N0} MHz   (사용률 {1}%)' -f $L.MHz, $L.Util)
        $script:BarActual = [int]$L.MHz
        # 눈금 끝보다 높게 나오면 눈금을 늘린다
        if ($script:BarActual -gt $script:ScaleMax) {
            $script:ScaleLive = [int]([math]::Ceiling($script:BarActual / 500.0) * 500)
            $script:ScaleMax = $script:ScaleLive
        }
        # 제한을 걸었는데 실제 클럭이 계속 그보다 높으면(새로 읽은 값 4번 연속) 이 PC에서는 제한이 듣지 않는 것
        $seq = $L.Seq
        if ($null -ne $seq -and $seq -ne $script:LastSeq) {
            $script:LastSeq = $seq
            $lim = $script:BarLimit
            if ($script:WatchLimit -and $lim -gt 0 -and $L.MHz -gt ($lim * 1.04 + 50)) { $script:OverCount++ } else { $script:OverCount = 0 }
        }
    }
    $overLimit = ($script:OverCount -ge 4)
    $script:lblClock.ForeColor = $(if ($overLimit) { [System.Drawing.Color]::DarkOrange } else { [System.Drawing.SystemColors]::ControlText })
    $script:bar.Invalidate()

    $d = $L.Disks
    if ($null -eq $d) { $script:lblSsd.Text = 'SSD 온도: 읽는 중…' }
    elseif (@($d).Count -eq 0) {
        $script:lblSsd.Text = 'SSD 온도: 읽을 수 없음'
        $script:lblSsd.ForeColor = [System.Drawing.SystemColors]::ControlText
    } else {
        # 창을 연 뒤 가장 높았던 온도를 디스크마다 기억한다(무거운 작업 뒤 한 번만 봐도 되게)
        foreach ($x in @($d)) {
            $k = "$($x.No)|$($x.Name)"
            if (-not $script:DiskMax.ContainsKey($k) -or $x.Temp -gt $script:DiskMax[$k]) { $script:DiskMax[$k] = $x.Temp }
        }
        # 디스크가 셋 이상이면 한 줄에 들어가게 짧게 쓴다
        $many = (@($d).Count -ge 3)
        $fmt = if ($many) { '디스크{0} {1}℃(최고 {2})' } else { '디스크{0} {1}℃ (최고 {2}℃)' }
        $parts = @($d) | ForEach-Object { $fmt -f $_.No, $_.Temp, $script:DiskMax["$($_.No)|$($_.Name)"] }
        $txt = 'SSD 온도: ' + ($parts -join $(if ($many) { ' / ' } else { '  /  ' }))
        if (@($d).Count -eq 1) { $txt += '   · 60℃ 주의 · 70℃ 높음' }
        $script:lblSsd.Text = $txt
        $names = (@($d) | ForEach-Object { '디스크{0}: {1}' -f $_.No, $_.Name }) -join "`r`n"
        if ($script:tip.GetToolTip($script:lblSsd) -ne $names) { $script:tip.SetToolTip($script:lblSsd, $names) }
        $max = (@($d) | Measure-Object -Property Temp -Maximum).Maximum
        $script:lblSsd.ForeColor = $(if ($max -ge 70) { [System.Drawing.Color]::Red } elseif ($max -ge 60) { [System.Drawing.Color]::DarkOrange } else { [System.Drawing.SystemColors]::ControlText })
    }

    if ($overLimit) {
        $script:lblZone.Text = '실제 클럭이 제한보다 계속 높아요. 이 PC에서는 이 방법이 듣지 않는 것 같아요. 다른 방법을 써 보세요.'
        $script:lblZone.ForeColor = [System.Drawing.Color]::DarkOrange
    } else {
        $script:lblZone.ForeColor = $script:cGray
        $z = $L.Zones
        if ($null -eq $z) { $script:lblZone.Text = '' }
        elseif (@($z).Count -gt 0) { $script:lblZone.Text = '메인보드 온도(ACPI, 참고용): ' + ((@($z) | ForEach-Object { "$_℃" }) -join ' / ') }
        else { $script:lblZone.Text = 'CPU 온도는 윈도우로는 읽을 수 없어요. 정확한 값은 HWiNFO 같은 프로그램으로 확인하세요.' }
    }
}

# $action: 모드 객체(Set-Mode에 넘길 것) 또는 문자열 'restore'
function Invoke-ModeClick($action) {
    $script:form.UseWaitCursor = $true
    try {
        if ($action -is [string] -and $action -eq 'restore') {
            $ok = Restore-Default
            if (-not $ok) { Set-Status '이 프로그램으로 바꾼 설정이 없어서 되돌릴 게 없어요.' }
            elseif ($script:RestoreSwitched) { Set-Status '원래 전원 계획으로 되돌리고, 이 프로그램이 만든 전원 계획을 지웠어요.' $script:cBlue }
            else { Set-Status '이 프로그램이 만든 전원 계획을 지웠어요. 지금 쓰는 전원 계획은 그대로예요.' $script:cBlue }
        } else {
            Set-Mode $action
            $msg = '적용했어요: {0}. 실제 클럭은 몇 초 안에 바뀝니다.'
            # 기본 클럭보다 낮은 제한은 CPU에 따라 정한 값보다 더 낮게 잡힌다(실제 측정으로 확인)
            if ($action.Kind -eq 'clock' -and $script:Cpu.Base -gt 0 -and $action.MaxFreq -lt $script:Cpu.Base) {
                $msg = '적용했어요: {0}. 기본 클럭보다 낮게 정하면 실제 클럭은 더 낮게 나올 수 있어요.'
            }
            Set-Status ($msg -f $action.Title) $script:cGreen
        }
        if ($DryRun -and $script:Log.Count -gt 0) {
            [void][System.Windows.Forms.MessageBox]::Show(("[시험 모드] 실제로는 바꾸지 않았어요. 실행할 명령:`n`n" + ($script:Log -join "`n")), $AppName)
        }
    } catch {
        Set-Status ('실패: ' + $_.Exception.Message) ([System.Drawing.Color]::Red)
    } finally {
        $script:form.UseWaitCursor = $false
    }
    Update-StateUI $true
}

# 숫자 칸에 적힌 값으로 적용한다. 쓸 수 없는 값이면 고쳐 쓰지 않고 안내만 한다.
function Invoke-CustomApply {
    $n = ConvertTo-ClockValue $script:txtClock.Text
    if ($null -eq $n) {
        Set-Status ('적용하지 않았어요. {0}~{1} 사이의 MHz 숫자로 적어 주세요. (예: 4.5GHz → 4500)' -f $script:Cpu.Min, $script:Cpu.Max) ([System.Drawing.Color]::Red)
        try { [void]$script:txtClock.Focus(); $script:txtClock.SelectAll() } catch { }
        return
    }
    try { $m = New-ClockMode $n }
    catch { Set-Status ('실패: ' + $_.Exception.Message) ([System.Drawing.Color]::Red); return }
    Invoke-ModeClick $m
}

function New-DesktopShortcut {
    # 관리자 권한으로 다시 띄운 창에서는 '처음 실행한 사용자'의 바탕화면을 쓴다
    $desk = ''
    if ($UserDesktop -and (Test-Path -LiteralPath $UserDesktop -PathType Container)) { $desk = $UserDesktop }
    if (-not $desk) { $desk = [Environment]::GetFolderPath('Desktop') }
    $ws = New-Object -ComObject WScript.Shell
    $lnk = $ws.CreateShortcut((Join-Path $desk "$AppName.lnk"))
    $lnk.TargetPath = $PsExe
    $lnk.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$ScriptPath`""
    $lnk.WorkingDirectory = $AppDir
    $lnk.WindowStyle = 7
    $icon = Join-Path $SysDir 'powercpl.dll'
    if (Test-Path -LiteralPath $icon) { $lnk.IconLocation = "$icon,0" }
    $lnk.Description = 'Firebat F1 발열 관리'
    $lnk.Save()
    [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($ws)
}

function Save-WindowImage([string]$path) {
    $f = $script:form
    $f.Refresh()
    $bmp = New-Object System.Drawing.Bitmap($f.Width, $f.Height)
    $f.DrawToBitmap($bmp, (New-Object System.Drawing.Rectangle(0, 0, $f.Width, $f.Height)))
    $bmp.Save($path, [System.Drawing.Imaging.ImageFormat]::Png)
    $bmp.Dispose()
}

function Show-MainWindow {
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()
    # 예상하지 못한 오류가 나도 영어 오류 창을 띄우지 않고 아래 상태 줄에 알린다
    if (-not $script:ErrorHookAdded) {
        try {
            [System.Windows.Forms.Application]::add_ThreadException({
                try { Set-Status ('문제가 생겼어요: ' + $_.Exception.Message) ([System.Drawing.Color]::Red) } catch { }
            })
            $script:ErrorHookAdded = $true
        } catch { }
    }
    $script:fN = New-Object System.Drawing.Font('Malgun Gothic', 10)
    $script:fB = New-Object System.Drawing.Font('Malgun Gothic', 10, [System.Drawing.FontStyle]::Bold)
    $script:fH = New-Object System.Drawing.Font('Malgun Gothic', 16, [System.Drawing.FontStyle]::Bold)
    $script:fS = New-Object System.Drawing.Font('Malgun Gothic', 9)
    $script:fT = New-Object System.Drawing.Font('Malgun Gothic', 7.5)
    $script:cGreen = [System.Drawing.Color]::FromArgb(0, 120, 60)
    $script:cBlue = [System.Drawing.Color]::FromArgb(0, 90, 160)
    $script:cGray = [System.Drawing.Color]::FromArgb(110, 110, 110)
    $script:cOn = [System.Drawing.Color]::FromArgb(205, 240, 212)
    $cBack = [System.Drawing.Color]::FromArgb(250, 250, 250)
    $script:brTrack = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(232, 234, 237))
    $script:brFill = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(66, 133, 244))
    $script:brLocked = New-Object System.Drawing.Drawing2D.HatchBrush([System.Drawing.Drawing2D.HatchStyle]::BackwardDiagonal, [System.Drawing.Color]::FromArgb(170, 170, 170), [System.Drawing.Color]::FromArgb(214, 214, 214))
    $script:brTick = New-Object System.Drawing.SolidBrush($script:cGray)
    $script:brLimitText = New-Object System.Drawing.SolidBrush([System.Drawing.Color]::FromArgb(150, 30, 30))
    $script:penBorder = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(160, 160, 160))
    $script:penLimit = New-Object System.Drawing.Pen([System.Drawing.Color]::FromArgb(200, 40, 40), 2)
    $script:Syncing = $false
    $script:BarActual = 0
    $script:BarLimit = 0
    $script:WatchLimit = $false
    $script:OverCount = 0
    $script:LastSeq = -1
    $script:AppliedCustom = 0
    $script:LastStateTick = 0
    $script:DiskMax = @{}
    $cpu = $script:Cpu
    # 막대의 눈금 끝(MHz): 처음 값(ScaleBase), 실제 클럭이 넘어서 늘어난 값(ScaleLive), 지금 쓰는 값(ScaleMax)
    $script:ScaleBase = if ($cpu.Boost -gt 0) { [int]([math]::Ceiling($cpu.Boost / 500.0) * 500) }
                        else { [int]([math]::Max(4000, [math]::Ceiling($cpu.Base * 1.35 / 500.0) * 500)) }
    $script:ScaleLive = $script:ScaleBase
    $script:ScaleMax = $script:ScaleBase

    $form = New-Object System.Windows.Forms.Form
    $script:form = $form
    $form.Text = "$AppName $AppVersion" + $(if ($DryRun) { '  [시험 모드 - 실제로 바꾸지 않음]' } else { '' })
    $form.ClientSize = New-Object System.Drawing.Size(640, 610)
    $form.FormBorderStyle = 'FixedSingle'
    $form.MaximizeBox = $false
    $form.StartPosition = 'CenterScreen'
    $form.BackColor = $cBack

    # ----- 머리말 -----
    $form.Controls.Add((New-Label $AppName 12 8 616 32 $script:fH))
    $cpuTxt = "감지된 CPU: $($cpu.Label)"
    if ($cpu.Boost -gt 0) { $cpuTxt += ('   ·   기본 {0:0.0}GHz / 부스트 {1:0.0}GHz' -f ($cpu.Base / 1000), ($cpu.Boost / 1000)) }
    $lc = New-Label $cpuTxt 14 42 614 22 $script:fB
    $lc.AutoEllipsis = $true
    $form.Controls.Add($lc)
    if ($cpu.Model -eq 'other') {
        $w = New-Label 'Firebat F1(7640HS·H255)용이에요. 이 CPU에서도 동작하지만 값은 확인되지 않았어요.' 14 64 614 20 $script:fS
        $w.ForeColor = [System.Drawing.Color]::DarkOrange
    } else {
        $w = New-Label "지원 모델이에요. 누르면 바로 적용되고, 언제든 '원래대로'로 되돌릴 수 있어요." 14 64 614 20 $script:fS
        $w.ForeColor = $script:cGreen
    }
    $form.Controls.Add($w)

    # ----- 지금 상태 -----
    $gb = New-Object System.Windows.Forms.GroupBox
    $gb.Text = '지금 상태'; $gb.Font = $script:fB
    $gb.Location = New-Object System.Drawing.Point(10, 88); $gb.Size = New-Object System.Drawing.Size(620, 164)
    $script:lblMode = New-Label '' 12 22 596 22 $script:fB
    $script:lblMode.AutoEllipsis = $true
    $script:lblDetail = New-Label '' 12 44 596 18 $script:fS
    $script:lblDetail.ForeColor = $script:cGray
    $script:lblDetail.AutoEllipsis = $true
    $script:bar = New-Object System.Windows.Forms.PictureBox
    $script:bar.Location = New-Object System.Drawing.Point(12, 66)
    $script:bar.Size = New-Object System.Drawing.Size(596, 34)
    $script:bar.Add_Paint({ try { Write-SpeedBar $_.Graphics $this.Width $this.Height } catch { } })
    $script:lblClock = New-Label '실제 CPU 클럭: 읽는 중…' 12 102 596 20
    $script:lblSsd = New-Label 'SSD 온도: 읽는 중…' 12 122 596 20
    $script:lblSsd.AutoEllipsis = $true
    $script:lblZone = New-Label '' 12 142 596 18 $script:fS
    $script:lblZone.ForeColor = $script:cGray
    $script:lblZone.AutoEllipsis = $true
    $script:tip = New-Object System.Windows.Forms.ToolTip
    $script:tip.SetToolTip($script:bar, '파란 부분: 지금 실제 클럭 / 빗금 부분: 제한으로 막힌 구간')
    $gb.Controls.AddRange(@($script:lblMode, $script:lblDetail, $script:bar, $script:lblClock, $script:lblSsd, $script:lblZone))
    $form.Controls.Add($gb)

    # ----- CPU 최대 속도 정하기 -----
    $gp = New-Object System.Windows.Forms.GroupBox
    $gp.Text = 'CPU 최대 속도 정하기 (누르면 바로 적용)'; $gp.Font = $script:fB
    $gp.Location = New-Object System.Drawing.Point(10, 258); $gp.Size = New-Object System.Drawing.Size(620, 262)

    # 방법 1: 부스트 끄기 (99%)
    $script:btnBoostOff = New-Button '부스트 끄기 (99%)' 12 24 190 50 $script:fB
    $script:btnBoostOff.Tag = '부스트 끄기 (99%)'
    $script:btnBoostOff.Add_Click({ Invoke-ModeClick (New-BoostOffMode) })
    $line1 = if ($cpu.Base -gt 0) { '부스트를 끄고 기본 클럭(약 {0:0.0}GHz)까지만 써요.' -f ($cpu.Base / 1000) }
             else { '부스트를 끄고 기본 클럭까지만 써요.' }
    $slowCpu = ($cpu.Model -eq 'other' -and $cpu.Base -gt 0 -and $cpu.Base -lt 2500)
    $line2 = if ($slowCpu) { '이 CPU는 기본 클럭이 낮아서 많이 느려질 수 있어요.' } else { '가장 간단해요. 처음이면 이것부터.' }
    $d1 = New-Label "$line1`r`n$line2" 212 26 396 46
    if ($slowCpu) { $d1.ForeColor = [System.Drawing.Color]::DarkOrange }
    $gp.Controls.AddRange(@($script:btnBoostOff, $d1))

    foreach ($sy in @(79, 207)) {
        $sep = New-Object System.Windows.Forms.Label
        $sep.AutoSize = $false
        $sep.BorderStyle = 'Fixed3D'
        $sep.Location = New-Object System.Drawing.Point(12, $sy)
        $sep.Size = New-Object System.Drawing.Size(596, 2)
        $gp.Controls.Add($sep)
    }

    # 방법 2: 최대 클럭 제한
    $t2 = New-Label '최대 클럭 제한' 12 84 112 22 $script:fB
    $h2 = New-Label '클럭 상한만 낮춰요. 기본 클럭보다 높게 잡으면 부스트를 그만큼만 씁니다.' 126 86 482 18 $script:fS
    $h2.ForeColor = $script:cGray
    $gp.Controls.AddRange(@($t2, $h2))
    $chips = @()
    if ($cpu.Quiet -gt 0) {
        $chips += [pscustomobject]@{ MHz = $cpu.Quiet; Name = '조용' }
        $chips += [pscustomobject]@{ MHz = $cpu.Base; Name = '기본' }
    }
    if ($cpu.Game -gt 0) { $chips += [pscustomobject]@{ MHz = $cpu.Game; Name = '게임' } }
    $script:ChipButtons = @()
    $x = 12
    foreach ($c in $chips) {
        $title = ('{0} {1:0.0}GHz' -f $c.Name, ($c.MHz / 1000))
        $b = New-Button $title $x 108 140 36 $script:fB
        $b.Tag = [pscustomobject]@{ MHz = [int]$c.MHz; Title = $title }
        $b.Add_Click({
            try { $m = New-ClockMode ([int]$this.Tag.MHz) }
            catch { Set-Status ('실패: ' + $_.Exception.Message) ([System.Drawing.Color]::Red); return }
            Invoke-ModeClick $m
        })
        $script:ChipButtons += $b
        $gp.Controls.Add($b)
        $x += 148
    }
    if ($chips.Count -eq 0) {
        $gp.Controls.Add((New-Label "이 CPU는 빠른 선택 값이 없어요. 아래 '직접 정하기'로 값을 정해 주세요." 12 116 596 22))
    } else {
        $hintTxt = '조용: 문서·영상  ·  기본: 기본 클럭까지'
        if ($cpu.Game -gt 0) { $hintTxt += ('  ·  게임: 부스트 조금만 (원래 {0:0.0}GHz)' -f ($cpu.Boost / 1000)) }
        $h3 = New-Label $hintTxt 12 148 596 18 $script:fS
        $h3.ForeColor = $script:cGray
        $gp.Controls.Add($h3)
    }

    $l4 = New-Label '직접 정하기' 12 178 84 22
    $script:tbClock = New-Object System.Windows.Forms.TrackBar
    $script:tbClock.AutoSize = $false
    $script:tbClock.Location = New-Object System.Drawing.Point(96, 172)
    $script:tbClock.Size = New-Object System.Drawing.Size(300, 30)
    $script:tbClock.TickStyle = 'None'
    $script:tbClock.Minimum = [int][math]::Ceiling($cpu.Min / 100.0)
    $script:tbClock.Maximum = [int][math]::Floor($cpu.Max / 100.0)
    $script:tbClock.SmallChange = 1
    $script:tbClock.LargeChange = 2
    $script:tbClock.BackColor = $cBack
    $script:txtClock = New-Object System.Windows.Forms.TextBox
    $script:txtClock.Location = New-Object System.Drawing.Point(402, 175)
    $script:txtClock.Size = New-Object System.Drawing.Size(64, 25)
    $script:txtClock.Font = $script:fN
    $script:txtClock.TextAlign = 'Right'
    $script:txtClock.MaxLength = 7
    $l5 = New-Label 'MHz' 470 178 38 22
    $script:btnApply = New-Button '적용' 512 172 96 30 $script:fB
    # 슬라이더를 움직이면 숫자 칸이 따라가고, 숫자를 적으면(쓸 수 있는 값일 때) 슬라이더가 따라간다
    $script:tbClock.Add_ValueChanged({
        if ($script:Syncing) { return }
        $script:Syncing = $true
        try { $script:txtClock.Text = "$($script:tbClock.Value * 100)" } catch { } finally { $script:Syncing = $false }
        try { Update-ApplyButton } catch { }
    })
    $script:txtClock.Add_TextChanged({
        if ($script:Syncing) { return }
        $script:Syncing = $true
        try {
            $n = ConvertTo-ClockValue $script:txtClock.Text
            if ($null -ne $n) {
                $t = [int][math]::Round($n / 100.0)
                $script:tbClock.Value = [math]::Max($script:tbClock.Minimum, [math]::Min($script:tbClock.Maximum, $t))
            }
        } catch { } finally { $script:Syncing = $false }
        try { Update-ApplyButton } catch { }
    })
    $script:txtClock.Add_KeyDown({
        if ($_.KeyCode -eq [System.Windows.Forms.Keys]::Enter) {
            $_.SuppressKeyPress = $true
            try { Invoke-CustomApply } catch { try { Set-Status ('실패: ' + $_.Exception.Message) ([System.Drawing.Color]::Red) } catch { } }
        }
    })
    $script:btnApply.Add_Click({
        try { Invoke-CustomApply } catch { try { Set-Status ('실패: ' + $_.Exception.Message) ([System.Drawing.Color]::Red) } catch { } }
    })
    $gp.Controls.AddRange(@($l4, $script:tbClock, $script:txtClock, $l5, $script:btnApply))
    $defClock = if ($cpu.Game -gt 0) { $cpu.Game } elseif ($cpu.Base -ge 2000) { $cpu.Base } else { 3000 }
    Set-ClockControls $defClock

    # 원래대로
    $br0 = New-Button '원래대로 되돌리기' 12 214 190 38 $script:fB
    $br0.Add_Click({ Invoke-ModeClick 'restore' })
    $d0 = New-Label "이 프로그램이 만든 전원 계획을 지우고, 쓰던 계획으로 돌아가요." 212 224 396 20 $script:fS
    $gp.Controls.AddRange(@($br0, $d0))
    $form.Controls.Add($gp)

    # ----- 아래: 바이오스·안내 -----
    $lb = New-Label 'W(와트) 전력 제한은 바이오스에서 걸어야 확실해요. 7640HS·H255 모두 35W를 권장해요.' 14 526 614 20 $script:fS
    $form.Controls.Add($lb)
    $bg = New-Button '바이오스 설정 방법' 10 548 134 30 $script:fS
    $bg.Add_Click({
        try { Show-TextWindow '바이오스 전력 제한 방법' $BiosGuide }
        catch { Set-Status ('안내 창을 열지 못했어요: ' + $_.Exception.Message) ([System.Drawing.Color]::Red) }
    })
    $br = New-Button '바이오스로 재부팅' 149 548 128 30 $script:fS
    $br.Add_Click({
        try {
            $ans = [System.Windows.Forms.MessageBox]::Show("지금 바로 재부팅해서 바이오스로 들어갑니다.`n저장 안 한 작업이 있으면 먼저 저장하세요.`n`n계속할까요?", $AppName, 'YesNo', 'Warning', 'Button2')
            if ($ans -ne 'Yes') { return }
            if ($DryRun) { [void][System.Windows.Forms.MessageBox]::Show('[시험 모드] shutdown /r /fw /t 0 을 실행할 차례예요.', $AppName); return }
            $failed = $false
            $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
            try { & $ShutdownExe /r /fw /t 0 2>&1 | Out-Null; if ($LASTEXITCODE -ne 0) { $failed = $true } }
            catch { $failed = $true }
            finally { $ErrorActionPreference = $old }
            if ($failed) {
                [void][System.Windows.Forms.MessageBox]::Show('바이오스로 바로 재부팅하지 못했어요. 컴퓨터를 다시 켤 때 Del 키를 연타하세요.', $AppName)
            }
        } catch { Set-Status ('재부팅하지 못했어요: ' + $_.Exception.Message) ([System.Drawing.Color]::Red) }
    })
    $bc = New-Button '고장 예방 체크리스트' 282 548 138 30 $script:fS
    $bc.Add_Click({
        try { Show-TextWindow '고장 예방 체크리스트' $Checklist }
        catch { Set-Status ('안내 창을 열지 못했어요: ' + $_.Exception.Message) ([System.Drawing.Color]::Red) }
    })
    $bs = New-Button '바탕화면 바로가기' 425 548 126 30 $script:fS
    $bs.Add_Click({
        if ($DryRun) { Set-Status '[시험 모드] 바로가기는 만들지 않았어요.'; return }
        try { New-DesktopShortcut; Set-Status "바탕화면에 '$AppName' 바로가기를 만들었어요." $script:cGreen }
        catch { Set-Status ('바로가기를 만들지 못했어요: ' + $_.Exception.Message) ([System.Drawing.Color]::Red) }
    })
    $script:btnHelp = New-Button '사용법' 556 548 74 30 $script:fS
    $script:btnHelp.Add_Click({
        try {
            $readme = Join-Path $AppDir '사용법.txt'
            if (Test-Path -LiteralPath $readme) { Start-Process -FilePath $NotepadExe -ArgumentList "`"$readme`"" } else { Set-Status '사용법.txt 파일이 같은 폴더에 없어요.' }
        } catch { Set-Status ('사용법을 열지 못했어요: ' + $_.Exception.Message) ([System.Drawing.Color]::Red) }
    })
    $form.Controls.AddRange(@($bg, $br, $bc, $bs, $script:btnHelp))
    $script:lblStatus = New-Label '' 12 584 618 22 $script:fS
    $script:lblStatus.AutoEllipsis = $true
    $form.Controls.Add($script:lblStatus)
    Set-Status "$AppVersion · $Disclaimer" $script:cGray
    # 창이 뜨자마자 Enter·Space 가 눌려도 설정이 바뀌지 않게, 처음 포커스는 '사용법' 버튼에 둔다
    $form.ActiveControl = $script:btnHelp

    # 화면이 작거나 배율이 커서 창이 화면보다 길면, 화면 높이에 맞추고 스크롤로 본다
    $form.Add_Load({
        try {
            $f = $script:form
            $wa = if ($script:FakeWorkArea) { $script:FakeWorkArea } else { [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea }
            if ($f.Height -gt $wa.Height) {
                $f.AutoScroll = $true
                $f.Height = $wa.Height
                $f.Width = $f.Width + [System.Windows.Forms.SystemInformation]::VerticalScrollBarWidth
                $f.Location = New-Object System.Drawing.Point(($wa.Left + [math]::Max(0, [int](($wa.Width - $f.Width) / 2))), $wa.Top)
            }
        } catch { }
    })

    Update-StateUI $true

    $script:timer = New-Object System.Windows.Forms.Timer
    $script:timer.Interval = 1000
    $script:timer.Add_Tick({ try { Update-Live } catch { } })

    # 스크롤이 생기는 작은 화면에서도 창이 맨 위부터 보이게 한다(처음 포커스가 아래쪽 버튼에 있어서 내려가 있을 수 있다)
    $form.Add_Shown({ try { if ($script:form.AutoScroll) { $script:form.AutoScrollPosition = New-Object System.Drawing.Point(0, 0) } } catch { } })

    if ($Snapshot) {
        $form.StartPosition = 'Manual'
        $form.Location = New-Object System.Drawing.Point(-3000, -3000)
        $form.ShowInTaskbar = $false
        $form.Add_Shown({
            if ($script:TestHook) { & $script:TestHook }   # 시험용: 버튼을 눌러 보는 자동 시험
            if ($script:Live) { Update-Live }               # 시험용: 미리 넣어 둔 값으로 화면을 그린다
            Save-WindowImage $Snapshot
            $script:form.Close()
        })
    } else {
        Start-LiveReader
        $form.Add_Shown({ $script:timer.Start() })
        # 다른 창에 갔다 돌아오면 상태를 다시 읽는다(제어판에서 전원 계획을 바꿨을 수 있으므로)
        $form.Add_Activated({
            try { if ([math]::Abs([Environment]::TickCount - $script:LastStateTick) -gt 2000) { Update-StateUI $false } } catch { }
        })
    }
    $form.Add_FormClosing({ try { $script:timer.Stop(); if ($script:Live) { $script:Live.Stop = $true } } catch { } })
    try {
        [void]$form.ShowDialog()
    } finally {
        $script:timer.Dispose()
        Stop-LiveReader
        $form.Dispose()
        foreach ($o in @($script:brTrack, $script:brFill, $script:brLocked, $script:brTick, $script:brLimitText, $script:penBorder, $script:penLimit)) {
            try { $o.Dispose() } catch { }
        }
    }
}

# ---------- 시작 ----------
try {
    $script:Cpu = Get-CpuInfo
    if ($RunAction) {
        "CPU: $($script:Cpu.Name)  ->  $($script:Cpu.Model)"
        switch ($RunAction) {
            'status' {
                $st = Get-CurrentState
                $st | Format-List | Out-String
                "모드: $((Get-StateMode $st).Kind)"
                $v = & $LiveReader $true
                "실제 CPU 클럭: $($v.MHz) MHz, 사용률 $($v.Util)%"
                if (@($v.Disks).Count) { @($v.Disks) | Format-Table -AutoSize | Out-String } else { 'SSD 온도: 읽을 수 없음(관리자 권한 필요)' }
            }
            'restore' { if (-not (Restore-Default)) { '되돌릴 설정이 없어요(이 프로그램 전원 계획 없음).' } }
            default {
                $cpu = $script:Cpu
                $mode = $null
                if ($RunAction -eq 'boostoff' -or $RunAction -eq 'recommend') { $mode = New-BoostOffMode }
                elseif ($RunAction -eq 'clock') {
                    if ($Clock -le 0) { throw '-RunAction clock 에는 -Clock <MHz> 를 같이 적어 주세요. 예: -RunAction clock -Clock 4200' }
                    $mode = New-ClockMode $Clock
                }
                else {
                    # quiet / base / game: 이 CPU에 빠른 선택 값이 있을 때만
                    $mhz = 0
                    if ($RunAction -eq 'quiet') { $mhz = $cpu.Quiet }
                    elseif ($RunAction -eq 'base') { if ($cpu.Quiet -gt 0) { $mhz = $cpu.Base } }
                    elseif ($RunAction -eq 'game') { $mhz = $cpu.Game }
                    if ($mhz -le 0) { throw "이 CPU에는 '$RunAction' 값이 정해져 있지 않아요. -RunAction clock -Clock <MHz> 로 직접 정해 주세요." }
                    $mode = New-ClockMode $mhz
                }
                Set-Mode $mode
                if ($DryRun) { "적용할 설정: $($mode.Title) (시험 모드라 실제로는 바꾸지 않았어요)" } else { "적용: $($mode.Title)" }
            }
        }
        if ($DryRun -and $RunAction -ne 'status' -and $script:Log.Count -gt 0) { '[DryRun] 실제로 바꾸지 않고, 실행할 명령만 보여줍니다:' }
        $script:Log
        return
    }
    Show-MainWindow
} catch {
    if ($RunAction) { throw }
    Add-Type -AssemblyName System.Windows.Forms
    [void][System.Windows.Forms.MessageBox]::Show("오류가 났어요:`n$($_.Exception.Message)", $AppName, 'OK', 'Error')
}
