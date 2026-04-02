# =================================================
# Author        : Venkat Praveen Kumar Chavali
# Date          : 24-Mar-2026
# Version       : 1.0
# Script Type   : Private
# Purpose       : VM input dialog — textbox paste + CSV file browse.
#                 Replaces Get-VMNamesFromTextBox from original script.
# Name          : Show-VMwareMigrationInputDialog.ps1
# Compatibility : PS 5.1-compatible
# =================================================

function Show-VMwareMigrationInputDialog {
    [CmdletBinding()]
    param(
        [string[]]$ConnectedVCenters = @(),
        [int]$MaxObjects = 10000
    )

    Add-Type -AssemblyName System.Windows.Forms | Out-Null
    Add-Type -AssemblyName System.Drawing       | Out-Null

    $vcLabel = if ($ConnectedVCenters -and $ConnectedVCenters.Count -gt 0) {
        "Connected vCenters: " + ($ConnectedVCenters -join "  |  ")
    } else {
        "No vCenters specified — all connected sessions will be searched"
    }

    function Parse-VMNames { param([string]$Raw)
        if ([string]::IsNullOrWhiteSpace($Raw)) { return @() }
        return @(
            ($Raw -replace "`r","" -split "`n") |
            ForEach-Object { ($_ -replace '[",]','').Trim() } |
            Where-Object { $_ -and $_ -notmatch '^(?i)vmname$' } |
            Select-Object -Unique
        )
    }

    $form               = New-Object System.Windows.Forms.Form
    $form.Text          = "VMware Site Affinity Migration — VM Input"
    $form.StartPosition = "CenterScreen"
    $form.Size          = New-Object System.Drawing.Size(680, 620)
    $form.MinimumSize   = New-Object System.Drawing.Size(520, 500)
    $form.BackColor     = [System.Drawing.Color]::FromArgb(245, 247, 250)
    $form.Font          = New-Object System.Drawing.Font("Segoe UI", 9)
    $form.Tag           = $null

    # Header
    $header           = New-Object System.Windows.Forms.Panel
    $header.Dock      = "Top"; $header.Height = 70
    $header.BackColor = [System.Drawing.Color]::FromArgb(0, 100, 60)
    $form.Controls.Add($header)

    $lblTitle         = New-Object System.Windows.Forms.Label
    $lblTitle.Text    = "Site Affinity Migration — VM Input"
    $lblTitle.ForeColor = [System.Drawing.Color]::White
    $lblTitle.Font    = New-Object System.Drawing.Font("Segoe UI", 13, [System.Drawing.FontStyle]::Bold)
    $lblTitle.AutoSize = $true; $lblTitle.Location = New-Object System.Drawing.Point(16, 8)
    $header.Controls.Add($lblTitle)

    $lblVcs           = New-Object System.Windows.Forms.Label
    $lblVcs.Text      = $vcLabel
    $lblVcs.ForeColor = [System.Drawing.Color]::FromArgb(190, 230, 210)
    $lblVcs.Font      = New-Object System.Drawing.Font("Segoe UI", 8)
    $lblVcs.AutoSize  = $true; $lblVcs.Location = New-Object System.Drawing.Point(18, 42)
    $header.Controls.Add($lblVcs)

    # Info strip
    $strip            = New-Object System.Windows.Forms.Panel
    $strip.Dock       = "Top"; $strip.Height = 32
    $strip.BackColor  = [System.Drawing.Color]::FromArgb(210, 240, 225)
    $form.Controls.Add($strip)

    $lblInfo          = New-Object System.Windows.Forms.Label
    $lblInfo.Text     = "  Paste VM names (one per line) OR browse to a CSV/TXT file. Max $MaxObjects VMs."
    $lblInfo.ForeColor = [System.Drawing.Color]::FromArgb(0, 80, 40)
    $lblInfo.Font     = New-Object System.Drawing.Font("Segoe UI", 8, [System.Drawing.FontStyle]::Italic)
    $lblInfo.Dock     = "Fill"; $lblInfo.TextAlign = "MiddleLeft"
    $strip.Controls.Add($lblInfo)

    # Toolbar
    $toolPanel           = New-Object System.Windows.Forms.Panel
    $toolPanel.Dock      = "Top"; $toolPanel.Height = 38
    $toolPanel.BackColor = [System.Drawing.Color]::FromArgb(235, 245, 240)
    $form.Controls.Add($toolPanel)

    $btnBrowse           = New-Object System.Windows.Forms.Button
    $btnBrowse.Text      = "Browse CSV / TXT..."
    $btnBrowse.Size      = New-Object System.Drawing.Size(140, 28)
    $btnBrowse.Location  = New-Object System.Drawing.Point(8, 5)
    $btnBrowse.FlatStyle = "Flat"
    $btnBrowse.BackColor = [System.Drawing.Color]::FromArgb(0, 100, 60)
    $btnBrowse.ForeColor = [System.Drawing.Color]::White
    $btnBrowse.FlatAppearance.BorderSize = 0
    $toolPanel.Controls.Add($btnBrowse)

    $btnClear            = New-Object System.Windows.Forms.Button
    $btnClear.Text       = "Clear"
    $btnClear.Size       = New-Object System.Drawing.Size(70, 28)
    $btnClear.Location   = New-Object System.Drawing.Point(156, 5)
    $btnClear.FlatStyle  = "Flat"
    $toolPanel.Controls.Add($btnClear)

    $lblFile             = New-Object System.Windows.Forms.Label
    $lblFile.Text        = ""
    $lblFile.ForeColor   = [System.Drawing.Color]::FromArgb(0, 120, 60)
    $lblFile.Font        = New-Object System.Drawing.Font("Segoe UI", 8, [System.Drawing.FontStyle]::Italic)
    $lblFile.AutoSize    = $true; $lblFile.Location = New-Object System.Drawing.Point(236, 10)
    $toolPanel.Controls.Add($lblFile)

    # TextBox
    $txtBox              = New-Object System.Windows.Forms.TextBox
    $txtBox.Multiline    = $true; $txtBox.ScrollBars = "Vertical"
    $txtBox.Font         = New-Object System.Drawing.Font("Consolas", 9)
    $txtBox.AcceptsReturn = $true
    $txtBox.Location     = New-Object System.Drawing.Point(14, 154)
    $txtBox.Size         = New-Object System.Drawing.Size(640, 360)
    $txtBox.Anchor       = "Top,Left,Right,Bottom"
    $form.Controls.Add($txtBox)

    # Count + warn labels
    $lblCount            = New-Object System.Windows.Forms.Label
    $lblCount.Text       = "Objects entered: 0"
    $lblCount.Font       = New-Object System.Drawing.Font("Segoe UI", 8, [System.Drawing.FontStyle]::Italic)
    $lblCount.ForeColor  = [System.Drawing.Color]::FromArgb(80,80,80)
    $lblCount.AutoSize   = $true; $lblCount.Location = New-Object System.Drawing.Point(16, 520)
    $lblCount.Anchor     = "Bottom,Left"
    $form.Controls.Add($lblCount)

    $lblWarn             = New-Object System.Windows.Forms.Label
    $lblWarn.Text        = ""
    $lblWarn.ForeColor   = [System.Drawing.Color]::Firebrick
    $lblWarn.Font        = New-Object System.Drawing.Font("Segoe UI", 8, [System.Drawing.FontStyle]::Bold)
    $lblWarn.AutoSize    = $true; $lblWarn.Location = New-Object System.Drawing.Point(200, 520)
    $lblWarn.Anchor      = "Bottom,Left"
    $form.Controls.Add($lblWarn)

    # Bottom buttons
    $btnPanel            = New-Object System.Windows.Forms.Panel
    $btnPanel.Dock       = "Bottom"; $btnPanel.Height = 52
    $btnPanel.BackColor  = [System.Drawing.Color]::FromArgb(235,238,243)
    $form.Controls.Add($btnPanel)

    $btnOK               = New-Object System.Windows.Forms.Button
    $btnOK.Text          = "Start Migration"
    $btnOK.Size          = New-Object System.Drawing.Size(130, 32)
    $btnOK.Location      = New-Object System.Drawing.Point(410, 10)
    $btnOK.BackColor     = [System.Drawing.Color]::FromArgb(0, 140, 60)
    $btnOK.ForeColor     = [System.Drawing.Color]::White
    $btnOK.FlatStyle     = "Flat"; $btnOK.FlatAppearance.BorderSize = 0
    $btnOK.Font          = New-Object System.Drawing.Font("Segoe UI", 9, [System.Drawing.FontStyle]::Bold)
    $btnPanel.Controls.Add($btnOK)

    $btnCancel           = New-Object System.Windows.Forms.Button
    $btnCancel.Text      = "Cancel"
    $btnCancel.Size      = New-Object System.Drawing.Size(90, 32)
    $btnCancel.Location  = New-Object System.Drawing.Point(550, 10)
    $btnCancel.FlatStyle = "Flat"
    $btnPanel.Controls.Add($btnCancel)

    $form.AcceptButton = $btnOK; $form.CancelButton = $btnCancel

    # Events
    $txtBox.Add_TextChanged({
        $names = Parse-VMNames -Raw $txtBox.Text
        $count = $names.Count
        $lblCount.Text = "Objects entered: $count"
        if ($count -gt $MaxObjects) {
            $lblWarn.Text = "  ⚠ Limit is $MaxObjects — first $MaxObjects will be used"
            $lblCount.ForeColor = [System.Drawing.Color]::Firebrick
        } else {
            $lblWarn.Text = ""; $lblCount.ForeColor = [System.Drawing.Color]::FromArgb(80,80,80)
        }
    })

    $btnBrowse.Add_Click({
        $ofd = New-Object System.Windows.Forms.OpenFileDialog
        $ofd.Title = "Select VM list file"
        $ofd.Filter = "CSV / Text files (*.csv;*.txt)|*.csv;*.txt|All files (*.*)|*.*"
        if ($ofd.ShowDialog() -eq [System.Windows.Forms.DialogResult]::OK) {
            try {
                $txtBox.Text = Get-Content -LiteralPath $ofd.FileName -Raw -Encoding UTF8
                $lblFile.Text = "Loaded: " + [System.IO.Path]::GetFileName($ofd.FileName)
            } catch {
                [System.Windows.Forms.MessageBox]::Show("Failed to read file:`n$($_.Exception.Message)","File Error",
                    [System.Windows.Forms.MessageBoxButtons]::OK,
                    [System.Windows.Forms.MessageBoxIcon]::Error) | Out-Null
            }
        }
    })

    $btnClear.Add_Click({ $txtBox.Text = ""; $lblFile.Text = "" })

    $btnOK.Add_Click({
        $names = Parse-VMNames -Raw $txtBox.Text
        if ($names.Count -eq 0) {
            [System.Windows.Forms.MessageBox]::Show("No VM names entered.","No Input",
                [System.Windows.Forms.MessageBoxButtons]::OK,
                [System.Windows.Forms.MessageBoxIcon]::Warning) | Out-Null
            return
        }
        if ($names.Count -gt $MaxObjects) {
            $ans = [System.Windows.Forms.MessageBox]::Show(
                "$($names.Count) VMs found. Limit is $MaxObjects. Use first $MaxObjects?","Limit Exceeded",
                [System.Windows.Forms.MessageBoxButtons]::YesNo,
                [System.Windows.Forms.MessageBoxIcon]::Warning)
            if ($ans -ne [System.Windows.Forms.DialogResult]::Yes) { return }
            $names = $names | Select-Object -First $MaxObjects
        }
        $form.Tag = [string[]]$names
        $form.Close()
    })

    $btnCancel.Add_Click({ $form.Close() })

    [void]$form.ShowDialog()
    if ($form.Tag -and $form.Tag.Count -gt 0) { return [string[]]$form.Tag }
    return $null
}
