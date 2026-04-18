using System;
using System.Collections;
using System.Collections.Generic;
using System.Diagnostics;
using System.Drawing;
using System.IO;
using System.Linq;
using System.Net;
using System.Net.Sockets;
using System.Runtime.InteropServices;
using System.Text;
using System.Threading;
using System.Threading.Tasks;
using System.Windows.Forms;

namespace ProxyMenubar
{
    public enum TunnelState { Idle, Releasing, Connecting, Connected }

    public class TunnelManager
    {
        private const string ProxyHost = "gitlab";
        private const int ProxyPort = 1080;

        private Process _process;
        private readonly object _lock = new object();
        private List<string> _logBuffer = new List<string>();
        private const int LogBufferMax = 500;
        private TunnelState _state = TunnelState.Idle;

        public TunnelState State
        {
            get { lock (_lock) return _state; }
            private set
            {
                lock (_lock) _state = value;
                OnStateChanged?.Invoke(_state);
            }
        }

        public event Action<TunnelState> OnStateChanged;
        public event Action OnUnexpectedDisconnect;

        public string GetLogs()
        {
            lock (_lock) return string.Join(Environment.NewLine, _logBuffer);
        }

        public void KillOrphanedTunnel()
        {
            try
            {
                // Windows version of lsof -ti :1080 | xargs kill -9
                // Find PIDs using port 1080
                var startInfo = new ProcessStartInfo
                {
                    FileName = "cmd.exe",
                    Arguments = $"/c \"netstat -ano | findstr :1080\"",
                    RedirectStandardOutput = true,
                    UseShellExecute = false,
                    CreateNoWindow = true
                };

                using (var proc = Process.Start(startInfo))
                {
                    string output = proc.StandardOutput.ReadToEnd();
                    proc.WaitForExit();

                    var lines = output.Split(new[] { Environment.NewLine }, StringSplitOptions.RemoveEmptyEntries);
                    foreach (var line in lines)
                    {
                        var parts = line.Split(new[] { ' ' }, StringSplitOptions.RemoveEmptyEntries);
                        if (parts.Length > 0)
                        {
                            string pidStr = parts.Last();
                            if (int.TryParse(pidStr, out int pid) && pid > 0)
                            {
                                try
                                {
                                    var toKill = Process.GetProcessById(pid);
                                    if (toKill.ProcessName.Contains("ssh"))
                                    {
                                        toKill.Kill();
                                    }
                                }
                                catch { }
                            }
                        }
                    }
                }
            }
            catch { }
        }

        public async Task<string> ConnectAsync()
        {
            if (State == TunnelState.Connected) Disconnect();

            State = TunnelState.Releasing;

            return await Task.Run(async () =>
            {
                var deadline = DateTime.Now.AddSeconds(10);
                while (DateTime.Now < deadline)
                {
                    if (IsPortFree()) break;
                    KillOrphanedTunnel();
                    await Task.Delay(500);
                }

                if (!IsPortFree())
                {
                    State = TunnelState.Idle;
                    return "Port 1080 could not be released. Please wait and try again.";
                }

                string error = LaunchSSH();
                if (error != null)
                {
                    State = TunnelState.Idle;
                    return error;
                }

                return null;
            });
        }

        private string LaunchSSH()
        {
            try
            {
                _process = new Process();
                _process.StartInfo.FileName = "ssh";
                _process.StartInfo.Arguments = $"-D {ProxyPort} -N -v {ProxyHost}";
                _process.StartInfo.UseShellExecute = false;
                _process.StartInfo.RedirectStandardError = true;
                _process.StartInfo.CreateNoWindow = true;

                // Capture logs from stderr
                _process.ErrorDataReceived += (s, e) =>
                {
                    if (!string.IsNullOrEmpty(e.Data))
                    {
                        lock (_lock)
                        {
                            _logBuffer.Add(e.Data);
                            if (_logBuffer.Count > LogBufferMax) _logBuffer.RemoveAt(0);
                        }
                    }
                };

                _process.EnableRaisingEvents = true;
                _process.Exited += (s, e) =>
                {
                    lock (_lock)
                    {
                        if (_state != TunnelState.Idle)
                        {
                            _state = TunnelState.Idle;
                            _process = null;
                            OnStateChanged?.Invoke(TunnelState.Idle);
                            OnUnexpectedDisconnect?.Invoke();
                        }
                    }
                };

                _process.Start();
                _process.BeginErrorReadLine();
                State = TunnelState.Connecting;

                // Poll for connectivity
                Task.Run(async () =>
                {
                    var deadline = DateTime.Now.AddSeconds(30);
                    while (DateTime.Now < deadline)
                    {
                        if (_process == null || _process.HasExited) break;
                        if (IsPortReachable())
                        {
                            lock (_lock)
                            {
                                if (_process != null && !_process.HasExited)
                                {
                                    _state = TunnelState.Connected;
                                    OnStateChanged?.Invoke(TunnelState.Connected);
                                }
                            }
                            return;
                        }
                        await Task.Delay(300);
                    }
                });

                return null;
            }
            catch (Exception ex)
            {
                return $"Failed to launch ssh: {ex.Message}";
            }
        }

        private bool IsPortFree()
        {
            try
            {
                using (var client = new TcpClient())
                {
                    var result = client.BeginConnect("127.0.0.1", ProxyPort, null, null);
                    bool success = result.AsyncWaitHandle.WaitOne(TimeSpan.FromMilliseconds(100));
                    if (success)
                    {
                        client.EndConnect(result);
                        return false; // Port is in use
                    }
                    return true;
                }
            }
            catch { return true; }
        }

        private bool IsPortReachable()
        {
            try
            {
                using (var client = new TcpClient())
                {
                    var result = client.BeginConnect("127.0.0.1", ProxyPort, null, null);
                    bool success = result.AsyncWaitHandle.WaitOne(TimeSpan.FromMilliseconds(500));
                    if (success)
                    {
                        client.EndConnect(result);
                        return true;
                    }
                    return false;
                }
            }
            catch { return false; }
        }

        public void Disconnect()
        {
            lock (_lock)
            {
                if (_process != null && !_process.HasExited)
                {
                    try { _process.Kill(); } catch { }
                }
                _process = null;
                _state = TunnelState.Idle;
                OnStateChanged?.Invoke(TunnelState.Idle);
            }
        }
    }

    public class LogForm : Form
    {
        private TextBox _textBox;
        private TunnelManager _tunnel;
        private System.Windows.Forms.Timer _timer;

        public LogForm(TunnelManager tunnel)
        {
            _tunnel = tunnel;
            this.Text = "Proxy Logs";
            this.Width = 800;
            this.Height = 500;
            this.StartPosition = FormStartPosition.CenterScreen;

            _textBox = new TextBox
            {
                Multiline = true,
                ReadOnly = true,
                Dock = DockStyle.Fill,
                BackColor = Color.FromArgb(20, 20, 20),
                ForeColor = Color.LightGreen,
                Font = new Font("Consolas", 10),
                ScrollBars = ScrollBars.Vertical
            };

            this.Controls.Add(_textBox);

            _timer = new System.Windows.Forms.Timer { Interval = 1000 };
            _timer.Tick += (s, e) => RefreshLogs();
            
            this.FormClosing += (s, e) =>
            {
                _timer.Stop();
                this.Hide();
                e.Cancel = true; // Just hide, don't dispose
            };
        }

        public void ShowLogs()
        {
            RefreshLogs();
            this.Show();
            this.BringToFront();
            _timer.Start();
        }

        private void RefreshLogs()
        {
            string logs = _tunnel.GetLogs();
            _textBox.Text = string.IsNullOrEmpty(logs) ? "(no logs yet — connect first)" : logs;
            _textBox.SelectionStart = _textBox.Text.Length;
            _textBox.ScrollToCaret();
        }
    }

    public class ProxyMenubarContext : ApplicationContext
    {
        private NotifyIcon _notifyIcon;
        private TunnelManager _tunnel;
        private LogForm _logForm;
        private ContextMenuStrip _menu;

        private ToolStripMenuItem _statusItem;
        private ToolStripMenuItem _toggleItem;

        public ProxyMenubarContext()
        {
            _tunnel = new TunnelManager();
            _logForm = new LogForm(_tunnel);

            _tunnel.OnStateChanged += state => 
            {
                if (Control.DefaultFont != null) // Ensure we are on UI thread
                {
                    _notifyIcon.ContextMenuStrip.Invoke((MethodInvoker)UpdateMenuState);
                }
            };

            _tunnel.OnUnexpectedDisconnect += () =>
            {
                _notifyIcon.ShowBalloonTip(3000, "Proxy Menubar", "Connection was lost", ToolTipIcon.Warning);
            };

            _menu = new ContextMenuStrip();
            
            _statusItem = new ToolStripMenuItem("Status: Disconnected") { Enabled = false };
            _menu.Items.Add(_statusItem);
            _menu.Items.Add(new ToolStripSeparator());

            _toggleItem = new ToolStripMenuItem("Enable Proxy", null, ToggleProxy);
            _menu.Items.Add(_toggleItem);

            _menu.Items.Add(new ToolStripSeparator());
            _menu.Items.Add(new ToolStripMenuItem("Show Logs", null, (s, e) => _logForm.ShowLogs()));
            _menu.Items.Add(new ToolStripSeparator());
            _menu.Items.Add(new ToolStripMenuItem("Quit", null, (s, e) => Exit()));

            _notifyIcon = new NotifyIcon
            {
                Icon = SystemIcons.Shield, // Default icon, can be replaced with custom .ico
                ContextMenuStrip = _menu,
                Text = "Proxy Menubar",
                Visible = true
            };

            UpdateMenuState();
        }

        private void UpdateMenuState()
        {
            switch (_tunnel.State)
            {
                case TunnelState.Idle:
                    _statusItem.Text = "Status: Disconnected";
                    _toggleItem.Text = "Enable Proxy";
                    _toggleItem.Enabled = true;
                    // In a real app, we'd change the icon here
                    break;
                case TunnelState.Releasing:
                    _statusItem.Text = "Releasing port...";
                    _toggleItem.Text = "Releasing port...";
                    _toggleItem.Enabled = false;
                    break;
                case TunnelState.Connecting:
                    _statusItem.Text = "Connecting...";
                    _toggleItem.Text = "Connecting...";
                    _toggleItem.Enabled = false;
                    break;
                case TunnelState.Connected:
                    _statusItem.Text = "Connected → gitlab";
                    _toggleItem.Text = "Disable Proxy";
                    _toggleItem.Enabled = true;
                    break;
            }
        }

        private async void ToggleProxy(object sender, EventArgs e)
        {
            if (_tunnel.State == TunnelState.Connected)
            {
                _tunnel.Disconnect();
            }
            else if (_tunnel.State == TunnelState.Idle)
            {
                string error = await _tunnel.ConnectAsync();
                if (error != null)
                {
                    MessageBox.Show(error, "Connection Failed", MessageBoxButtons.OK, MessageBoxIcon.Error);
                }
            }
            UpdateMenuState();
        }

        private void Exit()
        {
            _tunnel.Disconnect();
            _tunnel.KillOrphanedTunnel();
            _notifyIcon.Visible = false;
            Application.Exit();
        }
    }

    static class Program
    {
        [STAThread]
        static void Main()
        {
            Application.EnableVisualStyles();
            Application.SetCompatibleTextRenderingDefault(false);
            Application.Run(new ProxyMenubarContext());
        }
    }
}
