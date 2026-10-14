using System.Collections.Concurrent;
using System.Linq;
using System.Diagnostics;
using System.Runtime.InteropServices;
using LinFlow.Core;

namespace LinFlow.App;

/// Hold-to-talk on a single key, through a low-level keyboard hook.
///
/// RegisterHotKey cannot do this: it fires on a chord press, not on hold-and-release of one bare
/// key, which is the whole interaction. So WH_KEYBOARD_LL it is.
///
/// The key comes from settings.json, defaulting to Left Ctrl + Left Alt. It is deliberately not the Mac's Fn:
/// Fn is handled in keyboard firmware on nearly every laptop and never reaches a Windows hook at
/// all, so binding it would simply never fire. See HotkeySettings for why the default is a chord
/// and why it moved off Right Ctrl and then Right Alt.
///
/// The middle, Back and Forward mouse buttons can be the key as well, alone or in a chord with
/// keys (2026-09-25). A mouse button never reaches the keyboard hook, so WH_MOUSE_LL watches it, on
/// a HookThread of its own. That hook swallows the button, so holding it to talk does not also
/// open a link or start autoscroll in the window under the pointer, and it hands a quick click back
/// as a real one (HotkeySettings.ClickLimit). What the button gives up is dragging with it held.
///
/// The callback must return immediately. Windows silently removes a hook whose callback is slow,
/// and the symptom is dictation that works for a while and then quietly stops - so the callback
/// does nothing but hand the event to a worker thread.
public sealed class Hotkey : IDisposable
{
    private const int WH_KEYBOARD_LL = 13;
    private const int WM_KEYDOWN = 0x0100, WM_KEYUP = 0x0101;
    private const int WM_SYSKEYDOWN = 0x0104, WM_SYSKEYUP = 0x0105;

    public const int VK_RCONTROL = VirtualKeys.RightControl;
    public const int VK_RMENU = VirtualKeys.RightAlt;      // Right Alt
    public const int VK_RSHIFT = VirtualKeys.RightShift;
    public const int VK_APPS = VirtualKeys.Menu;       // the menu key

    private delegate IntPtr HookProc(int nCode, IntPtr wParam, IntPtr lParam);

    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr SetWindowsHookEx(int idHook, HookProc lpfn, IntPtr hMod, uint dwThreadId);
    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool UnhookWindowsHookEx(IntPtr hhk);
    [DllImport("user32.dll")]
    private static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr GetModuleHandle(string? lpModuleName);

    [StructLayout(LayoutKind.Sequential)]
    private struct KBDLLHOOKSTRUCT
    {
        public uint vkCode;
        public uint scanCode;
        public uint flags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    private IntPtr _hook;
    private readonly HookProc _proc;      // kept alive deliberately: if this is collected the hook crashes
    private readonly HookThread.HookProc _mouseProc;   // the same, for the mouse hook
    private HookThread? _mouseHook;
    // When each mouse button went down and whether this hook swallowed that press, indexed from the
    // middle button (0x04), then Back and Forward. Touched only on the mouse hook's thread.
    private readonly long[] _buttonDownAt = new long[3];
    private readonly bool[] _buttonSwallowed = new bool[3];
    private readonly int[] _keys;
    private readonly HashSet<int> _held = new();
    private readonly object _gate = new(); // the two hooks run on different threads and share _held and _down
    private bool _down;

    public event Action? Pressed;
    public event Action? Released;

    /// When the chord completed, as a `Stopwatch.GetTimestamp()` value, so a take can measure
    /// the whole wait from the key rather than from whenever its handler got a thread.
    public static long PressedAt { get; private set; }

    public Hotkey(int[]? keys = null)
    {
        _keys = keys is { Length: > 0 } ? keys : HotkeySettings.Default;
        _proc = Callback;
        _mouseProc = MouseCallback;
        var buttons = _keys.Where(HotkeySettings.IsMouseButton).ToArray();
        if (buttons.Length < _keys.Length)
        {
            using var module = Process.GetCurrentProcess().MainModule!;
            _hook = SetWindowsHookEx(WH_KEYBOARD_LL, _proc, GetModuleHandle(module.ModuleName), 0);
            if (_hook == IntPtr.Zero)
                throw new InvalidOperationException(
                    $"could not install the keyboard hook (error {Marshal.GetLastWin32Error()})");
        }
        if (buttons.Length > 0)
        {
            try { _mouseHook = new HookThread("linflow-mouse-hook", (HookThread.WH_MOUSE_LL, _mouseProc)); }
            catch { Dispose(); throw; }
        }
        Log.Info($"hotkey hook running on {HotkeySettings.NameOf(_keys)} " +
                 $"(virtual key{(_keys.Length > 1 ? "s" : "")} " +
                 string.Join(", ", _keys.Select(k => $"0x{k:X2}")) + ")" +
                 (buttons.Length > 0 ? $", {HotkeySettings.NameOf(buttons)} through a mouse hook" : ""));
    }

    private IntPtr Callback(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode >= 0)
        {
            var data = Marshal.PtrToStructure<KBDLLHOOKSTRUCT>(lParam);
            var vk = (int)data.vkCode;
            if (Array.IndexOf(_keys, vk) >= 0)
            {
                var msg = (int)wParam;
                if (msg is WM_KEYDOWN or WM_SYSKEYDOWN) Down(vk);
                else if (msg is WM_KEYUP or WM_SYSKEYUP) Up(vk);
            }
        }
        // Always pass the key through. The Mac swallows Fn to keep the emoji picker shut;
        // swallowing a real modifier here would break Ctrl for every other app.
        return CallNextHookEx(_hook, nCode, wParam, lParam);
    }

    /// The mouse buttons' half of the hotkey. This runs for every move of the pointer, so
    /// anything that is not one of the hotkey's buttons goes straight on after a comparison.
    private IntPtr MouseCallback(int nCode, IntPtr wParam, IntPtr lParam)
    {
        var msg = (int)wParam;
        var vk = nCode >= 0 ? HotkeyMouse.ButtonOf(msg, lParam) : 0;
        if (vk != 0 && Array.IndexOf(_keys, vk) >= 0 && !HotkeyMouse.IsOwnClick(lParam))
        {
            var i = vk - VirtualKeys.MiddleMouse;
            if (HotkeyMouse.IsDown(msg))
            {
                _buttonDownAt[i] = Stopwatch.GetTimestamp();
                _buttonSwallowed[i] = true;
                Down(vk);
                return (IntPtr)1;
            }
            // An up whose down this hook never saw - the button was held through a rebind - goes
            // on, or the window that got the down would wait for its up forever.
            if (_buttonSwallowed[i])
            {
                _buttonSwallowed[i] = false;
                Up(vk);
                if (HotkeySettings.IsClick(Stopwatch.GetElapsedTime(_buttonDownAt[i])))
                    ThreadPool.QueueUserWorkItem(_ => HotkeyMouse.Click(vk));
                return (IntPtr)1;
            }
        }
        return HookThread.Next(nCode, wParam, lParam);
    }

    /// A key or button of the hotkey went down. Held keys repeat, so this runs over and over while
    /// a key is down: _held is a set and _down guards the edge, so only the moment the last key of
    /// the chord arrives starts a recording.
    private void Down(int vk)
    {
        lock (_gate)
        {
            _held.Add(vk);
            if (_down || _held.Count != _keys.Length) return;
            // Stamped here, in the hook, rather than in the handler: Fire queues to a
            // worker, and the point of the measurement is everything after the key -
            // including that hop. Two reads of a counter is well inside the budget a
            // low-level hook has before Windows removes it.
            PressedAt = Stopwatch.GetTimestamp();
            _down = true;
            Fire(Pressed);
        }
    }

    /// Releasing any one key ends the dictation. Waiting for all of them would mean
    /// the recording ran on while the user let go a finger at a time.
    private void Up(int vk)
    {
        lock (_gate)
        {
            _held.Remove(vk);
            if (_down) { _down = false; Fire(Released); }
        }
    }

    /// Off this thread at once - see the note on the class - but in order, and one at a time.
    ///
    /// Pressed and Released used to go to the thread pool as two independent work items, which
    /// guarantees neither ordering nor exclusivity. On a quick tap the two handlers could run
    /// concurrently, and when Released reached the recorder before Start() had finished, the
    /// recording that Pressed then started was never stopped: microphone open and the dot red
    /// until the next tap. One worker and one queue make every press run to completion before
    /// its own release is handled.
    private static readonly BlockingCollection<Action> Queue = new();

    static Hotkey()
    {
        new Thread(() =>
        {
            foreach (var work in Queue.GetConsumingEnumerable())
            {
                try { work(); }
                catch (Exception e) { Log.Info($"hotkey handler threw: {e}"); }
            }
        })
        { IsBackground = true, Name = "linflow-hotkey" }.Start();
    }

    private static void Fire(Action? handler)
    {
        if (handler is null) return;
        Queue.Add(handler);
    }

    public void Dispose()
    {
        if (_hook != IntPtr.Zero)
        {
            UnhookWindowsHookEx(_hook);
            _hook = IntPtr.Zero;
        }
        _mouseHook?.Dispose();
        _mouseHook = null;
    }
}
