use windows::core::{Interface, Result};
use windows::Win32::Foundation::{HWND, LPARAM, WPARAM};
use windows::Win32::System::Com::{CoCreateInstance, CLSCTX_ALL};
use windows::Win32::UI::Accessibility::*;
use windows::Win32::UI::WindowsAndMessaging::{
    GetClassNameW, GetGUIThreadInfo, GetWindowLongPtrW, SendMessageTimeoutW, GUITHREADINFO,
    GWL_STYLE, SMTO_ABORTIFHUNG, WM_GETTEXT, WM_GETTEXTLENGTH,
};

pub fn selected_text() -> Result<String> {
    unsafe {
        if let Some(text) = native_edit_selection()? {
            return Ok(text);
        }
        let automation: IUIAutomation = CoCreateInstance(&CUIAutomation8, None, CLSCTX_ALL)?;
        let timeouts: IUIAutomation2 = automation.cast()?;
        timeouts.SetConnectionTimeout(500)?;
        timeouts.SetTransactionTimeout(500)?;
        let mut element = automation.GetFocusedElement()?;
        let walker = automation.ControlViewWalker()?;
        // Browsers often expose selection on the document above the focused link.
        for _ in 0..8 {
            if !element.CurrentIsPassword()?.as_bool() {
                if let Ok(pattern) =
                    element.GetCurrentPatternAs::<IUIAutomationTextPattern>(UIA_TextPatternId)
                {
                    if let Ok(ranges) = pattern.GetSelection() {
                        let mut text = String::new();
                        for i in 0..ranges.Length()? {
                            let part = ranges.GetElement(i)?.GetText(1_000_000)?.to_string();
                            if !text.is_empty() && !part.is_empty() {
                                text.push('\n');
                            }
                            text.push_str(&part);
                        }
                        if !text.trim().is_empty() {
                            return Ok(text);
                        }
                    }
                }
            } else {
                return Ok(String::new());
            }
            match walker.GetParentElement(&element) {
                Ok(parent) => element = parent,
                Err(_) => break,
            }
        }
        Ok(String::new())
    }
}

unsafe fn native_edit_selection() -> Result<Option<String>> {
    let mut info = GUITHREADINFO {
        cbSize: std::mem::size_of::<GUITHREADINFO>() as u32,
        ..Default::default()
    };
    GetGUIThreadInfo(0, &mut info)?;
    let hwnd = info.hwndFocus;
    let mut class = [0u16; 256];
    let length = GetClassNameW(hwnd, &mut class);
    let class = String::from_utf16_lossy(&class[..length as usize]).to_ascii_uppercase();
    if class != "EDIT"
        && !class.starts_with("RICHEDIT")
        && !class.starts_with("WINDOWSFORMS10.EDIT.")
    {
        return Ok(None);
    }
    if GetWindowLongPtrW(hwnd, GWL_STYLE) & 0x20 != 0 {
        return Ok(Some(String::new()));
    }
    let mut start = 0u32;
    let mut end = 0u32;
    message(
        hwnd,
        0x00B0,
        WPARAM(&mut start as *mut _ as usize),
        LPARAM(&mut end as *mut _ as isize),
    )?;
    if start == end {
        return Ok(Some(String::new()));
    }
    let length = message(hwnd, WM_GETTEXTLENGTH, WPARAM(0), LPARAM(0))?.min(1_000_000);
    let mut text = vec![0u16; length + 1];
    let copied = message(
        hwnd,
        WM_GETTEXT,
        WPARAM(text.len()),
        LPARAM(text.as_mut_ptr() as isize),
    )?
    .min(length);
    let start = (start as usize).min(copied);
    let end = (end as usize).min(copied);
    Ok(Some(String::from_utf16_lossy(&text[start..end])))
}

unsafe fn message(hwnd: HWND, msg: u32, wparam: WPARAM, lparam: LPARAM) -> Result<usize> {
    let mut result = 0;
    if SendMessageTimeoutW(
        hwnd,
        msg,
        wparam,
        lparam,
        SMTO_ABORTIFHUNG,
        250,
        Some(&mut result),
    )
    .0 == 0
    {
        return Err(windows::core::Error::from_win32());
    }
    Ok(result)
}
