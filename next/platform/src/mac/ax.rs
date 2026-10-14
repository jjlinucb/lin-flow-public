//! Reading the focused text field through Accessibility, for the readback of hand edits. Uses
//! the grant the talk key already needs, and reads only the one focused element, never the
//! screen. Native apps report their focused text element; Chromium and Electron build their
//! tree only once asked, so they are asked the way a screen reader does.

use core_foundation::base::{CFType, TCFType};
use core_foundation::boolean::CFBoolean;
use core_foundation::dictionary::CFDictionary;
use core_foundation::string::{CFString, CFStringRef};
use core_foundation_sys::base::{CFGetTypeID, CFRelease, CFTypeRef};
use objc2_app_kit::{NSRunningApplication, NSWorkspace};
use std::ffi::c_void;
use std::sync::atomic::{AtomicUsize, Ordering};
use std::sync::Once;

type AXUIElementRef = *mut c_void;
type AXError = i32;
const AX_SUCCESS: AXError = 0;
const AX_CANNOT_COMPLETE: AXError = -25204;

#[link(name = "ApplicationServices", kind = "framework")]
extern "C" {
    fn AXIsProcessTrustedWithOptions(options: *const c_void) -> bool;
    fn AXIsProcessTrusted() -> bool;
    static kAXTrustedCheckOptionPrompt: CFStringRef;
    fn AXUIElementCreateSystemWide() -> AXUIElementRef;
    fn AXUIElementCreateApplication(pid: i32) -> AXUIElementRef;
    fn AXUIElementCopyAttributeValue(element: AXUIElementRef, attribute: CFStringRef, value: *mut CFTypeRef) -> AXError;
    fn AXUIElementSetAttributeValue(element: AXUIElementRef, attribute: CFStringRef, value: CFTypeRef) -> AXError;
    fn AXUIElementSetMessagingTimeout(element: AXUIElementRef, seconds: f32) -> AXError;
    fn AXUIElementGetTypeID() -> usize;
}

/// How long one Accessibility read may take before it gives up. The default is six seconds,
/// and a busy app can use all of it.
pub const MESSAGING_TIMEOUT: f32 = 0.5;
static TIMEOUT_SET: Once = Once::new();
/// Reads that ran out of time, for the log.
pub static TIMEOUTS: AtomicUsize = AtomicUsize::new(0);

/// Whether this process is trusted for Accessibility. `prompt` shows the system dialog, and puts
/// the app in the list, when it is not.
pub fn trusted(prompt: bool) -> bool {
    if !prompt {
        return unsafe { AXIsProcessTrusted() };
    }
    let key = unsafe { CFString::wrap_under_get_rule(kAXTrustedCheckOptionPrompt) };
    let options = CFDictionary::from_CFType_pairs(&[(key.as_CFType(), CFBoolean::true_value().as_CFType())]);
    unsafe { AXIsProcessTrustedWithOptions(options.as_concrete_TypeRef() as *const c_void) }
}

/// One Accessibility element, released when dropped.
pub struct Element(AXUIElementRef);

unsafe impl Send for Element {}

impl Drop for Element {
    fn drop(&mut self) {
        if !self.0.is_null() {
            unsafe { CFRelease(self.0 as CFTypeRef) };
        }
    }
}

fn set_timeout() {
    TIMEOUT_SET.call_once(|| unsafe {
        let system = AXUIElementCreateSystemWide();
        AXUIElementSetMessagingTimeout(system, MESSAGING_TIMEOUT);
        CFRelease(system as CFTypeRef);
    });
}

fn copy(element: AXUIElementRef, attribute: &str) -> Option<CFType> {
    let name = CFString::new(attribute);
    let mut value: CFTypeRef = std::ptr::null();
    let err = unsafe { AXUIElementCopyAttributeValue(element, name.as_concrete_TypeRef(), &mut value) };
    if err == AX_CANNOT_COMPLETE {
        TIMEOUTS.fetch_add(1, Ordering::Relaxed);
    }
    if err != AX_SUCCESS || value.is_null() {
        return None;
    }
    Some(unsafe { CFType::wrap_under_create_rule(value) })
}

fn copy_element(element: AXUIElementRef, attribute: &str) -> Option<Element> {
    let v = copy(element, attribute)?;
    if unsafe { CFGetTypeID(v.as_CFTypeRef()) } != unsafe { AXUIElementGetTypeID() } {
        return None;
    }
    let raw = v.as_CFTypeRef() as AXUIElementRef;
    std::mem::forget(v);
    Some(Element(raw))
}

/// Chrome and the browsers built on it, which take their accessibility switch from Chrome.
pub fn is_chromium_browser(bundle_id: Option<&str>) -> bool {
    let Some(id) = bundle_id.map(str::to_lowercase) else { return false };
    ["com.google.chrome", "org.chromium.chromium", "com.microsoft.edgemac", "com.brave.browser", "company.thebrowser.browser", "com.vivaldi.vivaldi", "com.operasoftware.opera"]
        .iter()
        .any(|b| id == *b || id.starts_with(&format!("{b}.")))
}

/// Switches a Chromium or Electron app's accessibility tree on. AXManualAccessibility is
/// Electron's documented switch and every other app ignores it. AXEnhancedUserInterface changes
/// how AppKit windows behave while it is on, so only Chrome, which honours nothing else, gets it.
pub fn prime(pid: i32) {
    set_timeout();
    unsafe {
        let app = AXUIElementCreateApplication(pid);
        let on = CFBoolean::true_value();
        AXUIElementSetAttributeValue(app, CFString::new("AXManualAccessibility").as_concrete_TypeRef(), on.as_CFTypeRef());
        if is_chromium_browser(bundle_id_of(pid).as_deref()) {
            AXUIElementSetAttributeValue(app, CFString::new("AXEnhancedUserInterface").as_concrete_TypeRef(), on.as_CFTypeRef());
        }
        CFRelease(app as CFTypeRef);
    }
}

/// Anything but a password field. A secure field is never read back, whatever is in it.
fn usable(e: Element) -> Option<Element> {
    if let Some(sub) = copy(e.0, "AXSubrole") {
        if sub.downcast::<CFString>().map(|s| s.to_string()) == Some("AXSecureTextField".into()) {
            return None;
        }
    }
    Some(e)
}

/// The focused element, system-wide first and then inside `pid`, the app pasted into.
pub fn focused_element(pid: i32) -> Option<Element> {
    set_timeout();
    unsafe {
        let system = AXUIElementCreateSystemWide();
        let found = copy_element(system, "AXFocusedUIElement").or_else(|| {
            prime(pid);
            let app = AXUIElementCreateApplication(pid);
            let e = copy_element(app, "AXFocusedUIElement").or_else(|| copy_element(system, "AXFocusedUIElement"));
            CFRelease(app as CFTypeRef);
            e
        });
        CFRelease(system as CFTypeRef);
        found.and_then(usable)
    }
}

impl Element {
    /// The field's text, if it has any and it is a sane size to work with.
    pub fn value(&self) -> Option<String> {
        let v = copy(self.0, "AXValue")?;
        let s = v.downcast::<CFString>()?.to_string();
        (linflow_core::text::unicode::count(&s) <= 200_000).then_some(s)
    }
}

pub fn bundle_id_of(pid: i32) -> Option<String> {
    let app = NSRunningApplication::runningApplicationWithProcessIdentifier(pid)?;
    app.bundleIdentifier().map(|s| s.to_string())
}

/// The app in front: its pid, bundle id and name.
pub fn frontmost_app() -> Option<(i32, String, String)> {
    let app = NSWorkspace::sharedWorkspace().frontmostApplication()?;
    let pid = app.processIdentifier();
    let id = app.bundleIdentifier().map(|s| s.to_string()).unwrap_or_default();
    let name = app.localizedName().map(|s| s.to_string()).unwrap_or_default();
    Some((pid, id, name))
}
