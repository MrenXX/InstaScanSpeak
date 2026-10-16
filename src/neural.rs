use std::fs;
use std::io::{BufRead, BufReader, Write};
use std::os::windows::io::AsRawHandle;
use std::os::windows::process::CommandExt;
use std::path::PathBuf;
use std::process::{Child, ChildStdin, ChildStdout, Command, Stdio};
use std::sync::atomic::{AtomicBool, AtomicI32, AtomicU64, Ordering};
use std::sync::{mpsc, Arc, Mutex};
use std::thread;
use std::time::{Duration, Instant};
use windows::core::{Error, Result, HRESULT, PCWSTR};
use windows::Win32::Foundation::{CloseHandle, HANDLE};
use windows::Win32::Media::Audio::{PlaySoundW, SND_ASYNC, SND_MEMORY, SND_NODEFAULT, SND_SYNC};
use windows::Win32::System::JobObjects::*;

pub const VOICE_ID: &str = "piper:northern-english-male";
pub const VOICE_NAME: &str = "Northern English Male - English (UK)";

fn roots() -> Vec<PathBuf> {
    let mut roots = Vec::new();
    if let Ok(exe) = std::env::current_exe() {
        if let Some(parent) = exe.parent() {
            roots.push(parent.to_path_buf());
        }
    }
    if let Some(local) = std::env::var_os("LOCALAPPDATA") {
        roots.push(PathBuf::from(local).join("InstaSpeak"));
    }
    roots
}

pub fn assets() -> Option<(PathBuf, PathBuf)> {
    roots().into_iter().find_map(|root| {
        let runtime = root.join("piper").join("piper.exe");
        let model = root
            .join("voices")
            .join("northern_english_male")
            .join("voice.onnx");
        (runtime.is_file() && model.is_file() && model.with_extension("onnx.json").is_file())
            .then_some((runtime, model))
    })
}

struct Shared {
    child: Mutex<Option<Child>>,
    generation: AtomicU64,
    rate: AtomicI32,
    busy: AtomicBool,
    error: Mutex<Option<String>>,
}

impl Shared {
    fn kill(&self) {
        if let Some(mut child) = self.child.lock().unwrap().take() {
            let _ = child.kill();
            let _ = child.wait();
        }
    }

    fn cancel(&self) {
        self.generation.fetch_add(1, Ordering::SeqCst);
        unsafe {
            let _ = PlaySoundW(PCWSTR::null(), None, SND_ASYNC);
        }
        if self.busy.swap(false, Ordering::SeqCst) {
            self.kill();
        }
    }
}

enum Request {
    Read {
        text: String,
        generation: u64,
        notify: isize,
    },
    Shutdown,
}

pub struct Speaker {
    tx: mpsc::Sender<Request>,
    shared: Arc<Shared>,
}

impl Speaker {
    pub fn new() -> Self {
        let shared = Arc::new(Shared {
            child: Mutex::new(None),
            generation: AtomicU64::new(0),
            rate: AtomicI32::new(0),
            busy: AtomicBool::new(false),
            error: Mutex::new(None),
        });
        let (tx, rx) = mpsc::channel();
        let state = shared.clone();
        thread::spawn(move || worker(rx, state));
        Self { tx, shared }
    }

    pub fn speak(&self, text: &str, rate: i32, notify: isize) -> Result<()> {
        self.shared.cancel();
        self.shared.rate.store(rate, Ordering::SeqCst);
        *self.shared.error.lock().unwrap() = None;
        let generation = self.shared.generation.load(Ordering::SeqCst);
        self.shared.busy.store(true, Ordering::SeqCst);
        self.tx
            .send(Request::Read {
                text: text.to_string(),
                generation,
                notify,
            })
            .map_err(|_| error("Neural speech worker stopped"))
    }

    pub fn stop(&self) {
        self.shared.cancel();
    }
    pub fn set_rate(&self, rate: i32) {
        self.shared.rate.store(rate, Ordering::SeqCst);
    }
    pub fn wait(&self, timeout_ms: u32) -> Result<()> {
        let start = Instant::now();
        while self.shared.busy.load(Ordering::SeqCst) {
            if start.elapsed() > Duration::from_millis(timeout_ms as u64) {
                return Err(error("Neural speech timed out"));
            }
            thread::sleep(Duration::from_millis(10));
        }
        if let Some(message) = self.shared.error.lock().unwrap().clone() {
            return Err(error(&message));
        }
        Ok(())
    }
}

impl Drop for Speaker {
    fn drop(&mut self) {
        self.shared.cancel();
        self.shared.kill();
        let _ = self.tx.send(Request::Shutdown);
    }
}

struct Engine {
    input: ChildStdin,
    output: BufReader<ChildStdout>,
    rate: i32,
}
struct Job(HANDLE);
impl Job {
    fn new() -> Result<Self> {
        unsafe {
            let handle = CreateJobObjectW(None, PCWSTR::null())?;
            let job = Self(handle);
            let mut limits = JOBOBJECT_EXTENDED_LIMIT_INFORMATION::default();
            limits.BasicLimitInformation.LimitFlags = JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE;
            SetInformationJobObject(
                handle,
                JobObjectExtendedLimitInformation,
                &limits as *const _ as _,
                std::mem::size_of_val(&limits) as u32,
            )?;
            Ok(job)
        }
    }
}
impl Drop for Job {
    fn drop(&mut self) {
        unsafe {
            let _ = CloseHandle(self.0);
        }
    }
}

fn worker(rx: mpsc::Receiver<Request>, shared: Arc<Shared>) {
    let job = Job::new();
    let mut engine = None;
    loop {
        let request = match rx.recv_timeout(Duration::from_secs(30)) {
            Ok(request) => request,
            Err(mpsc::RecvTimeoutError::Timeout) => {
                shared.kill();
                engine = None;
                continue;
            }
            Err(mpsc::RecvTimeoutError::Disconnected) => break,
        };
        let Request::Read {
            text,
            generation,
            notify,
        } = request
        else {
            break;
        };
        if generation != shared.generation.load(Ordering::SeqCst) {
            continue;
        }
        let result = match &job {
            Ok(job) => read(&text, generation, &shared, &mut engine, job),
            Err(failure) => Err(error(&format!("Could not manage voice helper: {failure}"))),
        };
        if generation == shared.generation.load(Ordering::SeqCst) {
            if let Err(failure) = result {
                shared.kill();
                engine = None;
                let message = format!("Northern English Male: {failure}");
                *shared.error.lock().unwrap() = Some(message.clone());
                if notify != 0 {
                    super::post_worker_status(notify, message);
                }
            } else {
                println!("neural_finished=true");
            }
            shared.busy.store(false, Ordering::SeqCst);
        }
    }
    shared.kill();
}

fn start_engine(shared: &Shared, job: &Job, rate: i32, generation: u64) -> Result<Engine> {
    shared.kill();
    let (runtime, model) = assets()
        .ok_or_else(|| error("Voice files are missing. Run Install Northern English Voice.cmd."))?;
    let mut slot = shared.child.lock().unwrap();
    if generation != shared.generation.load(Ordering::SeqCst) {
        return Err(error("Cancelled"));
    }
    let length_scale = 2.0_f64.powf(-(rate as f64) / 10.0);
    let mut child = Command::new(&runtime)
        .args(["--model"])
        .arg(&model)
        .args([
            "--json-input",
            "--length_scale",
            &format!("{length_scale:.5}"),
            "--quiet",
        ])
        .current_dir(runtime.parent().unwrap())
        .stdin(Stdio::piped())
        .stdout(Stdio::piped())
        .stderr(Stdio::null())
        .creation_flags(0x08000000)
        .spawn()
        .map_err(|e| error(&format!("Could not start Piper: {e}")))?;
    if let Err(failure) =
        unsafe { AssignProcessToJobObject(job.0, HANDLE(child.as_raw_handle() as _)) }
    {
        let _ = child.kill();
        let _ = child.wait();
        return Err(failure);
    }
    let input = child.stdin.take().unwrap();
    let output = BufReader::new(child.stdout.take().unwrap());
    println!("neural_helper_pid={}", child.id());
    println!("neural_rate={rate}");
    *slot = Some(child);
    Ok(Engine {
        input,
        output,
        rate,
    })
}

fn read(
    text: &str,
    generation: u64,
    shared: &Shared,
    engine: &mut Option<Engine>,
    job: &Job,
) -> Result<()> {
    let start = Instant::now();
    let directory = std::env::temp_dir().join("InstaSpeak");
    fs::create_dir_all(&directory).map_err(|e| error(&e.to_string()))?;
    for (index, part) in sections(text).iter().enumerate() {
        if generation != shared.generation.load(Ordering::SeqCst) {
            break;
        }
        let rate = shared.rate.load(Ordering::SeqCst);
        let alive = shared.child.lock().unwrap().is_some();
        if !alive || engine.as_ref().map(|e| e.rate) != Some(rate) {
            *engine = Some(start_engine(shared, job, rate, generation)?);
        }
        let active = engine.as_mut().unwrap();
        let file = directory.join(format!(
            "speech-{}-{generation}-{index}.wav",
            std::process::id()
        ));
        let operation = (|| {
            let request = serde_json::json!({"text": part, "output_file": file});
            writeln!(active.input, "{request}")
                .and_then(|_| active.input.flush())
                .map_err(|e| error(&e.to_string()))?;
            let mut response = String::new();
            if active
                .output
                .read_line(&mut response)
                .map_err(|e| error(&e.to_string()))?
                == 0
            {
                return Err(error("Voice helper ended before producing audio"));
            }
            if generation != shared.generation.load(Ordering::SeqCst) {
                return Ok(());
            }
            let audio = fs::read(&file).map_err(|e| error(&e.to_string()))?;
            let _ = fs::remove_file(&file);
            if index == 0 {
                println!(
                    "neural_audio_ready_ms={:.2}",
                    start.elapsed().as_secs_f64() * 1000.0
                );
            }
            if !unsafe {
                PlaySoundW(
                    PCWSTR(audio.as_ptr() as _),
                    None,
                    SND_MEMORY | SND_SYNC | SND_NODEFAULT,
                )
            }
            .as_bool()
            {
                return Err(error("Windows could not play the generated speech"));
            }
            Ok(())
        })();
        let _ = fs::remove_file(&file);
        operation?;
    }
    Ok(())
}

fn sections(text: &str) -> Vec<String> {
    let mut result = Vec::new();
    let mut part = String::new();
    let mut count = 0;
    let mut punctuation = false;
    for ch in text.chars() {
        if ch.is_whitespace() && ((punctuation && count >= 60) || count >= 240) {
            if !part.trim().is_empty() {
                result.push(part.trim().to_string());
            }
            part.clear();
            count = 0;
        }
        part.push(ch);
        count += 1;
        punctuation = matches!(ch, '.' | '!' | '?' | '\n');
    }
    if !part.trim().is_empty() {
        result.push(part.trim().to_string());
    }
    result
}

fn error(message: &str) -> Error {
    Error::new(HRESULT(0x80004005u32 as i32), message)
}
