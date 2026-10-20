param([Parameter(Mandatory=$true)][string]$StatePath, [switch]$UseWpf)
Add-Type -AssemblyName System.Windows.Forms,System.Drawing
Add-Type @'
using System;
using System.Runtime.InteropServices;
using System.Windows.Forms;
public static class FixtureDpi {
    [DllImport("user32.dll")] public static extern bool SetProcessDpiAwarenessContext(IntPtr value);
    [DllImport("user32.dll")] public static extern bool ShowWindow(IntPtr hwnd, int cmd);
}
public sealed class FixtureFocus : NativeWindow {
    static FixtureFocus instance;
    readonly TextBox input;
    FixtureFocus(Form form,TextBox input) { this.input=input; AssignHandle(form.Handle); }
    public static void Install(Form form,TextBox input) { instance=new FixtureFocus(form,input); }
    protected override void WndProc(ref Message message) {
        if(message.Msg==0x802A) { input.Focus(); input.SelectAll(); message.Result=new IntPtr(1); return; }
        base.WndProc(ref message);
    }
}
'@ -ReferencedAssemblies System.Windows.Forms
[FixtureDpi]::SetProcessDpiAwarenessContext([IntPtr](-4)) | Out-Null
if ($UseWpf) {
    Add-Type -AssemblyName PresentationFramework
    $window = [Windows.Markup.XamlReader]::Parse('<Window xmlns="http://schemas.microsoft.com/winfx/2006/xaml/presentation" Width="950" Height="330" Left="100" Top="100" Topmost="True" Title="InstaScanSpeak UI Automation fixture"><TextBox Name="SelectedText" Text="UI Automation selected text is read aloud." FontSize="24" Margin="25" VerticalAlignment="Top"/></Window>')
    $textBox = $window.FindName('SelectedText')
    $window.Add_Activated({ $textBox.Focus() | Out-Null; $textBox.SelectAll() })
    $window.Add_ContentRendered({
        $handle = [Windows.Interop.WindowInteropHelper]::new($window).Handle
        [FixtureDpi]::ShowWindow($handle,5) | Out-Null
        $window.Activate() | Out-Null
        $textBox.Focus() | Out-Null
        $textBox.SelectAll()
        @{ pid=$PID; form=$handle.ToInt64(); input=$handle.ToInt64() } | ConvertTo-Json | Set-Content -LiteralPath $StatePath
    })
    $window.ShowDialog() | Out-Null
    exit
}
$form = New-Object Windows.Forms.Form
$form.Text = 'InstaScanSpeak integration fixture'
$form.StartPosition = 'Manual'
$form.Location = [Drawing.Point]::new(100,100)
$form.ClientSize = [Drawing.Size]::new(950,330)
$form.TopMost = $true
$form.BackColor = [Drawing.Color]::White
$textBox = New-Object Windows.Forms.TextBox
$textBox.Location = [Drawing.Point]::new(30,25)
$textBox.Size = [Drawing.Size]::new(880,50)
$textBox.Font = [Drawing.Font]::new('Segoe UI',22)
$textBox.Text = 'Selected text is read aloud by InstaScanSpeak.'
$form.Controls.Add($textBox)
$label = New-Object Windows.Forms.Label
$label.Location = [Drawing.Point]::new(30,115)
$label.Size = [Drawing.Size]::new(880,140)
$label.Font = [Drawing.Font]::new('Segoe UI',26)
$label.Text = 'InstaScanSpeak reads this screen text aloud.'
$form.Controls.Add($label)
$form.Add_Shown({
    [FixtureFocus]::Install($form,$textBox)
    [FixtureDpi]::ShowWindow($form.Handle, 5) | Out-Null
    $form.Activate()
    $textBox.Focus() | Out-Null
    $textBox.SelectAll()
    $point = $label.PointToScreen([Drawing.Point]::Empty)
    @{ pid=$PID; form=$form.Handle.ToInt64(); input=$textBox.Handle.ToInt64(); x=$point.X; y=$point.Y; width=$label.Width; height=$label.Height } |
        ConvertTo-Json | Set-Content -LiteralPath $StatePath
})
$timer = New-Object Windows.Forms.Timer
$timer.Interval = 180000
$timer.Add_Tick({ $form.Close() })
$timer.Start()
[Windows.Forms.Application]::Run($form)
