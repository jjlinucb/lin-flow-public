using System.Runtime.InteropServices;
using LinFlow.Core;

namespace LinFlow.App;

/// Records a talk key for Settings: whatever keys and mouse buttons are pressed together next.
///
/// It reads low-level hooks rather than the window's key events, so it records exactly the codes
/// Hotkey will listen for - Left Ctrl, not just Ctrl - and a mouse button anywhere on the screen.
/// While it records, those keys and buttons go nowhere else, so a key pressed to be recorded does
/// not also type into the window or open a menu. The left and right buttons still click, so
/// Cancel can be pressed. Escape on its own calls it off, and so do 15 seconds without a chord.
internal sealed class HotkeyCapture : IDisposable
{
    private const int WM_KEYDOWN = 0x0100, WM_KEYUP = 0x0101;
    private const int WM_SYSKEYDOWN = 0x0104, WM_SYSKEYUP = 0x0105;

    private readonly ChordRecorder _chord = new();
    private readonly HookThread.HookProc _keyboard, _mouse;   // kept alive deliberately: a collected delegate crashes the hook
    private readonly HookThread _hooks;
    private readonly System.Threading.Timer? _timeout;
    private readonly Action<int[]?> _finished;
    private int _over;   // 1 once it has finished or been disposed, so it reports at most once

    /// `finished` is called once, on a pool thread, with the chord, or with null if it was called
    /// off. It is not called at all after Dispose.
    public HotkeyCapture(Action<int[]?> finished)
    {
        _finished = finished;
        _keyboard = KeyboardCallback;
        _mouse = MouseCallback;
        _hooks = new HookThread("linflow-hotkey-capture",
            (HookThread.WH_KEYBOARD_LL, _keyboard), (HookThread.WH_MOUSE_LL, _mouse));
        _timeout = new System.Threading.Timer(_ => Finish(null), null, TimeSpan.FromSeconds(15), Timeout.InfiniteTimeSpan);
    }

    private IntPtr KeyboardCallback(int nCode, IntPtr wParam, IntPtr lParam)
    {
        if (nCode < 0) return HookThread.Next(nCode, wParam, lParam);
        var vk = Marshal.ReadInt32(lParam);   // KBDLLHOOKSTRUCT.vkCode, its first field
        var msg = (int)wParam;
        if (msg is WM_KEYDOWN or WM_SYSKEYDOWN) Feed(vk, down: true);
        else if (msg is WM_KEYUP or WM_SYSKEYUP) Feed(vk, down: false);
        return (IntPtr)1;   // recorded, not typed
    }

    private IntPtr MouseCallback(int nCode, IntPtr wParam, IntPtr lParam)
    {
        var msg = (int)wParam;
        var vk = nCode >= 0 ? HotkeyMouse.ButtonOf(msg, lParam) : 0;
        // Moves, the wheel and the left and right buttons go on as usual, so Cancel can be clicked.
        if (vk == 0 || HotkeyMouse.IsOwnClick(lParam)) return HookThread.Next(nCode, wParam, lParam);
        Feed(vk, HotkeyMouse.IsDown(msg));
        return (IntPtr)1;
    }

    private void Feed(int vk, bool down)
    {
        int[]? result;
        lock (_chord)
        {
            if (_chord.Done) return;
            if (down) _chord.Down(vk); else _chord.Up(vk);
            if (!_chord.Done) return;
            result = _chord.Result;
        }
        // Off the hook's thread: finishing takes the hooks out, which cannot happen from inside one.
        ThreadPool.QueueUserWorkItem(_ => Finish(result));
    }

    private void Finish(int[]? chord)
    {
        if (Interlocked.Exchange(ref _over, 1) == 1) return;
        Stop();
        _finished(chord);
    }

    /// Calls it off without reporting anything, when Settings cancels it itself.
    public void Dispose()
    {
        Interlocked.Exchange(ref _over, 1);
        Stop();
    }

    private void Stop()
    {
        _timeout?.Dispose();
        _hooks.Dispose();
    }
}
