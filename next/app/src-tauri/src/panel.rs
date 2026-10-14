//! The pill and the toasts float above every app and must never take focus: dictation pastes
//! into whatever app is in front, and a click on the pill that brought Lin Flow forward would
//! send the paste to Lin Flow instead. On the Mac that takes a non-activating panel, as the
//! Swift app's pill was; on Windows, WS_EX_NOACTIVATE.

use tauri::WebviewWindow;

#[cfg(target_os = "macos")]
mod imp {
    use objc2::runtime::{AnyClass, AnyObject, Bool, ClassBuilder, Sel};
    use objc2::{msg_send, sel};
    use std::ffi::c_void;
    use std::sync::OnceLock;
    use tauri::WebviewWindow;

    extern "C" {
        fn object_setClass(obj: *mut AnyObject, cls: *const AnyClass) -> *const AnyClass;
        fn class_getInstanceSize(cls: *const AnyClass) -> usize;
        fn object_getClass(obj: *const AnyObject) -> *const AnyClass;
    }

    const NON_ACTIVATING_PANEL: usize = 1 << 7;
    const STATUS_WINDOW_LEVEL: isize = 25;
    // canJoinAllSpaces, stationary, ignoresCycle, fullScreenAuxiliary
    const BEHAVIOR: usize = 1 << 0 | 1 << 4 | 1 << 6 | 1 << 8;

    extern "C" fn no(_this: &AnyObject, _sel: Sel) -> Bool {
        Bool::NO
    }

    /// An NSPanel that never becomes key or main. It carries tao's one instance variable, so
    /// tao's own window code still finds it after the class changes.
    fn panel_class() -> Option<&'static AnyClass> {
        static CLASS: OnceLock<Option<usize>> = OnceLock::new();
        let ptr = CLASS.get_or_init(|| {
            let superclass = AnyClass::get(c"NSPanel")?;
            let mut builder = ClassBuilder::new(c"LinFlowNextPanel", superclass)?;
            unsafe {
                builder.add_method(sel!(canBecomeKeyWindow), no as extern "C" fn(_, _) -> _);
                builder.add_method(sel!(canBecomeMainWindow), no as extern "C" fn(_, _) -> _);
            }
            builder.add_ivar::<Bool>(c"focusable");
            Some(builder.register() as *const AnyClass as usize)
        });
        ptr.map(|p| unsafe { &*(p as *const AnyClass) })
    }

    fn ns(window: &WebviewWindow) -> Option<*mut AnyObject> {
        window.ns_window().ok().map(|p: *mut c_void| p as *mut AnyObject)
    }

    pub fn make_floating(window: &WebviewWindow) {
        let Some(obj) = ns(window) else { return };
        let Some(panel) = panel_class() else { return };
        unsafe {
            // Only when the panel class is no larger than the window it replaces: an instance
            // cannot grow in place.
            let current = object_getClass(obj);
            if class_getInstanceSize(panel) <= class_getInstanceSize(current) {
                object_setClass(obj, panel);
                let mask: usize = msg_send![obj, styleMask];
                let _: () = msg_send![obj, setStyleMask: mask | NON_ACTIVATING_PANEL];
                let _: () = msg_send![obj, setFloatingPanel: true];
                let _: () = msg_send![obj, setBecomesKeyOnlyIfNeeded: true];
            } else {
                log::warn!("pill: the panel class does not fit; the pill lets clicks through instead");
                let _: () = msg_send![obj, setIgnoresMouseEvents: true];
            }
            let _: () = msg_send![obj, setHidesOnDeactivate: false];
            let _: () = msg_send![obj, setLevel: STATUS_WINDOW_LEVEL];
            let _: () = msg_send![obj, setCollectionBehavior: BEHAVIOR];
        }
    }

    pub fn show(window: &WebviewWindow) {
        if let Some(obj) = ns(window) {
            let _: () = unsafe { msg_send![obj, orderFrontRegardless] };
        }
    }

    pub fn hide(window: &WebviewWindow) {
        if let Some(obj) = ns(window) {
            let _: () = unsafe { msg_send![obj, orderOut: std::ptr::null::<AnyObject>()] };
        }
    }
}

#[cfg(windows)]
mod imp {
    use tauri::WebviewWindow;
    use windows::Win32::Foundation::HWND;
    use windows::Win32::UI::WindowsAndMessaging::{
        GetWindowLongPtrW, SetWindowLongPtrW, SetWindowPos, ShowWindow, GWL_EXSTYLE, HWND_TOPMOST, SWP_NOACTIVATE, SWP_NOMOVE, SWP_NOSIZE, SW_HIDE, SW_SHOWNOACTIVATE, WS_EX_NOACTIVATE, WS_EX_TOOLWINDOW,
    };

    fn hwnd(window: &WebviewWindow) -> Option<HWND> {
        window.hwnd().ok().map(|h| HWND(h.0 as _))
    }

    pub fn make_floating(window: &WebviewWindow) {
        let Some(h) = hwnd(window) else { return };
        unsafe {
            let ex = GetWindowLongPtrW(h, GWL_EXSTYLE);
            SetWindowLongPtrW(h, GWL_EXSTYLE, ex | WS_EX_NOACTIVATE.0 as isize | WS_EX_TOOLWINDOW.0 as isize);
        }
    }

    pub fn show(window: &WebviewWindow) {
        let Some(h) = hwnd(window) else { return };
        unsafe {
            let _ = ShowWindow(h, SW_SHOWNOACTIVATE);
            let _ = SetWindowPos(h, Some(HWND_TOPMOST), 0, 0, 0, 0, SWP_NOMOVE | SWP_NOSIZE | SWP_NOACTIVATE);
        }
    }

    pub fn hide(window: &WebviewWindow) {
        if let Some(h) = hwnd(window) {
            unsafe {
                let _ = ShowWindow(h, SW_HIDE);
            }
        }
    }
}

#[cfg(not(any(target_os = "macos", windows)))]
mod imp {
    use tauri::WebviewWindow;
    pub fn make_floating(_window: &WebviewWindow) {}
    pub fn show(window: &WebviewWindow) {
        let _ = window.show();
    }
    pub fn hide(window: &WebviewWindow) {
        let _ = window.hide();
    }
}

/// Turns a window into a floating panel that never takes focus.
pub fn make_floating(window: &WebviewWindow) {
    imp::make_floating(window)
}

/// Shows it without bringing Lin Flow forward.
pub fn show(window: &WebviewWindow) {
    imp::show(window)
}

pub fn hide(window: &WebviewWindow) {
    imp::hide(window)
}
