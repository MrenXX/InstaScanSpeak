use super::*;

fn memory() -> serde_json::Value {
    let mut counters = PROCESS_MEMORY_COUNTERS_EX::default();
    counters.cb = size_of::<PROCESS_MEMORY_COUNTERS_EX>() as u32;
    unsafe {
        GetProcessMemoryInfo(
            GetCurrentProcess(),
            &mut counters as *mut _ as _,
            counters.cb,
        )
        .unwrap();
    }
    serde_json::json!({"working_set_mib":counters.WorkingSetSize as f64/1048576.0,
        "private_mib":counters.PrivateUsage as f64/1048576.0,
        "peak_working_set_mib":counters.PeakWorkingSetSize as f64/1048576.0})
}

#[test]
#[ignore = "run tests/ocr-fixtures.ps1 first; writes benchmark results to artifacts"]
fn benchmark_screen_fonts() -> AnyResult<()> {
    unsafe {
        CoInitializeEx(None, COINIT_MULTITHREADED).ok()?;
    }
    let directory = PathBuf::from("artifacts/ocr-fixtures");
    let manifest = fs::read_to_string(directory.join("fixtures.json"))?;
    let fixtures: serde_json::Value =
        serde_json::from_str(manifest.trim_start_matches('\u{feff}'))?;
    let mut ocr = OcrController::new()?;
    ocr.set_current_language_tag(Some("en-US"));
    let mut records = Vec::new();
    let before = memory();
    for fixture in fixtures.as_array().unwrap() {
        let name = fixture["name"].as_str().unwrap();
        let width = fixture["width"].as_i64().unwrap() as i32;
        let height = fixture["height"].as_i64().unwrap() as i32;
        let bgra = fs::read(directory.join(format!("{name}.bgra")))?;
        for mode in [
            "current",
            "current-repeat",
            "native",
            "2x",
            "3x",
            "2x-invert",
            "3x-invert",
            "2x-linear-invert",
            "3x-linear-invert",
            "4x-linear-invert",
        ] {
            let start = Instant::now();
            let image = if mode.starts_with("current") {
                preprocess_bgra(width, height, &bgra)?
            } else {
                let scale = if mode.starts_with("4x") {
                    4
                } else if mode.starts_with("3x") {
                    3
                } else if mode.starts_with("2x") {
                    2
                } else {
                    1
                };
                let resize = if mode.contains("linear") {
                    resize_bgra_bilinear
                } else {
                    resize_bgra_bicubic
                };
                let mut bytes = resize(&bgra, width, height, width * scale, height * scale);
                if mode.ends_with("invert") && fixture["dark"].as_bool().unwrap() {
                    for pixel in bytes.chunks_exact_mut(4) {
                        for channel in &mut pixel[..3] {
                            *channel = 255 - *channel;
                        }
                    }
                }
                PreprocessedImage {
                    width: width * scale,
                    height: height * scale,
                    bgra: bytes,
                }
            };
            let bitmap = software_bitmap_from_bgra(image.width, image.height, &image.bgra)?;
            let engine = ocr.current_engine()?;
            let result = engine.RecognizeAsync(&bitmap)?.get()?;
            let text = format_ocr_result(&result, engine)?;
            records.push(
                serde_json::json!({"name":name,"mode":mode,"ms":elapsed_ms(start),"text":text}),
            );
        }
    }
    fs::write(
        "artifacts/ocr-windows.json",
        serde_json::to_vec_pretty(&records)?,
    )?;
    fs::write(
        "artifacts/windows-ocr-memory.json",
        serde_json::to_vec_pretty(&serde_json::json!({"before":before,"after":memory()}))?,
    )?;
    unsafe {
        CoUninitialize();
    }
    Ok(())
}
