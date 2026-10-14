using System.Diagnostics;
using System.Runtime.InteropServices;
using LinFlow.Core;

namespace LinFlow.App;

/// Low-level hooks on a thread with a message loop of its own.
///
/// A low-level hook is called on the thread that installed it, and the input it watches waits
/// for that call. On the UI thread, a busy window - the Dictation list takes 1.4 s to first open -
/// would freeze the pointer for as long, and Windows removes a hook that keeps it waiting too
/// often, which is dictation that quietly stops working. A thread that does nothing but pump
/// messages is never busy.
internal sealed class HookThread : IDisposable
{
    public delegate IntPtr HookProc(int nCode, IntPtr wParam, IntPtr lParam);

    public const int WH_KEYBOARD_LL = 13;
    public const int WH_MOUSE_LL = 14;
    private const uint WM_QUIT = 0x0012;
    private const uint PM_NOREMOVE = 0x0000;

    [DllImport("user32.dll", SetLastError = true)]
    private static extern IntPtr SetWindowsHookEx(int idHook, HookProc lpfn, IntPtr hMod, uint dwThreadId);
    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool UnhookWindowsHookEx(IntPtr hhk);
    [DllImport("user32.dll")]
    private static extern IntPtr CallNextHookEx(IntPtr hhk, int nCode, IntPtr wParam, IntPtr lParam);
    [DllImport("kernel32.dll", CharSet = CharSet.Unicode)]
    private static extern IntPtr GetModuleHandle(string? lpModuleName);
    [DllImport("user32.dll")]
    private static extern int GetMessage(out MSG lpMsg, IntPtr hWnd, uint wMsgFilterMin, uint wMsgFilterMax);
    [DllImport("user32.dll")]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool PeekMessage(out MSG lpMsg, IntPtr hWnd, uint wMsgFilterMin, uint wMsgFilterMax, uint wRemoveMsg);
    [DllImport("user32.dll", SetLastError = true)]
    [return: MarshalAs(UnmanagedType.Bool)]
    private static extern bool PostThreadMessage(uint idThread, uint msg, UIntPtr wParam, IntPtr lParam);
    [DllImport("kernel32.dll")]
    private static extern uint GetCurrentThreadId();

    [StructLayout(LayoutKind.Sequential)]
    private struct MSG
    {
        public IntPtr hwnd;
        public uint message;
        public UIntPtr wParam;
        public IntPtr lParam;
        public uint time;
        public int x, y;
        public uint lPrivate;
    }

    private readonly HookProc[] _procs;   // kept alive deliberately: a collected delegate crashes the hook
    private Thread? _thread;
    private uint _threadId;

    /// Starts the thread and installs every hook on it, or throws if any of them cannot go in.
    public HookThread(string name, params (int Kind, HookProc Proc)[] hooks)
    {
        _procs = hooks.Select(h => h.Proc).ToArray();
        using var ready = new ManualResetEventSlim();
        string? failure = null;
        var thread = new Thread(() =>
        {
            _threadId = GetCurrentThreadId();
            // Makes this thread's message queue now, so Dispose's WM_QUIT has somewhere to land
            // even if it comes before any input does.
            PeekMessage(out _, IntPtr.Zero, 0, 0, PM_NOREMOVE);
            var installed = new List<IntPtr>();
            using (var module = Process.GetCurrentProcess().MainModule!)
            {
                foreach (var (kind, proc) in hooks)
                {
                    var handle = SetWindowsHookEx(kind, proc, GetModuleHandle(module.ModuleName), 0);
                    if (handle == IntPtr.Zero)
                    {
                        failure = $"could not install the {(kind == WH_MOUSE_LL ? "mouse" : "keyboard")} hook " +
                                  $"(error {Marshal.GetLastWin32Error()})";
                        break;
                    }
                    installed.Add(handle);
                }
            }
            ready.Set();
            // The hooks are called from inside GetMessage. Nothing is posted here but WM_QUIT.
            if (failure is null)
                while (GetMessage(out _, IntPtr.Zero, 0, 0) > 0) { }
            foreach (var handle in installed) UnhookWindowsHookEx(handle);
        })
        { IsBackground = true, Name = name };
        thread.Start();
        ready.Wait();
        if (failure is not null)
        {
            thread.Join();
            throw new InvalidOperationException(failure);
        }
        _thread = thread;
    }

    /// Passes an event on down the hook chain. The handle argument has been ignored since
    /// Windows XP, so a callback does not need its own.
    public static IntPtr Next(int nCode, IntPtr wParam, IntPtr lParam) =>
        CallNextHookEx(IntPtr.Zero, nCode, wParam, lParam);

    public void Dispose()
    {
        var thread = Interlocked.Exchange(ref _thread, null);
        if (thread is null) return;
        // The loop ends on WM_QUIT and unhooks on its own thread, the one that made the hooks.
        PostThreadMessage(_threadId, WM_QUIT, UIntPtr.Zero, IntPtr.Zero);
        thread.Join(TimeSpan.FromSeconds(2));
    }
}

/// The mouse buttons a hotkey can use, as the low-level mouse hook reports them, and the click
/// that hands a quick press back.
internal static class HotkeyMouse
{
    private const int WM_MBUTTONDOWN = 0x0207, WM_MBUTTONUP = 0x0208;
    private const int WM_XBUTTONDOWN = 0x020B, WM_XBUTTONUP = 0x020C;
    private const uint INPUT_MOUSE = 0;
    private const uint MOUSEEVENTF_MIDDLEDOWN = 0x0020, MOUSEEVENTF_MIDDLEUP = 0x0040;
    private const uint MOUSEEVENTF_XDOWN = 0x0080, MOUSEEVENTF_XUP = 0x0100;
    private const uint XBUTTON1 = 0x0001, XBUTTON2 = 0x0002;

    /// Stamped on the click Click sends, so the hooks let their own click through rather than
    /// swallowing it again. Everything else counts as the button, injected or not, so a click
    /// arriving from a remote-control or mouse-sharing tool still dictates.
    private static readonly IntPtr ClickMark = (IntPtr)0x4C464D42;   // "LFMB"

    [StructLayout(LayoutKind.Sequential)]
    private struct MSLLHOOKSTRUCT
    {
        public int x, y;
        public uint mouseData;
        public uint flags;
        public uint time;
        public IntPtr dwExtraInfo;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct MOUSEINPUT
    {
        public int dx, dy;
        public uint mouseData, dwFlags, time;
        public IntPtr dwExtraInfo;
    }

    /// SendInput's INPUT with only its mouse member. MOUSEINPUT is the largest member of that
    /// union, so this is the size SendInput checks, the same as Paste's full definition.
    [StructLayout(LayoutKind.Sequential)]
    private struct MouseInput
    {
        public uint type;
        public MOUSEINPUT mi;
    }

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint SendInput(uint nInputs, MouseInput[] pInputs, int cbSize);

    /// The hotkey code for the button a mouse message is about, or 0 for anything else: a move,
    /// the wheel, or the left or right button, which a hotkey can never use. Called for every
    /// move of the pointer, so the common case is one comparison.
    public static int ButtonOf(int msg, IntPtr lParam) => msg switch
    {
        WM_MBUTTONDOWN or WM_MBUTTONUP => VirtualKeys.MiddleMouse,
        WM_XBUTTONDOWN or WM_XBUTTONUP => (Marshal.PtrToStructure<MSLLHOOKSTRUCT>(lParam).mouseData >> 16) switch
        {
            XBUTTON1 => VirtualKeys.MouseBack,
            XBUTTON2 => VirtualKeys.MouseForward,
            _ => 0,
        },
        _ => 0,
    };

    public static bool IsDown(int msg) => msg is WM_MBUTTONDOWN or WM_XBUTTONDOWN;

    /// True for the click Click itself sent.
    public static bool IsOwnClick(IntPtr lParam) =>
        Marshal.PtrToStructure<MSLLHOOKSTRUCT>(lParam).dwExtraInfo == ClickMark;

    /// One click of the button, down and up, at wherever the pointer is. Called from a pool
    /// thread: a hook callback has to return before the input it sends can be seen.
    public static void Click(int vk)
    {
        var (down, up, data) = vk switch
        {
            VirtualKeys.MiddleMouse => (MOUSEEVENTF_MIDDLEDOWN, MOUSEEVENTF_MIDDLEUP, 0u),
            VirtualKeys.MouseBack => (MOUSEEVENTF_XDOWN, MOUSEEVENTF_XUP, XBUTTON1),
            VirtualKeys.MouseForward => (MOUSEEVENTF_XDOWN, MOUSEEVENTF_XUP, XBUTTON2),
            _ => (0u, 0u, 0u),
        };
        if (down == 0) return;
        var click = new[]
        {
            new MouseInput { type = INPUT_MOUSE, mi = new MOUSEINPUT { dwFlags = down, mouseData = data, dwExtraInfo = ClickMark } },
            new MouseInput { type = INPUT_MOUSE, mi = new MOUSEINPUT { dwFlags = up, mouseData = data, dwExtraInfo = ClickMark } },
        };
        if (SendInput((uint)click.Length, click, Marshal.SizeOf<MouseInput>()) != click.Length)
            Log.Info($"could not pass a {HotkeySettings.NameOf(vk)} click on (error {Marshal.GetLastWin32Error()})");
    }
}
