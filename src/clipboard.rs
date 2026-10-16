use std::mem::size_of;
use windows::core::{Error, Result};
use windows::Win32::Foundation::{GlobalFree, HANDLE, HWND};
use windows::Win32::System::DataExchange::{
    CloseClipboard, EmptyClipboard, OpenClipboard, SetClipboardData,
};
use windows::Win32::System::Memory::{GlobalAlloc, GlobalLock, GlobalUnlock, GMEM_MOVEABLE};
use windows::Win32::System::Ole::CF_UNICODETEXT;

pub fn copy(hwnd: HWND, text: &str) -> Result<()> {
    let wide: Vec<u16> = text.encode_utf16().chain(Some(0)).collect();
    unsafe {
        let memory = GlobalAlloc(GMEM_MOVEABLE, wide.len() * size_of::<u16>())?;
        let result = (|| {
            let target = GlobalLock(memory) as *mut u16;
            if target.is_null() {
                return Err(Error::from_win32());
            }
            std::ptr::copy_nonoverlapping(wide.as_ptr(), target, wide.len());
            let _ = GlobalUnlock(memory);
            OpenClipboard(hwnd)?;
            let result = EmptyClipboard().and_then(|_| {
                SetClipboardData(CF_UNICODETEXT.0 as u32, HANDLE(memory.0)).map(|_| ())
            });
            let _ = CloseClipboard();
            result
        })();
        if result.is_err() {
            let _ = GlobalFree(memory);
        }
        result
    }
}
