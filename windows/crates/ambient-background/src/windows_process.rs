use super::{ProcessControl, ProcessState};
use std::{
    collections::HashMap,
    fs::File,
    mem::{size_of, size_of_val},
    os::windows::{
        ffi::OsStrExt,
        io::{AsRawHandle, FromRawHandle, OwnedHandle},
    },
    path::Path,
    sync::{Arc, Mutex},
};
use windows::{
    core::{PCWSTR, PWSTR},
    Win32::{
        Foundation::*,
        Security::Authorization::ConvertStringSidToSidW,
        Security::*,
        Storage::FileSystem::*,
        System::{JobObjects::*, Pipes::CreatePipe, Threading::*},
    },
};

fn wide(value: impl AsRef<std::ffi::OsStr>) -> Vec<u16> {
    value.as_ref().encode_wide().chain(Some(0)).collect()
}
fn handle(value: &OwnedHandle) -> HANDLE {
    HANDLE(value.as_raw_handle())
}
unsafe fn owned(value: HANDLE) -> OwnedHandle {
    OwnedHandle::from_raw_handle(value.0)
}
fn failure(error: windows::core::Error) -> String {
    format!("Could not start confined headless process: {error}")
}

pub(super) struct Job(OwnedHandle);
impl Job {
    pub(super) fn terminate(&self) {
        unsafe {
            let _ = TerminateJobObject(handle(&self.0), 1);
        }
    }
}

struct AttributeList {
    _storage: Vec<usize>,
    pointer: LPPROC_THREAD_ATTRIBUTE_LIST,
}
impl Drop for AttributeList {
    fn drop(&mut self) {
        unsafe {
            DeleteProcThreadAttributeList(self.pointer);
        }
    }
}
impl AttributeList {
    unsafe fn new(handles: &[HANDLE]) -> windows::core::Result<Self> {
        let mut bytes = 0;
        let _ = InitializeProcThreadAttributeList(None, 1, None, &mut bytes);
        let mut storage = vec![0usize; bytes.div_ceil(size_of::<usize>())];
        let pointer = LPPROC_THREAD_ATTRIBUTE_LIST(storage.as_mut_ptr().cast());
        InitializeProcThreadAttributeList(Some(pointer), 1, None, &mut bytes)?;
        let attributes = Self {
            _storage: storage,
            pointer,
        };
        UpdateProcThreadAttribute(
            pointer,
            0,
            PROC_THREAD_ATTRIBUTE_HANDLE_LIST as usize,
            Some(handles.as_ptr().cast()),
            size_of_val(handles),
            None,
            None,
        )?;
        Ok(attributes)
    }
}

unsafe fn pipe() -> windows::core::Result<(OwnedHandle, OwnedHandle)> {
    let security = SECURITY_ATTRIBUTES {
        nLength: size_of::<SECURITY_ATTRIBUTES>() as u32,
        bInheritHandle: true.into(),
        ..Default::default()
    };
    let mut read = HANDLE::default();
    let mut write = HANDLE::default();
    CreatePipe(&mut read, &mut write, Some(&security), 0)?;
    let read = owned(read);
    let write = owned(write);
    SetHandleInformation(handle(&read), HANDLE_FLAG_INHERIT.0, HANDLE_FLAGS(0))?;
    Ok((read, write))
}

unsafe fn low_integrity_token() -> windows::core::Result<OwnedHandle> {
    let mut original = HANDLE::default();
    OpenProcessToken(
        GetCurrentProcess(),
        TOKEN_DUPLICATE | TOKEN_QUERY,
        &mut original,
    )?;
    let original = owned(original);
    let mut duplicated = HANDLE::default();
    DuplicateTokenEx(
        handle(&original),
        TOKEN_ALL_ACCESS,
        None,
        SecurityImpersonation,
        TokenPrimary,
        &mut duplicated,
    )?;
    let duplicated = owned(duplicated);
    let mut sid = PSID::default();
    ConvertStringSidToSidW(PCWSTR(wide("S-1-16-4096").as_ptr()), &mut sid)?;
    let label = TOKEN_MANDATORY_LABEL {
        Label: SID_AND_ATTRIBUTES {
            Sid: sid,
            Attributes: windows::Win32::System::SystemServices::SE_GROUP_INTEGRITY as u32,
        },
    };
    let result = SetTokenInformation(
        handle(&duplicated),
        TokenIntegrityLevel,
        (&label as *const TOKEN_MANDATORY_LABEL).cast(),
        size_of::<TOKEN_MANDATORY_LABEL>() as u32 + GetLengthSid(sid),
    );
    let _ = LocalFree(Some(HLOCAL(sid.0)));
    result?;
    Ok(duplicated)
}

// CommandLineToArgvW/MSVC escaping, also used for PowerShell's literal -Command argument.
fn quote_argument(argument: &str) -> String {
    let mut quoted = String::from("\"");
    let mut backslashes = 0;
    for character in argument.chars() {
        if character == '\\' {
            backslashes += 1;
            continue;
        }
        if character == '"' {
            quoted.push_str(&"\\".repeat(backslashes * 2 + 1));
        } else {
            quoted.push_str(&"\\".repeat(backslashes));
        }
        quoted.push(character);
        backslashes = 0;
    }
    quoted.push_str(&"\\".repeat(backslashes * 2));
    quoted.push('"');
    quoted
}

pub(super) fn spawn(
    executable: &Path,
    arguments: &[String],
    directory: &Path,
    environment: &HashMap<String, String>,
    low_integrity: bool,
) -> Result<
    (
        u32,
        Arc<ProcessControl>,
        File,
        File,
        impl FnOnce() -> i32 + Send,
    ),
    String,
> {
    let executable = which::which_in(executable, environment.get("PATH"), directory)
        .map_err(|error| error.to_string())?;
    let extension = executable
        .extension()
        .and_then(|extension| extension.to_str())
        .unwrap_or("");
    let mut environment = environment.clone();
    let (application, command_line) =
        if extension.eq_ignore_ascii_case("cmd") || extension.eq_ignore_ascii_case("bat") {
            // npm shims forward %* to a native executable. A naked batch invocation skips delayed
            // expansion; its final native command expands these placeholders AFTER cmd parses shell
            // syntax. Prompt quotes, %, !, &, and multiline text therefore never become cmd syntax.
            let namespace = format!("AMBIENT_SHIM_{}", uuid::Uuid::new_v4().simple());
            environment.insert(namespace.clone(), executable.to_string_lossy().into_owned());
            let placeholders = arguments
                .iter()
                .enumerate()
                .map(|(index, argument)| {
                    let key = format!("{namespace}_{index}");
                    environment.insert(key.clone(), quote_argument(argument));
                    format!("!{key}!")
                })
                .collect::<Vec<_>>()
                .join(" ");
            let application = std::env::var_os("COMSPEC")
                .map(std::path::PathBuf::from)
                .unwrap_or_else(|| "C:\\Windows\\System32\\cmd.exe".into());
            let line = format!(
                "{} /d /s /v:on /c \"\"%{namespace}%\" {placeholders}\"",
                quote_argument(&application.to_string_lossy())
            );
            (application, line)
        } else {
            let line = std::iter::once(quote_argument(&executable.to_string_lossy()))
                .chain(arguments.iter().map(|argument| quote_argument(argument)))
                .collect::<Vec<_>>()
                .join(" ");
            (executable, line)
        };
    let application = wide(application);
    let mut command_line = wide(command_line);
    let directory = wide(directory);
    let mut environment_entries = environment.iter().collect::<Vec<_>>();
    environment_entries.sort_by_key(|(key, _)| key.to_uppercase());
    let mut environment_block: Vec<u16> = environment_entries
        .iter()
        .flat_map(|(key, value)| wide(format!("{key}={value}")))
        .collect();
    environment_block.push(0);
    unsafe {
        let (stdout_read, stdout_write) = pipe().map_err(failure)?;
        let (stderr_read, stderr_write) = pipe().map_err(failure)?;
        let security = SECURITY_ATTRIBUTES {
            nLength: size_of::<SECURITY_ATTRIBUTES>() as u32,
            bInheritHandle: true.into(),
            ..Default::default()
        };
        let stdin = owned(
            CreateFileW(
                PCWSTR(wide("NUL").as_ptr()),
                GENERIC_READ.0,
                FILE_SHARE_READ | FILE_SHARE_WRITE,
                Some(&security),
                OPEN_EXISTING,
                FILE_ATTRIBUTE_NORMAL,
                None,
            )
            .map_err(failure)?,
        );
        let inherited_handles = [handle(&stdin), handle(&stdout_write), handle(&stderr_write)];
        let attributes = AttributeList::new(&inherited_handles).map_err(failure)?;
        let mut startup = STARTUPINFOEXW::default();
        startup.StartupInfo.cb = size_of::<STARTUPINFOEXW>() as u32;
        startup.StartupInfo.dwFlags = STARTF_USESTDHANDLES | STARTF_USESHOWWINDOW;
        startup.StartupInfo.wShowWindow = 0;
        startup.StartupInfo.hStdInput = handle(&stdin);
        startup.StartupInfo.hStdOutput = handle(&stdout_write);
        startup.StartupInfo.hStdError = handle(&stderr_write);
        startup.lpAttributeList = attributes.pointer;
        let job = Job(owned(
            CreateJobObjectW(None, PCWSTR::null()).map_err(failure)?,
        ));
        let mut limits = JOBOBJECT_EXTENDED_LIMIT_INFORMATION::default();
        limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
        SetInformationJobObject(
            handle(&job.0),
            JobObjectExtendedLimitInformation,
            (&limits as *const JOBOBJECT_EXTENDED_LIMIT_INFORMATION).cast(),
            size_of_val(&limits) as u32,
        )
        .map_err(failure)?;
        let token = if low_integrity {
            Some(low_integrity_token().map_err(failure)?)
        } else {
            None
        };
        let flags = CREATE_NO_WINDOW
            | CREATE_SUSPENDED
            | CREATE_UNICODE_ENVIRONMENT
            | EXTENDED_STARTUPINFO_PRESENT;
        let mut information = PROCESS_INFORMATION::default();
        if let Some(token) = token {
            CreateProcessAsUserW(
                Some(handle(&token)),
                PCWSTR(application.as_ptr()),
                Some(PWSTR(command_line.as_mut_ptr())),
                None,
                None,
                true,
                flags,
                Some(environment_block.as_ptr().cast()),
                PCWSTR(directory.as_ptr()),
                &startup.StartupInfo,
                &mut information,
            )
            .map_err(failure)?;
        } else {
            CreateProcessW(
                PCWSTR(application.as_ptr()),
                Some(PWSTR(command_line.as_mut_ptr())),
                None,
                None,
                true,
                flags,
                Some(environment_block.as_ptr().cast()),
                PCWSTR(directory.as_ptr()),
                &startup.StartupInfo,
                &mut information,
            )
            .map_err(failure)?;
        }
        let process = owned(information.hProcess);
        let thread = owned(information.hThread);
        if let Err(error) = AssignProcessToJobObject(handle(&job.0), handle(&process)) {
            let _ = TerminateProcess(handle(&process), 1);
            return Err(failure(error));
        }
        if ResumeThread(handle(&thread)) == u32::MAX {
            job.terminate();
            return Err(failure(windows::core::Error::from_win32()));
        }
        let control = Arc::new(ProcessControl {
            state: Mutex::new(ProcessState::default()),
            job,
        });
        let wait = move || {
            WaitForSingleObject(handle(&process), INFINITE);
            let mut exit_code = 1;
            let _ = GetExitCodeProcess(handle(&process), &mut exit_code);
            exit_code as i32
        };
        Ok((
            information.dwProcessId,
            control,
            File::from(stdout_read),
            File::from(stderr_read),
            wait,
        ))
    }
}
