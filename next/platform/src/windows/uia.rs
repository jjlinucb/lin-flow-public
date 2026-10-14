//! Reads the text of the field another app has focused, through UI Automation: the Windows half
//! of the Mac's Accessibility reads. One focused element, never the screen, and never a password
//! field, whatever is in it.
//!
//! UI Automation clients belong on an MTA thread that owns no windows, and its objects stay on
//! the thread that made them, so a `FieldReader` is made and used on the readback's own thread.

use std::cell::Cell;
use windows::core::{Interface, HRESULT};
use windows::Win32::System::Com::{CoCreateInstance, CoInitializeEx, CLSCTX_INPROC_SERVER, COINIT_MULTITHREADED};
use windows::Win32::UI::Accessibility::{CUIAutomation, CUIAutomation8, IUIAutomation, IUIAutomation2, IUIAutomationElement, IUIAutomationTextPattern, IUIAutomationValuePattern, UIA_TextPatternId, UIA_ValuePatternId};

/// The longest field worth reading: the Mac's cap, and a long email thread is well under it.
pub const MAX_LENGTH: usize = 200_000;
/// How long one read may take. UI Automation's own default is seconds, and a busy app can use
/// all of them; the Mac settled on half a second for the same reason.
pub const TIMEOUT_MS: u32 = 500;
const UIA_E_TIMEOUT: HRESULT = HRESULT(0x8013_1505_u32 as i32);

/// One focused element, held so the readback can keep reading the field it anchored on.
pub struct Field(IUIAutomationElement);

pub struct FieldReader {
    automation: IUIAutomation,
    timeouts: Cell<usize>,
}

/// Field text in the form the dictation was written in. A Win32 edit box stores a new line as
/// "\r\n" and Word as a bare "\r" (a line break as "\v"), and a web composer can turn a space
/// into a non-breaking one. Left alone, the field never contains a two-line dictation.
pub fn normalize(field: &str) -> String {
    field.replace("\r\n", "\n").replace(['\r', '\u{0B}'], "\n").replace('\u{A0}', " ")
}

impl FieldReader {
    pub fn new() -> Result<FieldReader, String> {
        unsafe {
            // S_FALSE when this thread already has the MTA, which is fine; an STA thread is not.
            let hr = CoInitializeEx(None, COINIT_MULTITHREADED);
            if hr.is_err() {
                return Err(format!("COM would not start on this thread ({hr:?})"));
            }
            let automation: IUIAutomation = CoCreateInstance(&CUIAutomation8, None, CLSCTX_INPROC_SERVER)
                .or_else(|_| CoCreateInstance(&CUIAutomation, None, CLSCTX_INPROC_SERVER))
                .map_err(|e| format!("UI Automation is not available ({e})"))?;
            if let Ok(two) = automation.cast::<IUIAutomation2>() {
                let _ = two.SetConnectionTimeout(TIMEOUT_MS);
                let _ = two.SetTransactionTimeout(TIMEOUT_MS);
            }
            Ok(FieldReader { automation, timeouts: Cell::new(0) })
        }
    }

    fn count<T>(&self, r: windows::core::Result<T>) -> Option<T> {
        match r {
            Ok(v) => Some(v),
            Err(e) => {
                if e.code() == UIA_E_TIMEOUT {
                    self.timeouts.set(self.timeouts.get() + 1);
                }
                None
            }
        }
    }

    /// The element with the keyboard focus, anywhere on this desktop, unless it is a password
    /// field or one of Lin Flow's own: a fix typed into its own window is not a correction.
    pub fn focused(&self, _pid: u32) -> Option<Field> {
        let element = self.count(unsafe { self.automation.GetFocusedElement() })?;
        // Unknown counts as a password: never read a field that would not say what it is.
        let password = self.count(unsafe { element.CurrentIsPassword() }).map(|b| b.as_bool()).unwrap_or(true);
        if password {
            return None;
        }
        let pid = self.count(unsafe { element.CurrentProcessId() })?;
        if pid as u32 == std::process::id() {
            return None;
        }
        Some(Field(element))
    }

    /// The field's text, if it has any and it is a sane size. None means it could not be read,
    /// which is different from "": an empty field is a real reading, and it is what a composer
    /// looks like the moment its message is sent.
    ///
    /// A value first, as the Mac reads AXValue: edit boxes, browser fields and most composers
    /// have one. Then the document text, for what has none: Word, and the Outlook message body.
    pub fn text(&self, field: &Field) -> Option<String> {
        let fits = |s: &String| s.chars().count() <= MAX_LENGTH;
        let value = self.value(field);
        if let Some(v) = value.as_ref().filter(|v| !v.is_empty()) {
            return fits(v).then(|| normalize(v));
        }
        if let Some(d) = self.document(field) {
            return fits(&d).then(|| normalize(&d));
        }
        value.map(|v| normalize(&v))
    }

    fn value(&self, field: &Field) -> Option<String> {
        let pattern: IUIAutomationValuePattern = self.count(unsafe { field.0.GetCurrentPatternAs(UIA_ValuePatternId) })?;
        self.count(unsafe { pattern.CurrentValue() }).map(|b| b.to_string())
    }

    fn document(&self, field: &Field) -> Option<String> {
        let pattern: IUIAutomationTextPattern = self.count(unsafe { field.0.GetCurrentPatternAs(UIA_TextPatternId) })?;
        let range = self.count(unsafe { pattern.DocumentRange() })?;
        // One past the cap, so a document over it says so rather than being cut to fit.
        self.count(unsafe { range.GetText(MAX_LENGTH as i32 + 1) }).map(|b| b.to_string())
    }

    /// Chromium and Electron build their accessibility tree only once something asks, and not at
    /// once, so the readback asks at the paste and the tree is there by the first look.
    pub fn prime(&self, pid: u32) {
        drop(self.focused(pid));
    }

    pub fn timeouts(&self) -> usize {
        self.timeouts.get()
    }
}
