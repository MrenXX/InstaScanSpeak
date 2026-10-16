use std::time::Instant;
use windows::core::{w, Result, PCWSTR};
use windows::Win32::Media::Speech::*;
use windows::Win32::System::Com::{CoCreateInstance, CoTaskMemFree, CLSCTX_ALL};

pub struct Speech {
    voice: Option<ISpVoice>,
}

impl Speech {
    pub fn new() -> Self {
        Self { voice: None }
    }

    pub fn speak(&mut self, text: &str, voice_id: &str, rate: i32) -> Result<f64> {
        let start = Instant::now();
        unsafe {
            if self.voice.is_none() {
                self.voice = Some(CoCreateInstance(&SpVoice, None, CLSCTX_ALL)?);
            }
            let voice = self.voice.as_ref().unwrap();
            voice.Speak(
                PCWSTR::null(),
                (SPF_ASYNC.0 | SPF_PURGEBEFORESPEAK.0) as u32,
                None,
            )?;
            if !voice_id.is_empty() {
                let token: ISpObjectToken = CoCreateInstance(&SpObjectToken, None, CLSCTX_ALL)?;
                let id = wide(voice_id);
                token.SetId(PCWSTR::null(), PCWSTR(id.as_ptr()), false)?;
                voice.SetVoice(&token)?;
            }
            voice.SetRate(rate)?;
            let text = wide(text);
            voice.Speak(
                PCWSTR(text.as_ptr()),
                (SPF_ASYNC.0 | SPF_PURGEBEFORESPEAK.0 | SPF_IS_NOT_XML.0) as u32,
                None,
            )?;
        }
        Ok(start.elapsed().as_secs_f64() * 1000.0)
    }

    pub fn stop(&self) {
        if let Some(voice) = &self.voice {
            unsafe {
                let _ = voice.Speak(
                    PCWSTR::null(),
                    (SPF_ASYNC.0 | SPF_PURGEBEFORESPEAK.0) as u32,
                    None,
                );
            }
        }
    }

    pub fn release_if_finished(&mut self) {
        if let Some(voice) = &self.voice {
            let mut status = SPVOICESTATUS::default();
            if unsafe { voice.GetStatus(&mut status, std::ptr::null_mut()) }.is_ok()
                && status.dwRunningState == SPRS_DONE.0 as u32
            {
                self.voice = None;
            }
        }
    }

    pub fn wait(&self, timeout_ms: u32) -> Result<()> {
        if let Some(voice) = &self.voice {
            unsafe {
                voice.WaitUntilDone(timeout_ms)?;
                let mut status = SPVOICESTATUS::default();
                voice.GetStatus(&mut status, std::ptr::null_mut())?;
                if status.dwRunningState != SPRS_DONE.0 as u32 {
                    return Err(windows::core::Error::new(
                        windows::core::HRESULT(0x800705B4u32 as i32),
                        "Speech timed out",
                    ));
                }
            }
        }
        Ok(())
    }
}

pub fn default_voice_id() -> Result<String> {
    unsafe {
        let category: ISpObjectTokenCategory =
            CoCreateInstance(&SpObjectTokenCategory, None, CLSCTX_ALL)?;
        category.SetId(
            w!("HKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\Speech\\Voices"),
            false,
        )?;
        let id = category.GetDefaultTokenId()?;
        let result = id.to_string();
        CoTaskMemFree(Some(id.0 as _));
        Ok(result?)
    }
}

// SAPI stream-start timing. This excludes the sound device's output buffer.
pub fn benchmark() -> Result<()> {
    unsafe {
        let start = Instant::now();
        let voice: ISpVoice = CoCreateInstance(&SpVoice, None, CLSCTX_ALL)?;
        let mask = (1u64 << SPEI_START_INPUT_STREAM.0) | (1u64 << 30) | (1u64 << 33);
        voice.SetInterest(mask, mask)?;
        voice.SetNotifyWin32Event()?;
        println!(
            "voice_init_ms={:.2}",
            start.elapsed().as_secs_f64() * 1000.0
        );
        for i in 0..3 {
            let text = wide("InstaSpeak is ready.");
            let start = Instant::now();
            voice.Speak(
                PCWSTR(text.as_ptr()),
                (SPF_ASYNC.0 | SPF_IS_NOT_XML.0) as u32,
                None,
            )?;
            let queued_ms = start.elapsed().as_secs_f64() * 1000.0;
            let wait = windows::Win32::System::Threading::WaitForSingleObject(
                voice.GetNotifyEventHandle(),
                5000,
            );
            if wait != windows::Win32::Foundation::WAIT_OBJECT_0 {
                return Err(windows::core::Error::new(
                    windows::core::HRESULT(0x800705B4u32 as i32),
                    "No speech-start event",
                ));
            }
            let elapsed = start.elapsed().as_secs_f64() * 1000.0;
            let mut event = SPEVENT::default();
            let mut fetched = 0;
            voice.GetEvents(1, &mut event, &mut fetched)?;
            if fetched != 1 || event._bitfield & 0xffff != SPEI_START_INPUT_STREAM.0 {
                return Err(windows::core::Error::new(
                    windows::core::HRESULT(0x80004005u32 as i32),
                    "Unexpected speech event",
                ));
            }
            println!(
                "speech_run={} queued_ms={queued_ms:.2} stream_start_ms={elapsed:.2}",
                i + 1
            );
            voice.WaitUntilDone(10_000)?;
        }
    }
    Ok(())
}

pub fn voices() -> Result<Vec<(String, String)>> {
    unsafe {
        let category: ISpObjectTokenCategory =
            CoCreateInstance(&SpObjectTokenCategory, None, CLSCTX_ALL)?;
        category.SetId(
            w!("HKEY_LOCAL_MACHINE\\SOFTWARE\\Microsoft\\Speech\\Voices"),
            false,
        )?;
        let tokens = category.EnumTokens(PCWSTR::null(), PCWSTR::null())?;
        let mut result = Vec::new();
        let mut count = 0;
        tokens.GetCount(&mut count)?;
        for i in 0..count {
            let token = tokens.Item(i)?;
            let id = token.GetId()?;
            let label = token.GetStringValue(PCWSTR::null())?;
            result.push((id.to_string()?, label.to_string()?));
            CoTaskMemFree(Some(id.0 as _));
            CoTaskMemFree(Some(label.0 as _));
        }
        Ok(result)
    }
}

fn wide(text: &str) -> Vec<u16> {
    text.encode_utf16()
        .filter(|v| *v != 0)
        .chain(Some(0))
        .collect()
}
