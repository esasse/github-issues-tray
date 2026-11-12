using System.ComponentModel;
using System.Runtime.InteropServices;

namespace IssuesTray;

internal sealed record MenuEntry(string Text, int Id = 0, bool Enabled = true, bool IsDefault = false)
{
    public static readonly MenuEntry Separator = new("-");
}

/// <summary>
/// The notification-area icon, the global hotkey and the single-instance doorbell,
/// all on one hidden Win32 window. WinUI 3 has no tray icon of its own; going to
/// Shell_NotifyIcon directly costs a hundred lines and no dependency, and it is the
/// only way to get the 127-character tooltip (WinForms' NotifyIcon caps it at 63).
///
/// The window is a hidden top-level one, not message-only: message-only windows do
/// not receive broadcasts, and "TaskbarCreated" is how an icon survives Explorer
/// restarting.
/// </summary>
internal sealed class TrayHost : IDisposable
{
    public static readonly string WindowClass = AppPaths.InstanceName + ".Host";
    private const uint WM_TRAY = Native.WM_APP + 1;
    private const uint WM_SHOW_POPUP = Native.WM_APP + 2;
    private const int HotkeyId = 0xB17;
    private const int TipMax = 127;

    private readonly Native.WndProc _proc;   // kept alive: the window calls into it
    private readonly IntPtr _hwnd;
    private readonly uint _taskbarCreated;
    private IntPtr _icon;
    private string _tip = "";
    private bool _added;
    private bool _hotkeyRegistered;
    private long _lastClickTicks;

    public event Action? Click;
    public event Action? MiddleClick;
    public event Action? ContextMenuRequested;
    public event Action? HotkeyPressed;
    public event Action? ShowRequested;
    public event Action? AppearanceChanged;

    public TrayHost()
    {
        _proc = WndProc;
        var instance = Native.GetModuleHandleW(null);
        var wc = new Native.WNDCLASSEXW
        {
            cbSize = Marshal.SizeOf<Native.WNDCLASSEXW>(),
            lpfnWndProc = Marshal.GetFunctionPointerForDelegate(_proc),
            hInstance = instance,
            lpszClassName = WindowClass,
        };
        Native.RegisterClassExW(ref wc);
        _hwnd = Native.CreateWindowExW(0, WindowClass, "GitHub Issues Tray", 0, 0, 0, 0, 0,
            IntPtr.Zero, IntPtr.Zero, instance, IntPtr.Zero);
        if (_hwnd == IntPtr.Zero) throw new Win32Exception(Marshal.GetLastWin32Error());
        _taskbarCreated = Native.RegisterWindowMessageW("TaskbarCreated");
    }

    /// <summary>Takes ownership of the icon handle and destroys the previous one.</summary>
    public void Update(IntPtr icon, string tooltip)
    {
        var old = _icon;
        _icon = icon;
        _tip = Clamp(tooltip, TipMax);
        Apply();
        if (old != IntPtr.Zero && old != icon) Native.DestroyIcon(old);
    }

    public void SetTooltip(string tooltip)
    {
        var tip = Clamp(tooltip, TipMax);
        if (tip == _tip) return;
        _tip = tip;
        Apply();
    }

    private Native.NOTIFYICONDATAW NewData() => new()
    {
        cbSize = Marshal.SizeOf<Native.NOTIFYICONDATAW>(),
        hWnd = _hwnd,
        uID = 1,
        szTip = "",
        szInfo = "",
        szInfoTitle = "",
    };

    private void Apply()
    {
        if (_icon == IntPtr.Zero) return;
        var data = NewData();
        // NIF_SHOWTIP: with NOTIFYICON_VERSION_4 the standard tooltip only appears if asked for.
        data.uFlags = Native.NIF_MESSAGE | Native.NIF_ICON | Native.NIF_TIP | Native.NIF_SHOWTIP;
        data.uCallbackMessage = WM_TRAY;
        data.hIcon = _icon;
        data.szTip = _tip;

        if (_added && Native.Shell_NotifyIconW(Native.NIM_MODIFY, ref data)) return;

        // Not added yet, or the modify failed because Explorer lost the icon. A stale
        // registration would make the add fail, so clear it first; that one may fail.
        Native.Shell_NotifyIconW(Native.NIM_DELETE, ref data);
        _added = Native.Shell_NotifyIconW(Native.NIM_ADD, ref data);
        if (!_added)
        {
            Log.Write("Shell_NotifyIcon(NIM_ADD) failed; will retry when the taskbar comes back");
            return;
        }
        data.uVersion = Native.NOTIFYICON_VERSION_4;
        Native.Shell_NotifyIconW(Native.NIM_SETVERSION, ref data);
    }

    public bool RegisterHotkey(uint modifiers, uint virtualKey)
    {
        UnregisterHotkey();
        _hotkeyRegistered = Native.RegisterHotKey(_hwnd, HotkeyId, modifiers | Native.MOD_NOREPEAT, virtualKey);
        return _hotkeyRegistered;
    }

    public void UnregisterHotkey()
    {
        if (_hotkeyRegistered) Native.UnregisterHotKey(_hwnd, HotkeyId);
        _hotkeyRegistered = false;
    }

    /// <summary>Shows a native menu at the cursor and returns the chosen id (0 = none).</summary>
    public int ShowMenu(IReadOnlyList<MenuEntry> entries)
    {
        var root = Build(entries);
        try
        {
            Native.GetCursorPos(out var pt);
            // Without this the menu does not close when the user clicks elsewhere.
            Native.SetForegroundWindow(_hwnd);
            var chosen = Native.TrackPopupMenuEx(root, Native.TPM_RETURNCMD | Native.TPM_RIGHTBUTTON, pt.X, pt.Y, _hwnd, IntPtr.Zero);
            Native.PostMessageW(_hwnd, Native.WM_NULL, IntPtr.Zero, IntPtr.Zero);
            return (int)chosen;
        }
        finally
        {
            Native.DestroyMenu(root);
        }
    }

    private static IntPtr Build(IReadOnlyList<MenuEntry> entries)
    {
        var menu = Native.CreatePopupMenu();
        foreach (var entry in entries)
        {
            if (ReferenceEquals(entry, MenuEntry.Separator))
            {
                Native.AppendMenuW(menu, Native.MF_SEPARATOR, UIntPtr.Zero, null);
            }
            else
            {
                var flags = Native.MF_STRING | (entry.Enabled ? 0 : Native.MF_GRAYED);
                Native.AppendMenuW(menu, flags, (UIntPtr)(uint)entry.Id, entry.Text);
                if (entry.IsDefault) Native.SetMenuDefaultItem(menu, (uint)entry.Id, 0);
            }
        }
        return menu;
    }

    private IntPtr WndProc(IntPtr hWnd, uint msg, IntPtr wParam, IntPtr lParam)
    {
        try
        {
            if (msg == WM_TRAY)
            {
                // NOTIFYICON_VERSION_4: the event is in the low word of lParam.
                var ev = (uint)(lParam.ToInt64() & 0xFFFF);
                if (ev is Native.NIN_SELECT or Native.NIN_KEYSELECT)
                {
                    // A double click delivers a second select; it would close the popup
                    // the first one just opened.
                    var now = Environment.TickCount64;
                    if (now - _lastClickTicks > Native.GetDoubleClickTime())
                    {
                        _lastClickTicks = now;
                        Click?.Invoke();
                    }
                }
                else if (ev == Native.WM_MBUTTONUP) MiddleClick?.Invoke();
                else if (ev == Native.WM_CONTEXTMENU) ContextMenuRequested?.Invoke();
                return IntPtr.Zero;
            }
            if (msg == Native.WM_HOTKEY && wParam.ToInt64() == HotkeyId)
            {
                HotkeyPressed?.Invoke();
                return IntPtr.Zero;
            }
            if (msg == WM_SHOW_POPUP)
            {
                ShowRequested?.Invoke();
                return IntPtr.Zero;
            }
            if (_taskbarCreated != 0 && msg == _taskbarCreated)
            {
                Log.Write("taskbar recreated; adding the icon back");
                _added = false;
                Apply();
                return IntPtr.Zero;
            }
            if (msg == Native.WM_SETTINGCHANGE)
            {
                // Light/dark taskbar switches arrive as "ImmersiveColorSet".
                var area = lParam != IntPtr.Zero ? Marshal.PtrToStringUni(lParam) : null;
                if (area == "ImmersiveColorSet") AppearanceChanged?.Invoke();
            }
            else if (msg == Native.WM_DISPLAYCHANGE)
            {
                AppearanceChanged?.Invoke();
            }
        }
        catch (Exception ex)
        {
            Log.Write($"error in the tray window: {ex}");
        }
        return Native.DefWindowProcW(hWnd, msg, wParam, lParam);
    }

    /// <summary>Called by a second launch: asks the running instance to open its popup.</summary>
    public static bool SignalRunningInstance()
    {
        var hwnd = Native.FindWindowW(WindowClass, null);
        if (hwnd == IntPtr.Zero) return false;
        // The new process has the foreground (the user just launched it); hand that
        // right over, or the popup would open behind whatever window is active.
        Native.GetWindowThreadProcessId(hwnd, out var pid);
        Native.AllowSetForegroundWindow(pid);
        return Native.PostMessageW(hwnd, WM_SHOW_POPUP, IntPtr.Zero, IntPtr.Zero);
    }

    private static string Clamp(string? text, int max)
    {
        text ??= "";
        return text.Length <= max ? text : text[..(max - 1)] + "…";
    }

    public void Dispose()
    {
        if (_added)
        {
            var data = NewData();
            Native.Shell_NotifyIconW(Native.NIM_DELETE, ref data);
            _added = false;
        }
        UnregisterHotkey();
        if (_icon != IntPtr.Zero) Native.DestroyIcon(_icon);
        _icon = IntPtr.Zero;
        Native.DestroyWindow(_hwnd);
    }
}
