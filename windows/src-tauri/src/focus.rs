//! The bar's text box borrows keyboard focus and gives it back to the window the person was working in.
#[cfg(windows)]
mod platform {
    use std::sync::atomic::{AtomicIsize, Ordering};
    use windows::Win32::Foundation::HWND;
    use windows::Win32::UI::WindowsAndMessaging::{GetForegroundWindow, IsWindow, SetForegroundWindow};

    static REMEMBERED_FOREGROUND_WINDOW: AtomicIsize = AtomicIsize::new(0);

    pub fn remember_foreground_window() {
        let foreground_window = unsafe { GetForegroundWindow() };
        REMEMBERED_FOREGROUND_WINDOW.store(foreground_window.0 as isize, Ordering::SeqCst);
    }

    pub fn restore_foreground_window() {
        let remembered = REMEMBERED_FOREGROUND_WINDOW.swap(0, Ordering::SeqCst);
        if remembered == 0 {
            return;
        }
        let window = HWND(remembered as *mut core::ffi::c_void);
        unsafe {
            if IsWindow(Some(window)).as_bool() {
                let _ = SetForegroundWindow(window);
            }
        }
    }
}

#[cfg(not(windows))]
mod platform {
    pub fn remember_foreground_window() {}
    pub fn restore_foreground_window() {}
}

pub use platform::{remember_foreground_window, restore_foreground_window};
