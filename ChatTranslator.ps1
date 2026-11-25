﻿# WoW Chat Translator for Emberveil
# Watches Logs\WoWChatLog.txt (turn logging on in game with /chatlog) and shows
# every new Chinese chat line translated (English or Hungarian) in a small
# always-on-top window. Replies typed in the window are translated to Chinese
# and put on the clipboard. With "Chinese" chosen it works the other way:
# English lines are shown in Chinese and replies are translated to English. Text is sent to Google Translate's public web
# endpoint, so it needs internet; nothing is sent anywhere else.

Add-Type -AssemblyName System.Windows.Forms
Add-Type -AssemblyName System.Drawing
[Net.ServicePointManager]::SecurityProtocol = [Net.SecurityProtocolType]::Tls12

# ---------------------------------------------------------------- settings
$ConfigPath = Join-Path $env:APPDATA "WowChatTranslator.json"
$DefaultLog = Join-Path $env:LOCALAPPDATA "Programs\Azeroth Launcher\Azeroth\Binaries\Win64\Games\Emberveil\live\Azeroth\Logs\WoWChatLog.txt"

$Config = [pscustomobject]@{ LogPath = $DefaultLog; Lang = "en"; UiLang = "en"; OnlyChinese = $true; ShowOriginal = $true; X = -1; Y = -1; W = 600; H = 300 }
if (Test-Path $ConfigPath) {
    try {
        $saved = Get-Content $ConfigPath -Raw -Encoding UTF8 | ConvertFrom-Json
        foreach ($p in $saved.PSObject.Properties) { $Config | Add-Member -NotePropertyName $p.Name -NotePropertyValue $p.Value -Force }
    } catch { }
}
function Save-Config { try { $Config | ConvertTo-Json | Set-Content -Path $ConfigPath -Encoding UTF8 } catch { } }

# ---------------------------------------------------------------- texts (English first, Hungarian as a bonus)
$Texts = @{
    en = @{
        Title = "WoW Chat Translator"; To = "Translate to:"; OnlyCjk = "Only Chinese lines"; Orig = "Show original"
        Clear = "Clear"; Log = "Log file..."; Send = "To Chinese + copy"; Ui = "Magyar"
        Channels = @("Guild /g", "Say /s", "Party /p", "Raid /ra", "World /1", "Whisper /w", "(none)")
        Langs = @("English", "Hungarian", "Chinese")
        OnlyEn = "Only non-Chinese lines"; SendEn = "To English + copy"
        Watching = "Watching: "; NoLog = "No log file. In the game type /chatlog (or use the Log file... button)"
        Last = "Last translation: "; Error = "Error: "; Failed = "   [translation failed]"
        Copied = "On the clipboard! In the game: Enter, Ctrl+V, Enter"; WhoWhisper = "Type the name to whisper to"
        You = "You: "; Pick = "Choose WoWChatLog.txt"; TrError = "Translation error: "
    }
    hu = @{
        Title = "WoW Chat Fordító"; To = "Fordítás:"; OnlyCjk = "Csak kínai sorok"; Orig = "Eredeti is"
        Clear = "Törlés"; Log = "Naplófájl..."; Send = "Kínaira + másol"; Ui = "English"
        Channels = @("Guild /g", "Say /s", "Party /p", "Raid /ra", "Világ /1", "Suttog /w", "(nincs)")
        Langs = @("Angol", "Magyar", "Kínai")
        OnlyEn = "Csak nem kínai sorok"; SendEn = "Angolra + másol"
        Watching = "Figyelt fájl: "; NoLog = "Nincs naplófájl. A játékban: /chatlog (vagy: Naplófájl... gomb)"
        Last = "Utolsó fordítás: "; Error = "Hiba: "; Failed = "   [fordítás sikertelen]"
        Copied = "Vágólapon! A játékban: Enter, Ctrl+V, Enter"; WhoWhisper = "Írd be, kinek suttogsz"
        You = "Te: "; Pick = "WoWChatLog.txt kiválasztása"; TrError = "Fordítási hiba: "
    }
}
function T([string]$key) {
    $t = $Texts[[string]$Config.UiLang]
    if (-not $t) { $t = $Texts.en }
    return $t[$key]
}

# Chinese / Japanese / Korean characters
$CjkPattern = '[\u3040-\u30FF\u3400-\u4DBF\u4E00-\u9FFF\uAC00-\uD7AF\uF900-\uFAFF]'

# ---------------------------------------------------------------- translate
function Invoke-Translate([string]$text, [string]$target) {
    $url = "https://translate.googleapis.com/translate_a/single?client=gtx&sl=auto&tl=$target&dt=t&q=" + [Uri]::EscapeDataString($text)
    $req = [Net.HttpWebRequest]::Create($url)
    $req.Timeout = 5000
    $req.UserAgent = "Mozilla/5.0"
    $resp = $req.GetResponse()
    try {
        $reader = New-Object IO.StreamReader($resp.GetResponseStream(), [Text.Encoding]::UTF8)
        $json = $reader.ReadToEnd()
    } finally { $resp.Close() }
    $data = $json | ConvertFrom-Json
    $parts = @()
    foreach ($seg in $data[0]) { if ($seg -and $seg[0]) { $parts += [string]$seg[0] } }
    return ($parts -join "")
}

# ---------------------------------------------------------------- log reading
$script:Pos = -1L          # -1: start at the end (do not translate old lines)
$script:Rest = ""
$script:Enc = [Text.Encoding]::UTF8

function Read-NewLines {
    $path = $Config.LogPath
    if (-not (Test-Path -LiteralPath $path)) { return @() }
    $fs = New-Object IO.FileStream($path, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::ReadWrite)
    try {
        $len = $fs.Length
        if ($script:Pos -lt 0) {
            # first look: detect UTF-16 logs, then jump to the end
            if ($len -ge 2) {
                $bom = New-Object byte[] 2
                [void]$fs.Read($bom, 0, 2)
                if ($bom[0] -eq 0xFF -and $bom[1] -eq 0xFE) { $script:Enc = [Text.Encoding]::Unicode }
            }
            $script:Pos = $len
            return @()
        }
        if ($len -lt $script:Pos) { $script:Pos = 0; $script:Rest = "" }   # log restarted
        if ($len -eq $script:Pos) { return @() }
        [void]$fs.Seek($script:Pos, [IO.SeekOrigin]::Begin)
        $count = [int]($len - $script:Pos)
        $buf = New-Object byte[] $count
        $read = $fs.Read($buf, 0, $count)
        $script:Pos += $read
        $text = $script:Rest + $script:Enc.GetString($buf, 0, $read)
    } finally { $fs.Close() }
    $lines = $text -split "`r?`n"
    $script:Rest = $lines[-1]                       # unfinished last line
    if ($lines.Count -le 1) { return @() }
    return $lines[0..($lines.Count - 2)]
}

# "11/22 13:29:01.123  [Guild] [Name]: message" -> head, message
function Split-ChatLine([string]$line) {
    $body = $line
    if ($line -match '^\d+/\d+\s+[\d:\.]+\s+(.*)$') { $body = $Matches[1] }
    $i = $body.IndexOf(": ")
    if ($i -gt 0 -and $i -lt 80) {
        return @($body.Substring(0, $i), $body.Substring($i + 2))
    }
    return @("", $body)
}

# ---------------------------------------------------------------- window
$dark = [Drawing.Color]::FromArgb(18, 22, 26)
$field = [Drawing.Color]::FromArgb(30, 36, 42)

$form = New-Object Windows.Forms.Form
$form.TopMost = $true
$form.Opacity = 0.92
$form.BackColor = $dark
$form.ForeColor = [Drawing.Color]::Gainsboro
$form.Width = [int]$Config.W
$form.Height = [int]$Config.H
if ($Config.X -ge 0) { $form.StartPosition = "Manual"; $form.Location = New-Object Drawing.Point([int]$Config.X, [int]$Config.Y) }

# ---- top bar
$top = New-Object Windows.Forms.FlowLayoutPanel
$top.Dock = "Top"; $top.Height = 30; $top.Padding = New-Object Windows.Forms.Padding(4, 3, 4, 0)

$toLabel = New-Object Windows.Forms.Label
$toLabel.AutoSize = $true; $toLabel.Padding = New-Object Windows.Forms.Padding(0, 4, 0, 0)

$lang = New-Object Windows.Forms.ComboBox
$lang.DropDownStyle = "DropDownList"; $lang.Width = 95

$only = New-Object Windows.Forms.CheckBox
$only.AutoSize = $true; $only.Checked = [bool]$Config.OnlyChinese
$only.Add_CheckedChanged({ $Config.OnlyChinese = $only.Checked; Save-Config })

$orig = New-Object Windows.Forms.CheckBox
$orig.AutoSize = $true; $orig.Checked = [bool]$Config.ShowOriginal
$orig.Add_CheckedChanged({ $Config.ShowOriginal = $orig.Checked; Save-Config })

$clear = New-Object Windows.Forms.Button
$clear.AutoSize = $true; $clear.FlatStyle = "Flat"

$pick = New-Object Windows.Forms.Button
$pick.AutoSize = $true; $pick.FlatStyle = "Flat"

$uiBtn = New-Object Windows.Forms.Button
$uiBtn.AutoSize = $true; $uiBtn.FlatStyle = "Flat"; $uiBtn.ForeColor = [Drawing.Color]::Gray

$top.Controls.AddRange(@($toLabel, $lang, $only, $orig, $clear, $pick, $uiBtn))

# ---- chat
$box = New-Object Windows.Forms.RichTextBox
$box.Dock = "Fill"; $box.ReadOnly = $true; $box.BorderStyle = "None"
$box.BackColor = $dark; $box.ForeColor = [Drawing.Color]::White
$box.Font = New-Object Drawing.Font("Segoe UI", 10)

# ---- reply line: type in any language, get Chinese on the clipboard
$bottom = New-Object Windows.Forms.Panel
$bottom.Dock = "Bottom"; $bottom.Height = 30
$bottom.Padding = New-Object Windows.Forms.Padding(4, 3, 4, 3)

$chan = New-Object Windows.Forms.ComboBox
$chan.DropDownStyle = "DropDownList"; $chan.Width = 100; $chan.Dock = "Left"
$chanPrefix = @("/g ", "/s ", "/p ", "/ra ", "/1 ", "/w ", "")

$whisper = New-Object Windows.Forms.TextBox
$whisper.Width = 90; $whisper.Dock = "Left"; $whisper.Visible = $false
$whisper.BackColor = $field; $whisper.ForeColor = [Drawing.Color]::White
$chan.Add_SelectedIndexChanged({ $whisper.Visible = ($chan.SelectedIndex -eq 5) })

$send = New-Object Windows.Forms.Button
$send.Width = 130; $send.Dock = "Right"; $send.FlatStyle = "Flat"

$replyBox = New-Object Windows.Forms.TextBox
$replyBox.Dock = "Fill"
$replyBox.BackColor = $field; $replyBox.ForeColor = [Drawing.Color]::White
$replyBox.Font = New-Object Drawing.Font("Segoe UI", 10)

$bottom.Controls.Add($replyBox)
$bottom.Controls.Add($whisper)
$bottom.Controls.Add($chan)
$bottom.Controls.Add($send)

$status = New-Object Windows.Forms.Label
$status.Dock = "Bottom"; $status.Height = 18; $status.ForeColor = [Drawing.Color]::Gray
$status.Font = New-Object Drawing.Font("Segoe UI", 8)

$form.Controls.Add($box)
$form.Controls.Add($top)
$form.Controls.Add($bottom)
$form.Controls.Add($status)

# ---- texts on the controls (called again when the UI language changes)
$script:Building = $false
# Chinese mode: English (non-Chinese) lines are translated to Chinese and the
# reply line translates to English
function Is-ZhMode { return ([string]$Config.Lang -eq "zh-CN") }
function Apply-Texts {
    $script:Building = $true
    $form.Text = T "Title"
    $toLabel.Text = T "To"
    $lang.Items.Clear(); [void]$lang.Items.AddRange((T "Langs"))
    $lang.SelectedIndex = $(if ($Config.Lang -eq "hu") { 1 } elseif ($Config.Lang -eq "zh-CN") { 2 } else { 0 })
    if (Is-ZhMode) { $only.Text = T "OnlyEn" } else { $only.Text = T "OnlyCjk" }
    $orig.Text = T "Orig"
    $clear.Text = T "Clear"
    $pick.Text = T "Log"
    $uiBtn.Text = T "Ui"
    if (Is-ZhMode) { $send.Text = T "SendEn" } else { $send.Text = T "Send" }
    $ci = $chan.SelectedIndex; if ($ci -lt 0) { $ci = 0 }
    $chan.Items.Clear(); [void]$chan.Items.AddRange((T "Channels"))
    $chan.SelectedIndex = $ci
    $script:Building = $false
}

$lang.Add_SelectedIndexChanged({
    if ($script:Building) { return }
    $Config.Lang = $(if ($lang.SelectedIndex -eq 1) { "hu" } elseif ($lang.SelectedIndex -eq 2) { "zh-CN" } else { "en" }); Save-Config
    Apply-Texts
})
$uiBtn.Add_Click({
    $Config.UiLang = $(if ($Config.UiLang -eq "hu") { "en" } else { "hu" }); Save-Config
    Apply-Texts
})

function Add-Text([string]$text, [Drawing.Color]$color, [float]$size = 10) {
    $box.SelectionStart = $box.TextLength
    $box.SelectionLength = 0
    $box.SelectionColor = $color
    $box.SelectionFont = New-Object Drawing.Font("Segoe UI", $size)
    $box.AppendText($text)
}

function Scroll-Down {
    # keep the window light: drop old lines
    if ($box.Lines.Count -gt 400) {
        $box.ReadOnly = $false; $box.Select(0, $box.GetFirstCharIndexFromLine(100)); $box.SelectedText = ""; $box.ReadOnly = $true
    }
    $box.SelectionStart = $box.TextLength
    $box.ScrollToCaret()
}

function Show-Line([string]$head, [string]$translated, [string]$original) {
    if ($head) { Add-Text ($head + ": ") ([Drawing.Color]::FromArgb(64, 255, 64)) }
    Add-Text ($translated + "`n") ([Drawing.Color]::White)
    if ($Config.ShowOriginal -and $original -and $original -ne $translated) {
        Add-Text ("    " + $original + "`n") ([Drawing.Color]::FromArgb(120, 120, 120)) 8.5
    }
    Scroll-Down
}

function Set-Status([string]$text) { $status.Text = $text }

$clear.Add_Click({ $box.Clear() })
$pick.Add_Click({
    $dlg = New-Object Windows.Forms.OpenFileDialog
    $dlg.Filter = "WoWChatLog.txt|WoWChatLog.txt|Text|*.txt"
    $dlg.Title = T "Pick"
    if ($dlg.ShowDialog() -eq "OK") {
        $Config.LogPath = $dlg.FileName; Save-Config
        $script:Pos = -1L; $script:Rest = ""
        Set-Status ((T "Watching") + $Config.LogPath)
    }
})

# translate the reply to Chinese and put it on the clipboard; in the game:
# Enter, Ctrl+V, Enter (the channel command is pasted along with it)
function Send-Reply {
    $text = $replyBox.Text.Trim()
    if (-not $text) { return }
    try {
        $prefix = $chanPrefix[$chan.SelectedIndex]
        if ($chan.SelectedIndex -eq 5) {
            $name = $whisper.Text.Trim()
            if (-not $name) { Set-Status (T "WhoWhisper"); return }
            $prefix = "/w " + $name + " "
        }
        $replyTarget = $(if (Is-ZhMode) { "en" } else { "zh-CN" })
        $tr = Invoke-Translate $text $replyTarget
        [Windows.Forms.Clipboard]::SetText($prefix + $tr)
        Add-Text ((T "You") + $text + "`n") ([Drawing.Color]::FromArgb(110, 180, 255))
        Add-Text ("    " + $prefix + $tr + "`n") ([Drawing.Color]::FromArgb(150, 200, 255)) 9
        Scroll-Down
        $replyBox.Clear()
        Set-Status (T "Copied")
    } catch {
        Set-Status ((T "TrError") + $_.Exception.Message)
    }
}
$send.Add_Click({ Send-Reply })
$replyBox.Add_KeyDown({
    if ($_.KeyCode -eq "Return") { $_.SuppressKeyPress = $true; Send-Reply }
})

$form.Add_FormClosing({
    $Config.X = $form.Location.X; $Config.Y = $form.Location.Y
    $Config.W = $form.Width; $Config.H = $form.Height
    Save-Config
})

# ---------------------------------------------------------------- polling
$timer = New-Object Windows.Forms.Timer
$timer.Interval = 700
$timer.Add_Tick({
    $timer.Stop()
    try {
        if (-not (Test-Path -LiteralPath $Config.LogPath)) {
            Set-Status (T "NoLog")
            return
        }
        foreach ($line in (Read-NewLines)) {
            if (-not $line.Trim()) { continue }
            $parts = Split-ChatLine $line
            $head = $parts[0]; $msg = $parts[1]
            $isCjk = $msg -match $CjkPattern
            # the lines in the other language than the target get translated
            $foreign = $(if (Is-ZhMode) { -not $isCjk } else { $isCjk })
            if ($Config.OnlyChinese -and -not $foreign) { continue }
            if (-not $foreign) { Show-Line $head $msg ""; continue }
            try {
                $tr = Invoke-Translate $msg $Config.Lang
                Show-Line $head $tr $msg
                Set-Status ((T "Last") + (Get-Date -Format "HH:mm:ss"))
            } catch {
                Show-Line $head ($msg + (T "Failed")) ""
                Set-Status ((T "Error") + $_.Exception.Message)
            }
        }
    } catch {
        Set-Status ((T "Error") + $_.Exception.Message)
    } finally {
        $timer.Start()
    }
})

Apply-Texts
Set-Status ((T "Watching") + $Config.LogPath)
$timer.Start()
[void]$form.ShowDialog()
$timer.Stop()
