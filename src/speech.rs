use std::time::Instant;
use windows::core::{w, Result, PCWSTR};
use windows::Win32::Media::Speech::*;
use windows::Win32::System::Com::{CoCreateInstance, CoTaskMemFree, CLSCTX_ALL};

pub struct Speech {
    voice: Option<ISpVoice>,
    neural: Option<super::neural::Speaker>,
    using_neural: bool,
    notify: isize,
    paused: bool,
}

impl Speech {
    pub fn new() -> Self {
        Self {
            voice: None,
            neural: None,
            using_neural: false,
            notify: 0,
            paused: false,
        }
    }

    pub fn set_notify_window(&mut self, hwnd: windows::Win32::Foundation::HWND) {
        self.notify = hwnd.0 as isize;
    }

    pub fn speak(&mut self, text: &str, voice_id: &str, rate: i32) -> Result<f64> {
        let start = Instant::now();
        self.stop();
        self.using_neural = voice_id == super::neural::VOICE_ID;
        if self.using_neural {
            if super::neural::assets().is_none() {
                return Err(windows::core::Error::new(
                    windows::core::HRESULT(0x80004005u32 as i32),
                    "Run Install Northern English Voice.cmd to install this voice.",
                ));
            }
            let neural = self.neural.get_or_insert_with(super::neural::Speaker::new);
            neural.speak(text, rate, self.notify)?;
            return Ok(start.elapsed().as_secs_f64() * 1000.0);
        }
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

    pub fn stop(&mut self) {
        if let Some(neural) = &self.neural {
            neural.stop();
        }
        if let Some(voice) = &self.voice {
            unsafe {
                let _ = voice.Speak(
                    PCWSTR::null(),
                    (SPF_ASYNC.0 | SPF_PURGEBEFORESPEAK.0) as u32,
                    None,
                );
                if self.paused {
                    let _ = voice.Resume();
                }
            }
        }
        self.paused = false;
    }

    pub fn toggle_pause(&mut self) -> Result<Option<bool>> {
        if self.using_neural {
            return match &self.neural {
                Some(neural) => neural.toggle_pause(),
                None => Ok(None),
            };
        }
        let Some(voice) = &self.voice else {
            return Ok(None);
        };
        unsafe {
            let mut status = SPVOICESTATUS::default();
            voice.GetStatus(&mut status, std::ptr::null_mut())?;
            if !self.paused && status.dwRunningState == SPRS_DONE.0 as u32 {
                return Ok(None);
            }
            if self.paused {
                voice.Resume()?;
            } else {
                voice.Pause()?;
            }
        }
        self.paused = !self.paused;
        Ok(Some(self.paused))
    }

    pub fn set_rate(&self, rate: i32) -> Result<()> {
        if let Some(neural) = &self.neural {
            neural.set_rate(rate);
        }
        if let Some(voice) = &self.voice {
            unsafe {
                voice.SetRate(rate)?;
            }
        }
        Ok(())
    }

    pub fn release_if_finished(&mut self) {
        if self.paused {
            return;
        }
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
        if self.using_neural {
            if let Some(neural) = &self.neural {
                return neural.wait(timeout_ms);
            }
        }
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

#[cfg(test)]
mod tests {
    use super::*;
    use std::{thread, time::Duration};

    #[test]
    #[ignore = "requires a Windows audio output device"]
    fn sapi_pause_resume_keeps_position_and_stop_resets_pause() -> Result<()> {
        unsafe {
            windows::Win32::System::Com::CoInitializeEx(
                None,
                windows::Win32::System::Com::COINIT_MULTITHREADED,
            )
            .ok()?;
        }
        let mut speech = Speech::new();
        assert_eq!(speech.toggle_pause()?, None);
        speech.speak(
            &"This passage verifies pausing without losing the current reading position. "
                .repeat(20),
            "",
            0,
        )?;
        let audio_status = |speech: &Speech| -> Result<SPAUDIOSTATUS> {
            use windows::core::Interface;
            let mut status = SPAUDIOSTATUS::default();
            unsafe {
                let audio: ISpAudio = speech.voice.as_ref().unwrap().GetOutputStream()?.cast()?;
                audio.GetStatus(&mut status)?;
            }
            Ok(status)
        };
        let deadline = Instant::now() + Duration::from_secs(3);
        while audio_status(&speech)?.CurDevicePos == 0 {
            assert!(Instant::now() < deadline, "SAPI audio did not start");
            thread::sleep(Duration::from_millis(20));
        }
        assert_eq!(speech.toggle_pause()?, Some(true));
        // Pause completes at a word boundary; wait for the output device to close.
        let deadline = Instant::now() + Duration::from_secs(3);
        while audio_status(&speech)?.State == SPAS_RUN {
            assert!(Instant::now() < deadline, "SAPI output did not pause");
            thread::sleep(Duration::from_millis(20));
        }
        let paused_position = audio_status(&speech)?.CurDevicePos;
        thread::sleep(Duration::from_millis(300));
        assert_eq!(
            audio_status(&speech)?.CurDevicePos,
            paused_position,
            "paused SAPI audio advanced"
        );
        speech.release_if_finished();
        assert!(
            speech.voice.is_some(),
            "paused voice was discarded by idle cleanup"
        );
        assert_eq!(speech.toggle_pause()?, Some(false));
        let deadline = Instant::now() + Duration::from_secs(2);
        while audio_status(&speech)?.CurDevicePos <= paused_position {
            assert!(
                Instant::now() < deadline,
                "SAPI did not resume at its saved position"
            );
            thread::sleep(Duration::from_millis(20));
        }
        assert_eq!(speech.toggle_pause()?, Some(true));
        speech.stop();
        speech.wait(2000)?;
        assert_eq!(speech.toggle_pause()?, None);
        speech.speak("InstaSpeak is ready.", "", 0)?;
        speech.wait(10_000)?;
        drop(speech);
        unsafe {
            windows::Win32::System::Com::CoUninitialize();
        }
        Ok(())
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
        if super::neural::assets().is_some() {
            result.push((
                super::neural::VOICE_ID.to_string(),
                super::neural::VOICE_NAME.to_string(),
            ));
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
