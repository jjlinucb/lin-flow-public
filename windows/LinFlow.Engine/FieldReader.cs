using System.Runtime.InteropServices;

namespace LinFlow.Engine;

/// Reads the text of the field another app has focused, through UI Automation. The Windows half
/// of the Mac's Accessibility reads in PasteWatcher.swift (focusedTextElement, usable, value),
/// used by the app's readback and by `linflow-cli focus-test`.
///
/// It reads one focused element and never the screen. A password field is never read, whatever
/// is in it: UI Automation marks those with IsPassword, as Accessibility marks them with the
/// AXSecureTextField subrole.
///
/// The calls go straight through the COM vtables. WinForms has no UI Automation client, WPF's
/// managed one (System.Windows.Automation) is the older UIA2 that sees less of Chromium, and a
/// generated interop assembly needs tlbimp, which a build on the Mac does not have. The class
/// and interface ids and every slot number below were read out of the type library inside
/// C:\Windows\System32\UIAutomationCore.dll on 2026-09-23 (IUnknown is slots 0 to 2) by
/// scripts/probes/uia-slots.ps1. Run it again before adding a call here: a wrong slot calls a
/// different function, and nothing at compile time can catch it.
///
/// Everything here must run on one thread, which must be MTA: UI Automation clients are not
/// meant to run on a thread that owns windows, and the objects are only ever used on the thread
/// that made them.
public sealed unsafe class FieldReader
{
    private static readonly Guid ClsidCUIAutomation8 = new("e22ad333-b25f-460c-83d0-0581107395c9");
    private static readonly Guid ClsidCUIAutomation = new("ff48dba4-60ef-4201-aa87-54103eef594e");
    private static readonly Guid IidIUIAutomation = new("30cbe57d-d9d0-452a-ab13-7ac5ac4825ee");
    private static readonly Guid IidIUIAutomation2 = new("34723aff-0c9d-49d0-9896-7ab52df8cd8a");
    private static readonly Guid IidValuePattern = new("a94cd8b1-0844-4cd6-9d2d-640537ab39e9");
    private static readonly Guid IidTextPattern = new("32eba289-3583-42c9-9c59-3b6d9a1e9b6a");

    // IUIAutomation
    private const int SlotElementFromHandle = 6;
    private const int SlotGetFocusedElement = 8;
    // IUIAutomation2
    private const int SlotPutConnectionTimeout = 61;
    private const int SlotPutTransactionTimeout = 63;
    // IUIAutomationElement
    private const int SlotGetCurrentPatternAs = 14;
    private const int SlotCurrentProcessId = 20;
    private const int SlotCurrentControlType = 21;
    private const int SlotCurrentClassName = 30;
    private const int SlotCurrentIsPassword = 35;
    private const int SlotCurrentFrameworkId = 40;
    // IUIAutomationValuePattern, IUIAutomationTextPattern, IUIAutomationTextRange
    private const int SlotValueCurrentValue = 4;
    private const int SlotTextDocumentRange = 7;
    private const int SlotRangeGetText = 12;

    private const int ValuePatternId = 10002;
    private const int TextPatternId = 10014;
    private const int UiaTimeout = unchecked((int)0x80131505);   // UIA_E_TIMEOUT

    /// The longest field worth reading. The Mac's cap, and a long email thread is well under it.
    public const int MaxLength = 200_000;

    /// How long one read may take before it gives up. UI Automation's own default is seconds,
    /// and a busy app can use all of them; the Mac settled on half a second for the same reason.
    public const int TimeoutMs = 500;

    private readonly IntPtr _automation;

    /// Reads that hit TimeoutMs, for the log. Touched only on the reader's thread.
    public int Timeouts { get; private set; }

    private FieldReader(IntPtr automation) => _automation = automation;

    /// Null, with the reason, when UI Automation cannot be had on this thread.
    public static FieldReader? TryCreate(out string? why)
    {
        why = null;
        // S_FALSE when this thread already has the MTA, which is fine; an STA thread is not.
        var init = CoInitializeEx(IntPtr.Zero, CoinitMultithreaded);
        if (init < 0)
        {
            why = $"COM would not start on this thread (0x{init:X8})";
            return null;
        }
        // CUIAutomation8 is Windows 8 and later; the older class is the same interface.
        IntPtr automation;
        var hr = CoCreateInstance(ClsidCUIAutomation8, IntPtr.Zero, ClsctxInprocServer, IidIUIAutomation, out automation);
        if (hr < 0) hr = CoCreateInstance(ClsidCUIAutomation, IntPtr.Zero, ClsctxInprocServer, IidIUIAutomation, out automation);
        if (hr < 0 || automation == IntPtr.Zero)
        {
            why = $"UI Automation is not available (0x{hr:X8})";
            return null;
        }
        if (QueryInterface(automation, IidIUIAutomation2, out var two) >= 0)
        {
            var put = (delegate* unmanaged<IntPtr, uint, int>)Slot(two, SlotPutConnectionTimeout);
            put(two, TimeoutMs);
            put = (delegate* unmanaged<IntPtr, uint, int>)Slot(two, SlotPutTransactionTimeout);
            put(two, TimeoutMs);
            Marshal.Release(two);
        }
        return new FieldReader(automation);
    }

    /// One element, held until disposed.
    public sealed class Field : IDisposable
    {
        internal IntPtr Ptr;
        internal Field(IntPtr ptr) => Ptr = ptr;

        public void Dispose()
        {
            if (Ptr == IntPtr.Zero) return;
            Marshal.Release(Ptr);
            Ptr = IntPtr.Zero;
        }
    }

    /// The element with the keyboard focus, anywhere on this desktop, unless it is a password field.
    public Field? Focused()
    {
        IntPtr element;
        var hr = ((delegate* unmanaged<IntPtr, IntPtr*, int>)Slot(_automation, SlotGetFocusedElement))(_automation, &element);
        return Usable(hr, element);
    }

    /// The element for one window handle. What the probe uses, where no field of its own can
    /// have the real keyboard focus.
    public Field? FromHandle(IntPtr hwnd)
    {
        IntPtr element;
        var hr = ((delegate* unmanaged<IntPtr, IntPtr, IntPtr*, int>)Slot(_automation, SlotElementFromHandle))(_automation, hwnd, &element);
        return Usable(hr, element);
    }

    /// Anything but a password field.
    private Field? Usable(int hr, IntPtr element)
    {
        Count(hr);
        if (hr < 0 || element == IntPtr.Zero) return null;
        var field = new Field(element);
        int password;
        hr = ((delegate* unmanaged<IntPtr, int*, int>)Slot(element, SlotCurrentIsPassword))(element, &password);
        Count(hr);
        // Unknown is treated as a password: never read a field that would not say what it is.
        if (hr < 0 || password != 0)
        {
            field.Dispose();
            return null;
        }
        return field;
    }

    public int? ProcessId(Field field)
    {
        int pid;
        var hr = ((delegate* unmanaged<IntPtr, int*, int>)Slot(field.Ptr, SlotCurrentProcessId))(field.Ptr, &pid);
        Count(hr);
        return hr < 0 ? null : pid;
    }

    /// The field's text, if it has any and it is a sane size to work with. Null means it could
    /// not be read, which is different from "" - an empty field is a real reading, and it is
    /// what a composer looks like the moment its message is sent.
    ///
    /// A value first, as the Mac reads AXValue: edit boxes, browser text fields and most
    /// composers have one. Then the document text, for what has no value at all - Word, and the
    /// Outlook message body, which is Word. A value that comes back empty gets the second look
    /// too, in case the text lives in the document instead.
    public string? Text(Field field)
    {
        var value = ReadValue(field);
        if (!string.IsNullOrEmpty(value)) return value.Length <= MaxLength ? value : null;
        var document = ReadDocument(field);
        if (document is not null) return document.Length <= MaxLength ? document : null;
        return value;
    }

    private string? ReadValue(Field field)
    {
        var pattern = Pattern(field, ValuePatternId, IidValuePattern);
        if (pattern == IntPtr.Zero) return null;
        try
        {
            IntPtr bstr;
            var hr = ((delegate* unmanaged<IntPtr, IntPtr*, int>)Slot(pattern, SlotValueCurrentValue))(pattern, &bstr);
            Count(hr);
            return hr < 0 ? null : TakeString(bstr);
        }
        finally { Marshal.Release(pattern); }
    }

    private string? ReadDocument(Field field)
    {
        var pattern = Pattern(field, TextPatternId, IidTextPattern);
        if (pattern == IntPtr.Zero) return null;
        IntPtr range = IntPtr.Zero;
        try
        {
            var hr = ((delegate* unmanaged<IntPtr, IntPtr*, int>)Slot(pattern, SlotTextDocumentRange))(pattern, &range);
            Count(hr);
            if (hr < 0 || range == IntPtr.Zero) return null;
            IntPtr bstr;
            // One past the cap, so a document that is over it says so rather than being cut to fit.
            hr = ((delegate* unmanaged<IntPtr, int, IntPtr*, int>)Slot(range, SlotRangeGetText))(range, MaxLength + 1, &bstr);
            Count(hr);
            return hr < 0 ? null : TakeString(bstr);
        }
        finally
        {
            if (range != IntPtr.Zero) Marshal.Release(range);
            Marshal.Release(pattern);
        }
    }

    /// What kind of element it is, for focus-test and the log: the control type, the UI
    /// framework behind it ("Chrome", "Win32", "WPF", "DirectUI"...) and its window class.
    public string Describe(Field field)
    {
        int type;
        var hr = ((delegate* unmanaged<IntPtr, int*, int>)Slot(field.Ptr, SlotCurrentControlType))(field.Ptr, &type);
        Count(hr);
        var framework = ReadString(field, SlotCurrentFrameworkId);
        var className = ReadString(field, SlotCurrentClassName);
        var kind = hr < 0 ? "?" : ControlTypeName(type);
        return $"{kind}, framework {(string.IsNullOrEmpty(framework) ? "?" : framework)}, class {(string.IsNullOrEmpty(className) ? "?" : className)}";
    }

    private string? ReadString(Field field, int slot)
    {
        IntPtr bstr;
        var hr = ((delegate* unmanaged<IntPtr, IntPtr*, int>)Slot(field.Ptr, slot))(field.Ptr, &bstr);
        Count(hr);
        return hr < 0 ? null : TakeString(bstr);
    }

    private static string ControlTypeName(int id) => id switch
    {
        50004 => "Edit",
        50030 => "Document",
        50033 => "Pane",
        50026 => "Group",
        50032 => "Window",
        50020 => "Text",
        50025 => "Custom",
        50003 => "ComboBox",
        _ => $"control type {id}",
    };

    /// The pattern as the interface asked for, or zero when the element does not have it.
    /// GetCurrentPatternAs answers S_OK with nothing for a pattern the element lacks.
    private IntPtr Pattern(Field field, int patternId, Guid iid)
    {
        IntPtr pattern;
        var hr = ((delegate* unmanaged<IntPtr, int, Guid*, IntPtr*, int>)Slot(field.Ptr, SlotGetCurrentPatternAs))(field.Ptr, patternId, &iid, &pattern);
        Count(hr);
        return hr < 0 ? IntPtr.Zero : pattern;
    }

    private void Count(int hr)
    {
        if (hr == UiaTimeout) Timeouts++;
    }

    private static string? TakeString(IntPtr bstr)
    {
        if (bstr == IntPtr.Zero) return "";
        try { return Marshal.PtrToStringBSTR(bstr); }
        finally { Marshal.FreeBSTR(bstr); }
    }

    private static IntPtr Slot(IntPtr self, int slot) => (*(IntPtr**)self)[slot];

    private static int QueryInterface(IntPtr self, Guid iid, out IntPtr result)
    {
        IntPtr found;
        var hr = ((delegate* unmanaged<IntPtr, Guid*, IntPtr*, int>)Slot(self, 0))(self, &iid, &found);
        result = hr < 0 ? IntPtr.Zero : found;
        return hr;
    }

    /// The app that owns the window in front, which is the one a paste goes to.
    public static (int Pid, string Name) ForegroundApp()
    {
        var window = GetForegroundWindow();
        if (window == IntPtr.Zero) return (0, "");
        GetWindowThreadProcessId(window, out var pid);
        try
        {
            using var process = System.Diagnostics.Process.GetProcessById((int)pid);
            return ((int)pid, process.ProcessName);
        }
        catch
        {
            return ((int)pid, "?");
        }
    }

    [DllImport("user32.dll")]
    private static extern IntPtr GetForegroundWindow();

    [DllImport("user32.dll")]
    private static extern uint GetWindowThreadProcessId(IntPtr hWnd, out uint processId);

    private const uint CoinitMultithreaded = 0x0;
    private const uint ClsctxInprocServer = 0x1;

    [DllImport("ole32.dll")]
    private static extern int CoInitializeEx(IntPtr reserved, uint coInit);

    [DllImport("ole32.dll")]
    private static extern int CoCreateInstance(in Guid clsid, IntPtr outer, uint context, in Guid iid, out IntPtr result);
}
