<#
  미니PC 발열 관리 v1.0.1 - Firebat F1 (Ryzen 5 7640HS / Ryzen 7 H 255)
  MIT License (LICENSE.txt). Firebat 공식 프로그램이 아니며, 사용에 따른 책임은 사용자에게 있다.

  미니PC 발열을 줄이는 윈도우 전원 설정을 버튼 하나로 적용한다.
  - 윈도우 전원 계획만 바꾼다(드라이버·외부 프로그램 없음). '원래대로'로 언제든 되돌린다.
  - 전력 제한(W)은 바이오스에서 거는 게 확실해서 방법 안내와 '바이오스로 재부팅' 버튼만 둔다.

  사용: 같은 폴더의 '발열관리 실행.bat' 더블클릭
  시험: powershell -ExecutionPolicy Bypass -File MiniPC-Cool.ps1 -DryRun -RunAction recommend
        (실제로 바꾸지 않고 실행할 명령만 출력)
  명령줄: -RunAction recommend | quiet | game | restore | status
#>
param(
    [switch]$DryRun,
    [ValidateSet('', 'recommend', 'quiet', 'game', 'restore', 'status')]
    [string]$RunAction = '',
    [string]$Snapshot = '',
    [string]$FakeCpu = ''   # 시험용: 다른 PC에서 F1 화면을 미리 볼 때 CPU 이름을 대신 넣는다
)

$ErrorActionPreference = 'Stop'
$ScriptPath = $MyInvocation.MyCommand.Path
$AppDir = Split-Path -Parent $ScriptPath
$AppName = '미니PC 발열관리'   # 전원 계획·바로가기 이름에도 쓰므로 버전은 넣지 않는다
$AppVersion = 'v1.0.1'
$Disclaimer = 'Firebat 공식 프로그램이 아니에요. 있는 그대로 제공되며, 사용에 따른 책임은 사용자에게 있어요.'

function Test-Admin {
    $id = [Security.Principal.WindowsIdentity]::GetCurrent()
    return ([Security.Principal.WindowsPrincipal]$id).IsInRole([Security.Principal.WindowsBuiltInRole]::Administrator)
}

# ---------- 관리자 권한으로 다시 실행 ----------
if (-not (Test-Admin) -and -not $DryRun -and -not $Snapshot -and $RunAction -ne 'status') {
    $argList = @('-NoProfile', '-ExecutionPolicy', 'Bypass', '-WindowStyle', 'Hidden', '-File', "`"$ScriptPath`"")
    if ($RunAction) { $argList += @('-RunAction', $RunAction) }
    try {
        Start-Process -FilePath 'powershell.exe' -Verb RunAs -ArgumentList $argList | Out-Null
    } catch {
        Add-Type -AssemblyName System.Windows.Forms
        [void][System.Windows.Forms.MessageBox]::Show('관리자 권한을 허용해야 전원 설정을 바꿀 수 있어요.', $AppName)
    }
    exit
}

# ---------- 상수 ----------
$GUID_BALANCED = '381b4222-f694-41f0-9685-ff5bb260df2e'   # 윈도우 기본 '균형 조정'
$GUID_MINE     = 'f1c0011e-7640-4255-a1c3-0d1ce0c0ffee'   # 이 프로그램이 만드는 전원 계획
$SUB_PROCESSOR = '54533251-82be-4824-96c1-47b60b740d00'   # 프로세서 전원 관리
$S_BOOST       = 'be337238-0d82-4146-a960-4f3749d470c7'   # 프로세서 성능 강화 모드(숨김 항목)
$S_MAXSTATE    = 'bc5038f7-23e0-4960-96da-33abaf5935ec'   # 최대 프로세서 상태(%)
$S_MAXFREQ     = '75b0ae3f-bce0-45a7-8c89-c9611c25e100'   # 최대 프로세서 주파수(MHz, 숨김 항목)
$StateDir  = Join-Path $env:ProgramData 'MiniPCCool'
$StateFile = Join-Path $StateDir 'previous-scheme.txt'
$GuidRx = '[0-9a-fA-F]{8}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{4}-[0-9a-fA-F]{12}'

$BoostNames = @{
    0 = '사용 안 함'; 1 = '사용'; 2 = '적극적(윈도우 기본)'; 3 = '효율적으로 활성화됨'
    4 = '적극적으로 효율화됨'; 5 = '보장될 때 적극적'; 6 = '보장될 때 적극적으로 효율화됨'
}
$script:Log = New-Object System.Collections.Generic.List[string]

# ---------- powercfg ----------
function Invoke-PowerCfg {
    param([string[]]$A, [switch]$Change)
    if ($Change) { $script:Log.Add('powercfg ' + ($A -join ' ')) }
    if ($Change -and $DryRun) { return @() }
    $old = $ErrorActionPreference
    $ErrorActionPreference = 'Continue'
    try { $out = & powercfg.exe @A 2>&1 } finally { $ErrorActionPreference = $old }
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
        MaxFreq = $(if ($f) { [int]$f.AC } else { 0 })
    }
}

# ---------- CPU·프로필 ----------
function Get-CpuInfo {
    $p = Get-CimInstance Win32_Processor | Select-Object -First 1
    $name = ($p.Name -replace '\s+', ' ').Trim()
    if ($FakeCpu) { $name = $FakeCpu }
    $info = [ordered]@{ Name = $name; Model = 'other'; Label = $name; Base = [int]$p.MaxClockSpeed; Boost = 0; GameCap = 0 }
    if ($name -match '7640HS') {
        $info.Model = '7640HS'; $info.Label = 'Ryzen 5 7640HS (6코어)'
        $info.Base = 4300; $info.Boost = 5000; $info.GameCap = 4600
    } elseif ($name -match 'H ?255') {
        $info.Model = 'H255'; $info.Label = 'Ryzen 7 H 255 (8코어)'
        $info.Base = 3800; $info.Boost = 4900; $info.GameCap = 4400
    }
    return [pscustomobject]$info
}

function Get-Profiles($cpu) {
    $baseG = '{0:0.0}' -f ($cpu.Base / 1000)
    # 설명 글은 단어 중간에서 줄이 바뀌지 않게 줄바꿈 위치를 직접 정한다
    $gameDesc = if ($cpu.GameCap -gt 0) {
        "부스트는 켜되 최대 {0:0.0}GHz로 묶어요(원래 {1:0.0}GHz).`r`n게임·무거운 작업용." -f ($cpu.GameCap / 1000), ($cpu.Boost / 1000)
    } else { "부스트를 효율 모드로만 켜요.`r`n게임·무거운 작업용." }
    return [ordered]@{
        recommend = [pscustomobject]@{ Key = 'recommend'; Title = '추천 · 발열 관리'; Boost = 0; MaxState = 99; MaxFreq = 0
            Desc = "부스트 끔 + 최대 99% → 기본 클럭(${baseG}GHz)까지만 씁니다.`r`n처음이면 이것부터." }
        quiet = [pscustomobject]@{ Key = 'quiet'; Title = '조용 · 저발열'; Boost = 0; MaxState = 80; MaxFreq = 0
            Desc = "부스트 끔 + 최대 80% → 기본 클럭보다 더 낮춰요.`r`n문서·유튜브용, 가장 시원하고 조용함." }
        game = [pscustomobject]@{ Key = 'game'; Title = '게임 · 성능'; Boost = 3; MaxState = 100; MaxFreq = $cpu.GameCap
            Desc = $gameDesc }
    }
}

function Find-ProfileMatch($st) {
    if (-not $st.IsMine) { return $null }
    foreach ($p in $script:Profiles.Values) {
        if ($st.Boost -eq $p.Boost -and $st.MaxState -eq $p.MaxState -and $st.MaxFreq -eq $p.MaxFreq) { return $p }
    }
    return $null
}

# ---------- 적용·되돌리기 ----------
function Set-Profile($p) {
    $script:Log.Clear()
    $active = Get-ActiveSchemeGuid
    if ($active -ne $GUID_MINE) {
        # 되돌릴 때 쓰려고 지금 쓰던 전원 계획을 기억해 둔다
        if ($DryRun) { $script:Log.Add("(이전 전원 계획 기억: $active)") }
        else {
            New-Item -ItemType Directory -Force -Path $StateDir | Out-Null
            Set-Content -Path $StateFile -Value $active -Encoding ASCII
        }
    }
    if (-not (Test-Scheme $GUID_MINE)) {
        # 지금 쓰는 계획을 복사한다(절전·화면 꺼짐 시간 같은 사용자의 다른 설정이 그대로 따라오게)
        $base = $active
        Invoke-PowerCfg -Change @('-duplicatescheme', $base, $GUID_MINE) | Out-Null
        Invoke-PowerCfg -Change @('-changename', $GUID_MINE, $AppName, 'Firebat F1 발열 관리 프로그램이 만든 전원 계획') | Out-Null
    }
    # 숨김 항목을 제어판에서도 보이게(부스트 모드, 최대 주파수). 실패해도 적용에는 상관없다.
    foreach ($s in @($S_BOOST, $S_MAXFREQ)) {
        try { Invoke-PowerCfg -Change @('-attributes', $SUB_PROCESSOR, $s, '-ATTRIB_HIDE') | Out-Null }
        catch { $script:Log.Add('(제어판 표시 설정은 건너뜀 - 적용에는 상관없음)') }
    }
    $vals = [ordered]@{ $S_BOOST = $p.Boost; $S_MAXSTATE = $p.MaxState; $S_MAXFREQ = $p.MaxFreq }
    foreach ($kv in $vals.GetEnumerator()) {
        foreach ($cmd in @('/setacvalueindex', '/setdcvalueindex')) {
            try {
                Invoke-PowerCfg -Change @($cmd, $GUID_MINE, $SUB_PROCESSOR, $kv.Key, [string]$kv.Value) | Out-Null
            } catch {
                # 최대 주파수 항목이 없는 PC: 제한을 안 거는 설정이면 넘어가고, 거는 설정이면 알린다
                if ($kv.Key -eq $S_MAXFREQ -and $kv.Value -eq 0) { continue }
                if ($kv.Key -eq $S_MAXFREQ) { throw '이 PC는 최대 주파수 제한을 지원하지 않아서 게임 모드를 쓸 수 없어요.' }
                throw
            }
        }
    }
    Invoke-PowerCfg -Change @('/setactive', $GUID_MINE) | Out-Null
    if (-not $DryRun) {
        $st = Get-CurrentState
        if (-not $st.IsMine -or $st.Boost -ne $p.Boost -or $st.MaxState -ne $p.MaxState -or $st.MaxFreq -ne $p.MaxFreq) {
            throw ("적용 후 다시 읽어 보니 값이 달라요 (부스트 {0}, 최대 {1}%, 주파수 {2})" -f $st.Boost, $st.MaxState, $st.MaxFreq)
        }
    }
}

# 되돌리면 $true, 이 프로그램이 만든 전원 계획이 없으면 $false
function Restore-Default {
    $script:Log.Clear()
    $schemes = Get-SchemeList
    if (-not ($schemes | Where-Object { $_.Guid -eq $GUID_MINE })) { return $false }
    # 이 프로그램 계획을 쓰는 중일 때만 다른 계획으로 바꾼다(사용자가 이미 다른 계획으로 바꿨으면 그대로 둔다)
    if ((Get-ActiveSchemeGuid) -eq $GUID_MINE) {
        $prev = $null
        if (Test-Path $StateFile) {
            $raw = Get-Content -Path $StateFile -Raw
            if ($raw) { $prev = $raw.Trim().ToLower() }
        }
        if (-not $prev -or $prev -eq $GUID_MINE -or -not ($schemes | Where-Object { $_.Guid -eq $prev })) {
            $prev = if ($schemes | Where-Object { $_.Guid -eq $GUID_BALANCED }) { $GUID_BALANCED }
                    else { ($schemes | Where-Object { $_.Guid -ne $GUID_MINE } | Select-Object -First 1).Guid }
        }
        Invoke-PowerCfg -Change @('/setactive', $prev) | Out-Null
    }
    Invoke-PowerCfg -Change @('-delete', $GUID_MINE) | Out-Null
    if (-not $DryRun -and (Test-Path $StateFile)) { Remove-Item -Path $StateFile -Force }
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
    $script:Live = [hashtable]::Synchronized(@{ Stop = $false; MHz = $null; Util = $null; Disks = $null; Zones = $null })
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
4) AMD CBS → CPU Common Options → Core Performance Boost → Disabled
   (부스트를 끕니다. 이 프로그램의 '추천'과 같은 효과라 둘 중 하나만 해도 됩니다.)
5) AMD CBS → SMU Common Options → System Configuration → 35W
   (35W는 이 CPU들의 AMD 사양 최저값입니다.)
6) F10(Save & Exit)으로 저장하고 재부팅합니다.

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
- '추천' 버튼: 부스트 끔 + 최대 99%. 쉬는 중 전력과 온도가 크게 줄어듭니다.
- 바이오스에서 35W 전력 제한을 같이 하면 효과가 가장 큽니다.
  ('바이오스 설정 방법 보기' 참고)

[하드웨어로 할 수 있는 것]
- 상단에 팬을 다는 교체 케이스나 써멀 교체로 온도를 더 낮출 수 있습니다.
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

function New-Button([string]$text, [int]$x, [int]$y, [int]$w, [int]$h) {
    $b = New-Object System.Windows.Forms.Button
    $b.Text = $text
    $b.UseMnemonic = $false
    $b.Location = New-Object System.Drawing.Point($x, $y)
    $b.Size = New-Object System.Drawing.Size($w, $h)
    $b.Font = $script:fN
    return $b
}

function Set-Status([string]$text, $color = $null) {
    $script:lblStatus.Text = $text
    $script:lblStatus.ForeColor = $(if ($color) { $color } else { [System.Drawing.SystemColors]::ControlText })
}

function Update-StateUI {
    try {
        $st = Get-CurrentState
        $script:lblPlan.Text = "전원 계획: $($st.Name)"
        $freqTxt = if ($st.MaxFreq -gt 0) { "$($st.MaxFreq) MHz" } else { '제한 없음' }
        $boostTxt = if ($BoostNames.ContainsKey($st.Boost)) { $BoostNames[$st.Boost] } else { '알 수 없음' }
        $stateTxt = if ($st.MaxState -ge 0) { "$($st.MaxState)%" } else { '알 수 없음' }
        $detail = "부스트 $boostTxt · 최대 $stateTxt · 주파수 $freqTxt"
        $match = Find-ProfileMatch $st
        if ($match) {
            $script:lblMode.Text = "적용 중: $($match.Title)`r`n$detail"
            $script:lblMode.ForeColor = [System.Drawing.Color]::FromArgb(0, 120, 60)
        } elseif ($st.IsMine) {
            $script:lblMode.Text = "적용 중: 이 프로그램 전원 계획(값을 직접 바꾼 상태)`r`n$detail"
            $script:lblMode.ForeColor = [System.Drawing.SystemColors]::ControlText
        } else {
            $script:lblMode.Text = "적용 중: 이 프로그램 설정 아님(윈도우 설정 그대로)`r`n$detail"
            $script:lblMode.ForeColor = [System.Drawing.SystemColors]::ControlText
        }
        foreach ($k in $script:Buttons.Keys) {
            $b = $script:Buttons[$k]
            $isOn = ($match -and $match.Key -eq $k)
            $b.Text = $(if ($isOn) { '● ' + $b.Tag.Title } else { $b.Tag.Title })
            if ($isOn) { $b.UseVisualStyleBackColor = $false; $b.BackColor = [System.Drawing.Color]::FromArgb(205, 240, 212) }
            else { $b.BackColor = [System.Drawing.SystemColors]::Control; $b.UseVisualStyleBackColor = $true }
        }
    } catch {
        $script:lblMode.Text = "상태를 읽지 못했어요: $($_.Exception.Message)"
    }
}

# 백그라운드가 읽어 둔 값을 화면에 옮긴다(1초마다, 금방 끝남)
function Update-Live {
    $L = $script:Live
    if (-not $L) { return }
    if ($null -eq $L.MHz) { $script:lblClock.Text = '실제 CPU 클럭: 읽는 중…' }
    elseif ($L.MHz -le 0) { $script:lblClock.Text = '실제 CPU 클럭: 읽을 수 없음' }
    else { $script:lblClock.Text = ('실제 CPU 클럭: {0:N0} MHz   (사용률 {1}%)' -f $L.MHz, $L.Util) }

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
        $parts = @($d) | ForEach-Object { '디스크{0} {1}℃ (최고 {2}℃)' -f $_.No, $_.Temp, $script:DiskMax["$($_.No)|$($_.Name)"] }
        $txt = 'SSD 온도: ' + ($parts -join '  /  ')
        if (@($d).Count -eq 1) { $txt += '   · 60℃ 주의 · 70℃ 높음' }
        $script:lblSsd.Text = $txt
        $names = (@($d) | ForEach-Object { '디스크{0}: {1}' -f $_.No, $_.Name }) -join "`r`n"
        if ($script:tip.GetToolTip($script:lblSsd) -ne $names) { $script:tip.SetToolTip($script:lblSsd, $names) }
        $max = (@($d) | Measure-Object -Property Temp -Maximum).Maximum
        $script:lblSsd.ForeColor = $(if ($max -ge 70) { [System.Drawing.Color]::Red } elseif ($max -ge 60) { [System.Drawing.Color]::DarkOrange } else { [System.Drawing.SystemColors]::ControlText })
    }

    $z = $L.Zones
    if ($null -eq $z) { $script:lblZone.Text = '' }
    elseif (@($z).Count -gt 0) { $script:lblZone.Text = '메인보드 온도(ACPI, 참고용): ' + ((@($z) | ForEach-Object { "$_℃" }) -join ' / ') }
    else { $script:lblZone.Text = 'CPU 온도: 윈도우로는 읽을 수 없어요 - 정확한 값은 HWiNFO로 확인' }
}

function Invoke-ProfileClick([string]$key) {
    $script:form.UseWaitCursor = $true
    try {
        if ($key -eq 'restore') {
            $ok = Restore-Default
            if (-not $ok) { Set-Status '이 프로그램으로 바꾼 설정이 없어서 되돌릴 게 없어요.' }
            else { Set-Status '원래 전원 계획으로 되돌리고, 이 프로그램이 만든 전원 계획을 지웠어요.' ([System.Drawing.Color]::FromArgb(0, 90, 160)) }
        } else {
            $p = $script:Profiles[$key]
            Set-Profile $p
            Set-Status ("적용했어요: {0}. 실제 클럭은 몇 초 안에 바뀝니다." -f $p.Title) ([System.Drawing.Color]::FromArgb(0, 120, 60))
        }
        if ($DryRun -and $script:Log.Count -gt 0) {
            [void][System.Windows.Forms.MessageBox]::Show(("[시험 모드] 실제로는 바꾸지 않았어요. 실행할 명령:`n`n" + ($script:Log -join "`n")), $AppName)
        }
    } catch {
        Set-Status ('실패: ' + $_.Exception.Message) ([System.Drawing.Color]::Red)
    } finally {
        $script:form.UseWaitCursor = $false
    }
    Update-StateUI
}

function New-DesktopShortcut {
    $desk = [Environment]::GetFolderPath('Desktop')
    $ws = New-Object -ComObject WScript.Shell
    $lnk = $ws.CreateShortcut((Join-Path $desk "$AppName.lnk"))
    $lnk.TargetPath = Join-Path $env:SystemRoot 'System32\WindowsPowerShell\v1.0\powershell.exe'
    $lnk.Arguments = "-NoProfile -ExecutionPolicy Bypass -WindowStyle Hidden -File `"$ScriptPath`""
    $lnk.WorkingDirectory = $AppDir
    $lnk.WindowStyle = 7
    $icon = Join-Path $env:SystemRoot 'System32\powercpl.dll'
    if (Test-Path $icon) { $lnk.IconLocation = "$icon,0" }
    $lnk.Description = 'Firebat F1 발열 관리'
    $lnk.Save()
    [void][System.Runtime.InteropServices.Marshal]::ReleaseComObject($ws)
}

function Show-MainWindow {
    Add-Type -AssemblyName System.Windows.Forms, System.Drawing
    [System.Windows.Forms.Application]::EnableVisualStyles()
    $script:fN = New-Object System.Drawing.Font('Malgun Gothic', 10)
    $script:fB = New-Object System.Drawing.Font('Malgun Gothic', 10, [System.Drawing.FontStyle]::Bold)
    $script:fH = New-Object System.Drawing.Font('Malgun Gothic', 16, [System.Drawing.FontStyle]::Bold)
    $script:fS = New-Object System.Drawing.Font('Malgun Gothic', 9)

    $form = New-Object System.Windows.Forms.Form
    $script:form = $form
    $form.Text = "$AppName $AppVersion" + $(if ($DryRun) { '  [시험 모드 - 실제로 바꾸지 않음]' } else { '' })
    $form.ClientSize = New-Object System.Drawing.Size(640, 776)
    $form.FormBorderStyle = 'FixedSingle'
    $form.MaximizeBox = $false
    $form.StartPosition = 'CenterScreen'
    $form.BackColor = [System.Drawing.Color]::FromArgb(250, 250, 250)

    $form.Controls.Add((New-Label '미니PC 발열 관리' 12 10 616 34 $script:fH))
    $cpu = $script:Cpu
    $cpuTxt = "감지된 CPU: $($cpu.Label)"
    if ($cpu.Boost -gt 0) { $cpuTxt += ('   ·   기본 {0:0.0}GHz / 부스트 {1:0.0}GHz' -f ($cpu.Base / 1000), ($cpu.Boost / 1000)) }
    $form.Controls.Add((New-Label $cpuTxt 14 48 616 22 $script:fB))
    if ($cpu.Model -eq 'other') {
        $w = New-Label "Firebat F1(7640HS·H255)용으로 만든 프로그램이에요.`r`n이 CPU에서도 윈도우 전원 설정은 바뀌지만 값은 확인하지 않았어요." 14 72 616 36 $script:fS
        $w.ForeColor = [System.Drawing.Color]::DarkOrange
    } else {
        $w = New-Label '지원 모델이에요. 버튼을 누르면 바로 적용되고, 언제든 "원래대로"로 되돌릴 수 있어요.' 14 72 616 36 $script:fS
        $w.ForeColor = [System.Drawing.Color]::FromArgb(0, 120, 60)
    }
    $form.Controls.Add($w)

    # 지금 상태
    $gb = New-Object System.Windows.Forms.GroupBox
    $gb.Text = '지금 상태'; $gb.Font = $script:fB
    $gb.Location = New-Object System.Drawing.Point(10, 110); $gb.Size = New-Object System.Drawing.Size(620, 172)
    $script:lblPlan = New-Label '' 12 24 596 22
    $script:lblMode = New-Label '' 12 48 596 44
    $script:lblClock = New-Label '실제 CPU 클럭: 읽는 중…' 12 94 596 22
    $script:lblSsd = New-Label 'SSD 온도: 읽는 중…' 12 118 596 22
    $script:lblZone = New-Label '' 12 142 596 22
    $script:tip = New-Object System.Windows.Forms.ToolTip
    $script:DiskMax = @{}
    $gb.Controls.AddRange(@($script:lblPlan, $script:lblMode, $script:lblClock, $script:lblSsd, $script:lblZone))
    $form.Controls.Add($gb)

    # 원클릭 설정
    $gp = New-Object System.Windows.Forms.GroupBox
    $gp.Text = '원클릭 설정 (누르면 바로 적용)'; $gp.Font = $script:fB
    $gp.Location = New-Object System.Drawing.Point(10, 290); $gp.Size = New-Object System.Drawing.Size(620, 282)
    $rows = @()
    foreach ($p in $script:Profiles.Values) { $rows += $p }
    $rows += [pscustomobject]@{ Key = 'restore'; Title = '원래대로 되돌리기'
        Desc = "이 프로그램이 만든 전원 계획을 지우고,`r`n쓰던 전원 계획(보통 '균형 조정')으로 돌아가요." }
    $script:Buttons = [ordered]@{}
    $y = 24
    foreach ($r in $rows) {
        $b = New-Button $r.Title 12 $y 190 54
        $b.Font = $script:fB
        $b.Tag = $r
        $b.Add_Click({ Invoke-ProfileClick $this.Tag.Key })
        if ($r.Key -ne 'restore') { $script:Buttons[$r.Key] = $b }
        $d = New-Label $r.Desc 212 ($y + 4) 396 50
        $gp.Controls.AddRange(@($b, $d))
        $y += 62
    }
    $form.Controls.Add($gp)

    # 바이오스
    $gbi = New-Object System.Windows.Forms.GroupBox
    $gbi.Text = '전력 제한(W)은 바이오스에서'; $gbi.Font = $script:fB
    $gbi.Location = New-Object System.Drawing.Point(10, 580); $gbi.Size = New-Object System.Drawing.Size(620, 112)
    $gbi.Controls.Add((New-Label "W(와트) 제한은 바이오스에서 걸어야 확실히 먹어요. 7640HS·H255 모두 35W를 권장해요.`r`nAMD 사양의 최저값이고, 한 번 해 두면 계속 유지돼요." 12 22 596 44))
    $bg = New-Button '바이오스 설정 방법 보기' 12 70 220 32
    $bg.Add_Click({ Show-TextWindow '바이오스 전력 제한 방법' $BiosGuide })
    $br = New-Button '바이오스로 재부팅' 242 70 180 32
    $br.Add_Click({
        $ans = [System.Windows.Forms.MessageBox]::Show("지금 바로 재부팅해서 바이오스로 들어갑니다.`n저장 안 한 작업이 있으면 먼저 저장하세요.`n`n계속할까요?", $AppName, 'YesNo', 'Warning')
        if ($ans -ne 'Yes') { return }
        if ($DryRun) { [void][System.Windows.Forms.MessageBox]::Show('[시험 모드] shutdown /r /fw /t 0 을 실행할 차례예요.', $AppName); return }
        $old = $ErrorActionPreference; $ErrorActionPreference = 'Continue'
        try { & shutdown.exe /r /fw /t 0 2>&1 | Out-Null } finally { $ErrorActionPreference = $old }
        if ($LASTEXITCODE -ne 0) {
            [void][System.Windows.Forms.MessageBox]::Show('바이오스로 바로 재부팅하지 못했어요. 컴퓨터를 다시 켤 때 Del 키를 연타하세요.', $AppName)
        }
    })
    $gbi.Controls.AddRange(@($bg, $br))
    $form.Controls.Add($gbi)

    # 아래 버튼
    $bc = New-Button '고장 예방 체크리스트' 10 702 200 34
    $bc.Add_Click({ Show-TextWindow '고장 예방 체크리스트' $Checklist })
    $bs = New-Button '바탕화면 바로가기 만들기' 220 702 200 34
    $bs.Add_Click({
        try { New-DesktopShortcut; Set-Status "바탕화면에 '$AppName' 바로가기를 만들었어요." ([System.Drawing.Color]::FromArgb(0, 120, 60)) }
        catch { Set-Status ('바로가기를 만들지 못했어요: ' + $_.Exception.Message) ([System.Drawing.Color]::Red) }
    })
    $bd = New-Button '사용법 보기' 430 702 200 34
    $bd.Add_Click({
        $readme = Join-Path $AppDir '사용법.txt'
        if (Test-Path -LiteralPath $readme) { Start-Process notepad.exe -ArgumentList "`"$readme`"" } else { Set-Status '사용법.txt 파일이 같은 폴더에 없어요.' }
    })
    $form.Controls.AddRange(@($bc, $bs, $bd))
    $script:lblStatus = New-Label '' 12 744 616 26 $script:fS
    $form.Controls.Add($script:lblStatus)
    Set-Status "$AppVersion · $Disclaimer" ([System.Drawing.Color]::Gray)

    # 화면이 작거나 배율이 커서 창이 화면보다 길면, 화면 높이에 맞추고 스크롤로 본다
    $form.Add_Load({
        $wa = if ($script:FakeWorkArea) { $script:FakeWorkArea } else { [System.Windows.Forms.Screen]::PrimaryScreen.WorkingArea }
        if ($form.Height -gt $wa.Height) {
            $form.AutoScroll = $true
            $form.Height = $wa.Height
            $form.Width = $form.Width + [System.Windows.Forms.SystemInformation]::VerticalScrollBarWidth
            $form.Location = New-Object System.Drawing.Point(($wa.Left + [math]::Max(0, [int](($wa.Width - $form.Width) / 2))), $wa.Top)
        }
    })

    Update-StateUI

    $timer = New-Object System.Windows.Forms.Timer
    $timer.Interval = 1000
    $timer.Add_Tick({ Update-Live })

    if ($Snapshot) {
        $form.StartPosition = 'Manual'
        $form.Location = New-Object System.Drawing.Point(-3000, -3000)
        $form.ShowInTaskbar = $false
        $form.Add_Shown({
            if ($script:Live) { Update-Live }   # 시험용: 미리 넣어 둔 값으로 화면을 그린다
            $form.Refresh()
            $bmp = New-Object System.Drawing.Bitmap($form.Width, $form.Height)
            $form.DrawToBitmap($bmp, (New-Object System.Drawing.Rectangle(0, 0, $form.Width, $form.Height)))
            $bmp.Save($Snapshot, [System.Drawing.Imaging.ImageFormat]::Png)
            $bmp.Dispose()
            $form.Close()
        })
    } else {
        Start-LiveReader
        $form.Add_Shown({ $timer.Start() })
    }
    $form.Add_FormClosing({ $timer.Stop(); if ($script:Live) { $script:Live.Stop = $true } })
    try {
        [void]$form.ShowDialog()
    } finally {
        $timer.Dispose()
        Stop-LiveReader
        $form.Dispose()
    }
}

# ---------- 시작 ----------
try {
    $script:Cpu = Get-CpuInfo
    $script:Profiles = Get-Profiles $script:Cpu
    if ($RunAction) {
        "CPU: $($script:Cpu.Name)  ->  $($script:Cpu.Model)"
        switch ($RunAction) {
            'status' {
                Get-CurrentState | Format-List | Out-String
                $v = & $LiveReader $true
                "실제 CPU 클럭: $($v.MHz) MHz, 사용률 $($v.Util)%"
                if (@($v.Disks).Count) { @($v.Disks) | Format-Table -AutoSize | Out-String } else { 'SSD 온도: 읽을 수 없음(관리자 권한 필요)' }
            }
            'restore' { if (-not (Restore-Default)) { '되돌릴 설정이 없어요(이 프로그램 전원 계획 없음).' } }
            default { Set-Profile $script:Profiles[$RunAction] }
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
