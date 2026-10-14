using System.Runtime.InteropServices;
using System.Windows.Forms;
using LinFlow.Core;

namespace LinFlow.App;

/// Puts text into the focused field by way of the clipboard and a synthetic Ctrl+V, then puts
/// the clipboard back. Ported from TextInjector.swift, which does the same with Cmd+V.
///
/// Typing the text with SendInput character by character sounds cleaner and is not: it is slow
/// for a long dictation, it loses characters in apps that throttle input, and it breaks entirely
/// on anything with an IME. Every dictation tool does the clipboard dance.
public static class Paste
{
    [StructLayout(LayoutKind.Sequential)]
    private struct INPUT
    {
        public uint type;
        public InputUnion u;
    }

    [StructLayout(LayoutKind.Explicit)]
    private struct InputUnion
    {
        [FieldOffset(0)] public KEYBDINPUT ki;
        [FieldOffset(0)] public MOUSEINPUT mi;
        [FieldOffset(0)] public HARDWAREINPUT hi;
    }

    [StructLayout(LayoutKind.Sequential)]
    private struct KEYBDINPUT
    {
        public ushort wVk;
        public ushort wScan;
        public uint dwFlags;
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

    [StructLayout(LayoutKind.Sequential)]
    private struct HARDWAREINPUT
    {
        public uint uMsg;
        public ushort wParamL, wParamH;
    }

    private const uint INPUT_KEYBOARD = 1;
    private const uint KEYEVENTF_KEYUP = 0x0002;
    private const ushort VK_CONTROL = 0x11;
    private const ushort VK_V = 0x56;

    [DllImport("user32.dll", SetLastError = true)]
    private static extern uint SendInput(uint nInputs, INPUT[] pInputs, int cbSize);

    [DllImport("user32.dll")]
    private static extern uint GetClipboardSequenceNumber();

    [DllImport("user32.dll")]
    private static extern short GetAsyncKeyState(int vKey);

    /// Sets the clipboard, sends Ctrl+V, and restores the previous text after a moment - but
    /// only if nothing else has touched the clipboard meanwhile. GetClipboardSequenceNumber is
    /// the Windows answer to NSPasteboard.changeCount, which the Mac checks for the same reason:
    /// clobbering something the user copied in between would be much worse than losing a restore.
    public static void Send(string text)
    {
        if (string.IsNullOrEmpty(text)) return;
        OnSta(() => SendCore(text));
    }

    /// Runs clipboard work on an STA thread, because every System.Windows.Forms.Clipboard call
    /// throws ThreadStateException off one.
    ///
    /// Main() is [STAThread], but that sets the apartment of the UI thread alone. Hotkey.Fire
    /// hands Pressed and Released to ThreadPool.QueueUserWorkItem, whose threads are MTA, and
    /// nothing marshals back -- so every clipboard call here threw, was caught, was logged, and
    /// the dictation silently never arrived. No crash, no paste, on every dictation. Found by a
    /// sweep before this ever ran on Windows; it would have been the first thing John hit.
    private static void OnSta(Action work)
    {
        if (Thread.CurrentThread.GetApartmentState() == ApartmentState.STA) { work(); return; }
        var thread = new Thread(() =>
        {
            try { work(); }
            catch (Exception e) { Log.Info($"paste: {e.Message}"); }
        });
        thread.SetApartmentState(ApartmentState.STA);
        thread.IsBackground = true;
        thread.Start();
        // Joined: the caller is a hook-dispatch pool thread with nothing else to do, and the
        // 400ms restore below is fire-and-forget, so this returns promptly.
        thread.Join();
    }

    /// Puts the dictation on the clipboard marked as something not to keep.
    ///
    /// It is there for 0.4 s so Ctrl+V can find it, and then it is taken away again - but as
    /// ordinary content it was free to be retained on the way past. Windows Clipboard History
    /// (Win+V) keeps the last 25 entries, Cloud Clipboard syncs them to every machine John is
    /// signed into, and any third-party clipboard manager takes everything. So every dictation,
    /// including anything he says into a password field's neighbour or a private message, would
    /// sit in a list he never opened. Neither feature is on by default, but both are one click
    /// away in Settings, and the fix has to already be in place when that click happens.
    ///
    /// The three formats below are how Windows is asked to skip an entry - the same intent as
    /// the Mac's currentHostOnly plus the nspasteboard.org transient markers (e48a5cc).
    /// `ExcludeClipboardContentFromMonitorProcessing` is the one most clipboard managers honour;
    /// the other two are what the shell itself reads, as DWORD 0. Each needs to be a stream:
    /// a custom format set from a plain int is serialized, and nothing reading it expects that.
    ///
    /// John's own clipboard goes back unmarked, because it is his and was never ours to label.
    private static void SetTransient(string text)
    {
        var data = new DataObject();
        data.SetText(text);
        data.SetData("ExcludeClipboardContentFromMonitorProcessing", new MemoryStream(new byte[] { 0 }));
        data.SetData("CanIncludeInClipboardHistory", new MemoryStream(BitConverter.GetBytes(0)));
        data.SetData("CanUploadToCloudClipboard", new MemoryStream(BitConverter.GetBytes(0)));
        // copy: true renders everything onto the clipboard now, so it survives this process
        // releasing the data object - which it does immediately, well before the paste lands.
        Clipboard.SetDataObject(data, copy: true);
    }

    private static void SendCore(string text)
    {
        string? previous = null;
        try
        {
            if (Clipboard.ContainsText()) previous = Clipboard.GetText();
        }
        catch (Exception e)
        {
            Log.Info($"could not read the clipboard: {e.Message}");
        }

        try
        {
            SetTransient(text);
        }
        catch (Exception e)
        {
            // Another process can hold the clipboard open; one retry is usually enough.
            Log.Info($"clipboard busy ({e.Message}), retrying once");
            Thread.Sleep(60);
            try { SetTransient(text); }
            catch (Exception e2) { Log.Info($"paste abandoned: {e2.Message}"); return; }
        }

        var afterSet = GetClipboardSequenceNumber();
        ReleasePhysicalModifiers();
        SendCtrlV();

        if (previous is null) return;
        // Give the target app time to actually take the paste before taking the text back.
        var restore = previous;
        Task.Delay(400).ContinueWith(_ =>
        {
            if (GetClipboardSequenceNumber() != afterSet) return;   // someone else copied; leave it
            // A continuation runs on the pool, so this needs the STA hop just as much as the set.
            OnSta(() =>
            {
                try { Clipboard.SetText(restore); } catch { /* not worth a second failure */ }
            });
        });
    }

    /// If the user is still physically holding the hotkey when we paste - and with hold-to-talk
    /// they often are, because key-up is what triggers this - a stuck Ctrl turns our Ctrl+V into
    /// something else entirely. Send key-ups for the modifiers first.
    private static void ReleasePhysicalModifiers()
    {
        foreach (var vk in new ushort[] { VK_CONTROL, 0xA2, 0xA3, 0x12, 0xA4, 0xA5, 0x10, 0xA0, 0xA1 })
        {
            if ((GetAsyncKeyState(vk) & 0x8000) == 0) continue;
            SendInput(1, new[] { KeyInput(vk, up: true) }, Marshal.SizeOf<INPUT>());
        }
    }

    private static void SendCtrlV()
    {
        var inputs = new[]
        {
            KeyInput(VK_CONTROL, up: false),
            KeyInput(VK_V, up: false),
            KeyInput(VK_V, up: true),
            KeyInput(VK_CONTROL, up: true),
        };
        var sent = SendInput((uint)inputs.Length, inputs, Marshal.SizeOf<INPUT>());
        if (sent != inputs.Length)
            Log.Info($"SendInput sent {sent} of {inputs.Length} events (error {Marshal.GetLastWin32Error()})");
    }

    private static INPUT KeyInput(ushort vk, bool up) => new()
    {
        type = INPUT_KEYBOARD,
        u = new InputUnion { ki = new KEYBDINPUT { wVk = vk, dwFlags = up ? KEYEVENTF_KEYUP : 0 } },
    };
}
