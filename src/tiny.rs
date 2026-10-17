use std::io::{BufRead, BufReader, Write};
use std::os::windows::process::CommandExt;
use std::path::PathBuf;
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};
use std::sync::{
    atomic::{AtomicBool, AtomicU64, Ordering},
    Arc, Mutex,
};
use windows::core::{Error, Result, HRESULT};

pub fn assets() -> Option<(PathBuf, PathBuf)> {
    let mut roots = Vec::new();
    if let Ok(exe) = std::env::current_exe() {
        if let Some(parent) = exe.parent() {
            roots.push(parent.to_path_buf());
        }
    }
    if let Some(local) = std::env::var_os("LOCALAPPDATA") {
        roots.push(PathBuf::from(local).join("InstaSpeak"));
    }
    roots.into_iter().find_map(|root| {
        let helper = root.join("instaspeak-ocr.exe");
        let models = root.join("tiny-ocr");
        (helper.is_file()
            && ["det.onnx", "rec.onnx", "characters.txt", "onnxruntime.dll"]
                .iter()
                .all(|name| models.join(name).is_file()))
        .then_some((helper, models))
    })
}

#[derive(Default)]
pub struct Control {
    child: Mutex<Option<Child>>,
    generation: AtomicU64,
    busy: AtomicBool,
}

impl Control {
    pub fn generation(&self) -> u64 {
        self.generation.load(Ordering::SeqCst)
    }
    pub fn cancel(&self) {
        let mut child = self.child.lock().unwrap();
        self.generation.fetch_add(1, Ordering::SeqCst);
        if self.busy.swap(false, Ordering::SeqCst) {
            kill(&mut child);
        }
    }
    pub fn unload(&self) {
        self.cancel();
        kill(&mut self.child.lock().unwrap());
    }
}

fn kill(slot: &mut Option<Child>) {
    if let Some(mut child) = slot.take() {
        let _ = child.kill();
        let _ = child.wait();
    }
}

pub struct Engine {
    input: ChildStdin,
    output: BufReader<ChildStdout>,
    control: Arc<Control>,
    pid: u32,
    _job: super::neural::Job,
}

impl Engine {
    fn new(control: Arc<Control>, generation: u64) -> Result<Self> {
        let (helper, models) =
            assets().ok_or_else(|| error("Run Install Tiny OCR.cmd to install PP-OCRv6 Tiny."))?;
        let job = super::neural::Job::new()?;
        let mut slot = control.child.lock().unwrap();
        if control.generation() != generation {
            return Err(error("OCR cancelled"));
        }
        let mut child = Command::new(helper)
            .arg(models)
            .stdin(Stdio::piped())
            .stdout(Stdio::piped())
            .stderr(Stdio::null())
            .creation_flags(0x08000000)
            .spawn()
            .map_err(|e| error(&e.to_string()))?;
        if let Err(failure) = job.assign(&child) {
            let _ = child.kill();
            let _ = child.wait();
            return Err(failure);
        }
        let input = child.stdin.take().unwrap();
        let output = BufReader::new(child.stdout.take().unwrap());
        let pid = child.id();
        *slot = Some(child);
        println!("tiny_helper_pid={pid}");
        drop(slot);
        Ok(Self {
            input,
            output,
            control,
            pid,
            _job: job,
        })
    }

    pub fn recognize(
        engine: &mut Option<Self>,
        control: &Arc<Control>,
        generation: u64,
        width: i32,
        height: i32,
        pixels: &[u8],
    ) -> Result<(String, f64)> {
        let alive = {
            let slot = control.child.lock().unwrap();
            if generation != control.generation() {
                return Err(error("OCR cancelled"));
            }
            control.busy.store(true, Ordering::SeqCst);
            slot.is_some()
        };
        if !alive {
            *engine = None;
        }
        let result = (|| {
            if engine.is_none() {
                *engine = Some(Self::new(control.clone(), generation)?);
            }
            let engine = engine.as_mut().unwrap();
            engine
                .input
                .write_all(&(width as u32).to_le_bytes())
                .and_then(|_| engine.input.write_all(&(height as u32).to_le_bytes()))
                .and_then(|_| engine.input.write_all(pixels))
                .and_then(|_| engine.input.flush())
                .map_err(|e| error(&e.to_string()))?;
            let mut response = String::new();
            if engine
                .output
                .read_line(&mut response)
                .map_err(|e| error(&e.to_string()))?
                == 0
            {
                return Err(error(
                    "Tiny OCR helper stopped. Reinstall Tiny OCR if this repeats.",
                ));
            }
            let response: serde_json::Value =
                serde_json::from_str(&response).map_err(|e| error(&e.to_string()))?;
            if let Some(message) = response["error"].as_str() {
                return Err(error(message));
            }
            Ok((
                response["text"]
                    .as_str()
                    .ok_or_else(|| error("Invalid OCR helper response"))?
                    .to_string(),
                response["ms"].as_f64().unwrap_or(0.0),
            ))
        })();
        let slot = control.child.lock().unwrap();
        if control.generation() == generation {
            control.busy.store(false, Ordering::SeqCst);
        }
        drop(slot);
        if result.is_err() {
            *engine = None;
        }
        result
    }
}

impl Drop for Engine {
    fn drop(&mut self) {
        let mut slot = self.control.child.lock().unwrap();
        if slot.as_ref().map(Child::id) == Some(self.pid) {
            kill(&mut slot);
        }
    }
}

fn error(message: &str) -> Error {
    Error::new(HRESULT(0x80004005u32 as i32), message)
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cancelled_queued_ocr_never_starts_a_helper() {
        let control = Arc::new(Control::default());
        let generation = control.generation();
        control.cancel();
        let mut engine = None;
        assert!(Engine::recognize(&mut engine, &control, generation, 1, 1, &[255; 4]).is_err());
        assert!(engine.is_none());
        assert!(control.child.lock().unwrap().is_none());
        assert!(!control.busy.load(Ordering::SeqCst));
    }
}
