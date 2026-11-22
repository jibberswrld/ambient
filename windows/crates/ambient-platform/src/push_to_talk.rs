use serde::{Deserialize, Serialize};

#[derive(Debug, Clone, Copy, Default, PartialEq, Eq, Serialize, Deserialize)]
#[serde(rename_all = "camelCase")]
pub enum PushToTalkShortcut {
    #[default]
    ControlAlt,
    ControlWindows,
    ControlShift,
}

#[derive(Debug, Clone, Copy, PartialEq, Eq)]
pub enum ShortcutTransition {
    Pressed,
    Released,
}

pub struct PushToTalkMonitor {
    #[cfg(windows)]
    worker: Option<hook::HookWorker>,
}

impl PushToTalkMonitor {
    pub fn start(
        shortcut: PushToTalkShortcut,
        on_transition: impl Fn(ShortcutTransition) + Send + Sync + 'static,
    ) -> Result<Self, String> {
        #[cfg(windows)]
        {
            Ok(Self {
                worker: Some(hook::HookWorker::start(shortcut, on_transition)?),
            })
        }
        #[cfg(not(windows))]
        {
            let _ = (shortcut, on_transition);
            Ok(Self {})
        }
    }

    pub fn set_shortcut(&mut self, shortcut: PushToTalkShortcut) {
        #[cfg(windows)]
        if let Some(worker) = &self.worker {
            worker.set_shortcut(shortcut);
        }
        #[cfg(not(windows))]
        let _ = shortcut;
    }

    pub fn stop(&mut self) {
        #[cfg(windows)]
        if let Some(worker) = self.worker.take() {
            worker.stop();
        }
    }
}

impl Drop for PushToTalkMonitor {
    fn drop(&mut self) {
        self.stop();
    }
}

#[cfg(any(windows, test))]
mod state {
    use super::{PushToTalkShortcut, ShortcutTransition};

    // Windows virtual-key values distinguish both sides, so releasing one side
    // does not cancel a modifier still held on the other side.
    const LEFT_SHIFT: u32 = 0xA0;
    const RIGHT_SHIFT: u32 = 0xA1;
    const LEFT_CONTROL: u32 = 0xA2;
    const RIGHT_CONTROL: u32 = 0xA3;
    const LEFT_ALT: u32 = 0xA4;
    const RIGHT_ALT: u32 = 0xA5;
    const LEFT_WINDOWS: u32 = 0x5B;
    const RIGHT_WINDOWS: u32 = 0x5C;

    pub(super) struct ShortcutState {
        pub shortcut: PushToTalkShortcut,
        pub(super) held: [bool; 8],
        pub(super) pending_press: bool,
        is_pressed: bool,
        pub(super) alt_gr_is_held: bool,
        previous_event: Option<(u32, bool, u32)>,
    }

    impl ShortcutState {
        pub fn new(shortcut: PushToTalkShortcut) -> Self {
            Self {
                shortcut,
                held: [false; 8],
                pending_press: false,
                is_pressed: false,
                alt_gr_is_held: false,
                previous_event: None,
            }
        }

        pub fn event(
            &mut self,
            virtual_key: u32,
            is_down: bool,
            timestamp: u32,
        ) -> Option<ShortcutTransition> {
            let previous_event = self
                .previous_event
                .replace((virtual_key, is_down, timestamp));
            let modifier_index = match virtual_key {
                LEFT_CONTROL => 0,
                RIGHT_CONTROL => 1,
                LEFT_ALT => 2,
                RIGHT_ALT => 3,
                LEFT_WINDOWS => 4,
                RIGHT_WINDOWS => 5,
                LEFT_SHIFT => 6,
                RIGHT_SHIFT => 7,
                // The Swift monitor observes ordinary keys but ignores their
                // transitions, including keys pressed during an existing hold.
                _ => return self.flush_pending_press(),
            };
            let was_down = self.held[modifier_index];
            if virtual_key == RIGHT_ALT && is_down && !self.held[3] {
                // AltGr's synthetic LeftCtrl and RightAlt have the same
                // Windows timestamp. Do not briefly start dictation for it.
                self.alt_gr_is_held |= previous_event == Some((LEFT_CONTROL, true, timestamp));
            }
            self.held[modifier_index] = is_down;
            // Both release orders occur across keyboard drivers. Keep ignoring
            // the synthetic Control until the entire AltGr pair is up.
            if !self.held[0] && !self.held[3] {
                self.alt_gr_is_held = false;
            }
            let control = self.held[0] || self.held[1];
            let alt = self.held[2] || self.held[3];
            let windows = self.held[4] || self.held[5];
            let shift = self.held[6] || self.held[7];
            let matches_shortcut = match self.shortcut {
                PushToTalkShortcut::ControlAlt => control && alt && !windows && !shift,
                PushToTalkShortcut::ControlWindows => control && windows && !alt && !shift,
                PushToTalkShortcut::ControlShift => control && shift && !alt && !windows,
            };
            let is_pressed = matches_shortcut && !self.alt_gr_is_held;
            if !is_pressed {
                self.pending_press = false;
            }
            if is_pressed == self.is_pressed {
                return None;
            }
            if is_pressed && virtual_key == LEFT_CONTROL && is_down && !was_down {
                // Control can be AltGr's synthetic prefix even when another
                // modifier was held first. Allow RightAlt to cancel this press
                // before publishing it to the recorder.
                self.pending_press = true;
                return None;
            }
            self.pending_press = false;
            self.is_pressed = is_pressed;
            Some(if is_pressed {
                ShortcutTransition::Pressed
            } else {
                ShortcutTransition::Released
            })
        }

        pub fn flush_pending_press(&mut self) -> Option<ShortcutTransition> {
            if !self.pending_press {
                return None;
            }
            self.pending_press = false;
            self.is_pressed = true;
            Some(ShortcutTransition::Pressed)
        }
    }
}

#[cfg(windows)]
mod hook {
    use super::{state::ShortcutState, PushToTalkShortcut, ShortcutTransition};
    use std::{
        cell::{Cell, RefCell},
        sync::{mpsc, Arc, Mutex},
        thread,
    };
    use windows::Win32::{
        Foundation::{LPARAM, LRESULT, WPARAM},
        System::{LibraryLoader::GetModuleHandleW, Threading::GetCurrentThreadId},
        UI::{
            Input::KeyboardAndMouse::GetAsyncKeyState,
            WindowsAndMessaging::{
                CallNextHookEx, GetMessageW, KillTimer, PeekMessageW, PostThreadMessageW, SetTimer,
                SetWindowsHookExW, UnhookWindowsHookEx, KBDLLHOOKSTRUCT, MSG, PM_NOREMOVE,
                WH_KEYBOARD_LL, WM_KEYDOWN, WM_KEYUP, WM_QUIT, WM_SYSKEYDOWN, WM_SYSKEYUP,
                WM_TIMER,
            },
        },
    };

    struct HookContext {
        state: Arc<Mutex<ShortcutState>>,
        on_transition: Box<dyn Fn(ShortcutTransition) + Send + Sync>,
        pending_timer: Cell<Option<usize>>,
    }

    impl HookContext {
        fn update_pending_timer(&self, pending_press: bool) {
            if !pending_press {
                if let Some(timer) = self.pending_timer.take() {
                    unsafe {
                        let _ = KillTimer(None, timer);
                    }
                }
            } else if self.pending_timer.get().is_none() {
                let timer = unsafe { SetTimer(None, 0, 10, None) };
                if timer != 0 {
                    self.pending_timer.set(Some(timer));
                }
            }
        }

        fn emit(&self, transition: Option<ShortcutTransition>) {
            if let Some(transition) = transition {
                let _ = std::panic::catch_unwind(std::panic::AssertUnwindSafe(|| {
                    (self.on_transition)(transition);
                }));
            }
        }
    }

    impl Drop for HookContext {
        fn drop(&mut self) {
            self.update_pending_timer(false);
        }
    }
    thread_local! {
        static CONTEXT: RefCell<Option<HookContext>> = const { RefCell::new(None) };
    }

    unsafe extern "system" fn keyboard_hook(code: i32, message: WPARAM, data: LPARAM) -> LRESULT {
        if code >= 0 {
            // Rust panics must never unwind into Windows' hook dispatcher.
            let _ = std::panic::catch_unwind(|| {
                let message = message.0 as u32;
                if matches!(message, WM_KEYDOWN | WM_KEYUP | WM_SYSKEYDOWN | WM_SYSKEYUP) {
                    let event = unsafe { &*(data.0 as *const KBDLLHOOKSTRUCT) };
                    CONTEXT.with(|context| {
                        if let Some(context) = context.borrow().as_ref() {
                            let (transition, pending_press) = {
                                let mut state = context.state.lock().unwrap();
                                let transition = state.event(
                                    event.vkCode,
                                    matches!(message, WM_KEYDOWN | WM_SYSKEYDOWN),
                                    event.time,
                                );
                                (transition, state.pending_press)
                            };
                            context.update_pending_timer(pending_press);
                            context.emit(transition);
                        }
                    });
                }
            });
        }
        unsafe { CallNextHookEx(None, code, message, data) }
    }

    pub(super) struct HookWorker {
        state: Arc<Mutex<ShortcutState>>,
        thread_id: u32,
        thread: thread::JoinHandle<()>,
    }

    impl HookWorker {
        pub fn start(
            shortcut: PushToTalkShortcut,
            on_transition: impl Fn(ShortcutTransition) + Send + Sync + 'static,
        ) -> Result<Self, String> {
            let state = Arc::new(Mutex::new(ShortcutState::new(shortcut)));
            let hook_state = state.clone();
            let (ready_sender, ready_receiver) = mpsc::sync_channel(1);
            let thread = thread::Builder::new()
                .name("ambient-shortcut".into())
                .spawn(move || {
                    {
                        let mut state = hook_state.lock().unwrap();
                        state.held = [0xA2, 0xA3, 0xA4, 0xA5, 0x5B, 0x5C, 0xA0, 0xA1]
                            .map(|virtual_key| unsafe { GetAsyncKeyState(virtual_key) < 0 });
                        state.alt_gr_is_held = state.held[0] && state.held[3];
                    }
                    CONTEXT.with(|context| {
                        *context.borrow_mut() = Some(HookContext {
                            state: hook_state,
                            on_transition: Box::new(on_transition),
                            pending_timer: Cell::new(None),
                        });
                    });
                    let result = (|| unsafe {
                        let module = GetModuleHandleW(None).map_err(|error| error.to_string())?;
                        let hook = SetWindowsHookExW(
                            WH_KEYBOARD_LL,
                            Some(keyboard_hook),
                            Some(module.into()),
                            0,
                        )
                        .map_err(|error| error.to_string())?;
                        let mut message = MSG::default();
                        // Create the queue before exposing its ID to stop().
                        let _ = PeekMessageW(&mut message, None, 0, 0, PM_NOREMOVE);
                        let _ = ready_sender.send(Ok(GetCurrentThreadId()));
                        while GetMessageW(&mut message, None, 0, 0).0 > 0 {
                            if message.message == WM_TIMER {
                                CONTEXT.with(|context| {
                                    if let Some(context) = context.borrow().as_ref() {
                                        if context.pending_timer.get() == Some(message.wParam.0) {
                                            context.update_pending_timer(false);
                                            let transition =
                                                context.state.lock().unwrap().flush_pending_press();
                                            context.emit(transition);
                                        }
                                    }
                                });
                            }
                        }
                        let _ = UnhookWindowsHookEx(hook);
                        Ok::<(), String>(())
                    })();
                    if let Err(error) = result {
                        let _ = ready_sender.send(Err(error));
                    }
                    CONTEXT.with(|context| *context.borrow_mut() = None);
                })
                .map_err(|error| error.to_string())?;
            match ready_receiver.recv() {
                Ok(Ok(thread_id)) => Ok(Self {
                    state,
                    thread_id,
                    thread,
                }),
                result => {
                    let _ = thread.join();
                    Err(match result {
                        Ok(Err(error)) => error,
                        _ => "The global shortcut monitor could not start.".into(),
                    })
                }
            }
        }

        pub fn set_shortcut(&self, shortcut: PushToTalkShortcut) {
            // Like Swift, a new selection is evaluated on the next modifier event.
            let mut state = self.state.lock().unwrap();
            state.shortcut = shortcut;
            state.pending_press = false;
        }

        pub fn stop(self) {
            unsafe {
                let _ = PostThreadMessageW(self.thread_id, WM_QUIT, WPARAM(0), LPARAM(0));
            }
            if self.thread.thread().id() != thread::current().id() {
                let _ = self.thread.join();
            }
        }
    }
}

#[cfg(test)]
mod tests {
    use super::{state::ShortcutState, *};

    #[test]
    fn shortcut_names_and_default_match_settings() {
        for (shortcut, name) in [
            (PushToTalkShortcut::ControlAlt, "controlAlt"),
            (PushToTalkShortcut::ControlWindows, "controlWindows"),
            (PushToTalkShortcut::ControlShift, "controlShift"),
        ] {
            assert_eq!(
                serde_json::to_string(&shortcut).unwrap(),
                format!("\"{name}\"")
            );
            assert_eq!(
                serde_json::from_str::<PushToTalkShortcut>(&format!("\"{name}\"")).unwrap(),
                shortcut
            );
        }
        assert_eq!(
            PushToTalkShortcut::default(),
            PushToTalkShortcut::ControlAlt
        );
    }

    #[test]
    fn each_shortcut_requires_exact_modifiers_and_releases_either_key() {
        for (shortcut, second_key, extra_key) in [
            (PushToTalkShortcut::ControlAlt, 0xA4, 0xA0),
            (PushToTalkShortcut::ControlWindows, 0x5B, 0xA4),
            (PushToTalkShortcut::ControlShift, 0xA0, 0x5B),
        ] {
            for released_key in [0xA2, second_key] {
                let mut state = ShortcutState::new(shortcut);
                assert_eq!(state.event(0xA2, true, 1), None);
                assert_eq!(
                    state.event(second_key, true, 2),
                    Some(ShortcutTransition::Pressed)
                );
                assert_eq!(state.event(second_key, true, 3), None);
                assert_eq!(
                    state.event(extra_key, true, 4),
                    Some(ShortcutTransition::Released)
                );
                assert_eq!(
                    state.event(extra_key, false, 5),
                    Some(ShortcutTransition::Pressed)
                );
                assert_eq!(
                    state.event(released_key, false, 6),
                    Some(ShortcutTransition::Released)
                );
                assert_eq!(state.event(released_key, false, 7), None);
            }
        }
    }

    #[test]
    fn ordinary_keys_do_not_interrupt_a_hold() {
        let mut state = ShortcutState::new(PushToTalkShortcut::ControlAlt);
        state.event(0xA2, true, 1);
        assert_eq!(
            state.event(0xA4, true, 2),
            Some(ShortcutTransition::Pressed)
        );
        assert_eq!(state.event(0x41, true, 3), None);
        assert_eq!(state.event(0x41, false, 4), None);
        assert_eq!(
            state.event(0xA2, false, 5),
            Some(ShortcutTransition::Released)
        );
    }

    #[test]
    fn both_sides_of_a_modifier_are_tracked() {
        let mut state = ShortcutState::new(PushToTalkShortcut::ControlWindows);
        state.event(0xA2, true, 1);
        state.event(0xA3, true, 2);
        assert_eq!(
            state.event(0x5C, true, 3),
            Some(ShortcutTransition::Pressed)
        );
        assert_eq!(state.event(0xA2, false, 4), None);
        assert_eq!(
            state.event(0xA3, false, 5),
            Some(ShortcutTransition::Released)
        );
    }

    #[test]
    fn alt_gr_never_presses_but_deliberate_control_right_alt_does() {
        let mut state = ShortcutState::new(PushToTalkShortcut::ControlAlt);
        assert_eq!(state.event(0xA2, true, 10), None);
        assert_eq!(state.event(0xA5, true, 10), None);
        assert_eq!(state.event(0x41, true, 11), None);
        assert_eq!(state.event(0xA5, false, 12), None);
        state.event(0xA2, false, 12);
        state.event(0xA2, true, 20);
        assert_eq!(
            state.event(0xA5, true, 25),
            Some(ShortcutTransition::Pressed)
        );
    }

    #[test]
    fn alt_gr_with_another_modifier_held_never_briefly_presses() {
        for (shortcut, first_key) in [
            (PushToTalkShortcut::ControlAlt, 0xA4),
            (PushToTalkShortcut::ControlShift, 0xA0),
            (PushToTalkShortcut::ControlWindows, 0x5B),
        ] {
            for released_keys in [[0xA2, 0xA5], [0xA5, 0xA2]] {
                let mut state = ShortcutState::new(shortcut);
                assert_eq!(state.event(first_key, true, 1), None);
                assert_eq!(state.event(0xA2, true, 10), None);
                assert_eq!(state.event(0xA5, true, 10), None);
                assert_eq!(state.flush_pending_press(), None);
                assert_eq!(state.event(released_keys[0], false, 20), None);
                assert_eq!(state.event(released_keys[1], false, 20), None);
                assert_eq!(state.flush_pending_press(), None);
            }
        }
    }

    #[test]
    fn control_pressed_second_is_published_after_alt_gr_lookahead() {
        let mut state = ShortcutState::new(PushToTalkShortcut::ControlShift);
        state.event(0xA1, true, 1);
        assert_eq!(state.event(0xA2, true, 2), None);
        assert_eq!(
            state.flush_pending_press(),
            Some(ShortcutTransition::Pressed)
        );
        assert_eq!(state.flush_pending_press(), None);
        assert_eq!(
            state.event(0xA2, false, 3),
            Some(ShortcutTransition::Released)
        );
    }

    #[test]
    fn changing_shortcut_takes_effect_at_next_modifier_event() {
        let mut state = ShortcutState::new(PushToTalkShortcut::ControlAlt);
        state.event(0xA2, true, 1);
        state.event(0xA4, true, 2);
        state.shortcut = PushToTalkShortcut::ControlShift;
        assert_eq!(
            state.event(0xA4, false, 3),
            Some(ShortcutTransition::Released)
        );
        assert_eq!(
            state.event(0xA1, true, 4),
            Some(ShortcutTransition::Pressed)
        );
    }

    #[cfg(not(windows))]
    #[test]
    fn developer_monitor_is_a_no_op() {
        let mut monitor = PushToTalkMonitor::start(PushToTalkShortcut::default(), |_| {
            panic!("The non-Windows monitor must not emit transitions")
        })
        .unwrap();
        monitor.set_shortcut(PushToTalkShortcut::ControlShift);
        monitor.stop();
        monitor.stop();
    }
}
