use image::{Rgb, RgbImage, imageops};
use oar_ocr_core::core::config::{ModelInferenceConfig, OrtSessionConfig};
use oar_ocr_core::core::inference::OrtInfer;
use oar_ocr_core::models::detection::db::DBModel;
use oar_ocr_core::predictors::TextRecognitionPredictor;
use oar_ocr_core::processors::{
    BoxType, ColorOrder, DBPostProcess, DetResizeForTest, LimitType, NormalizeImage, ScoreMode,
    TensorLayout, sort_quad_boxes,
};
use oar_ocr_core::utils::get_rotate_crop_image;
use std::io::{self, Read, Write};
use std::path::PathBuf;
use std::time::Instant;

fn main() {
    if let Err(error) = run() {
        println!("{}", serde_json::json!({"error":error.to_string()}));
        std::process::exit(1);
    }
}

fn run() -> Result<(), Box<dyn std::error::Error>> {
    rayon::ThreadPoolBuilder::new()
        .num_threads(2)
        .build_global()?;
    let models = PathBuf::from(
        std::env::args_os()
            .nth(1)
            .ok_or("Missing model directory")?,
    );
    ort::init_from(models.join("onnxruntime.dll"))?
        .with_execution_providers([ort::ep::CPU::default().with_arena_allocator(false).build()])
        .commit();
    let threads = OrtSessionConfig::new()
        .with_intra_threads(2)
        .with_inter_threads(1)
        .with_log_severity_level(3)
        .with_memory_pattern(true);
    let detector = DBModel::new(
        OrtInfer::from_config(
            &ModelInferenceConfig {
                ort_session: Some(threads.clone()),
                ..Default::default()
            },
            models.join("det.onnx"),
            Some("x"),
        )?,
        DetResizeForTest::new(
            None,
            None,
            None,
            Some(960),
            Some(LimitType::Max),
            None,
            Some(4000),
        ),
        NormalizeImage::with_color_order(
            Some(1.0 / 255.0),
            Some(vec![0.5; 3]),
            Some(vec![0.5; 3]),
            Some(TensorLayout::CHW),
            Some(ColorOrder::BGR),
        )?,
        DBPostProcess::new(
            Some(0.3),
            Some(0.5),
            Some(1000),
            Some(1.6),
            Some(true),
            Some(ScoreMode::Fast),
            Some(BoxType::Quad),
        ),
    );
    let recognizer = TextRecognitionPredictor::builder()
        .dict_path(models.join("characters.txt"))
        .with_ort_config(threads)
        .build(models.join("rec.onnx"))?;
    let mut input = io::stdin().lock();
    let mut output = io::stdout().lock();
    loop {
        let mut header = [0u8; 8];
        if let Err(error) = input.read_exact(&mut header) {
            if error.kind() == io::ErrorKind::UnexpectedEof {
                break;
            }
            return Err(error.into());
        }
        let width = u32::from_le_bytes(header[..4].try_into()?);
        let height = u32::from_le_bytes(header[4..].try_into()?);
        let length = (width as usize)
            .checked_mul(height as usize)
            .and_then(|n| n.checked_mul(4))
            .filter(|n| *n > 0 && *n <= 128 * 1024 * 1024)
            .ok_or("Invalid image dimensions")?;
        let mut pixels = vec![0; length];
        input.read_exact(&mut pixels)?;
        let start = Instant::now();
        let mut image = RgbImage::from_fn(width, height, |x, y| {
            let index = ((y * width + x) * 4) as usize;
            Rgb([pixels[index + 2], pixels[index + 1], pixels[index]])
        });
        let border: u64 = (0..width)
            .map(|x| {
                image
                    .get_pixel(x, 0)
                    .0
                    .iter()
                    .map(|v| *v as u64)
                    .sum::<u64>()
            })
            .sum();
        if border < width as u64 * 3 * 128 {
            imageops::invert(&mut image);
        }
        let scale = if width.max(height) <= 1200 { 2 } else { 1 };
        let image = imageops::resize(
            &image,
            width * scale,
            height * scale,
            imageops::FilterType::CatmullRom,
        );
        let result = (|| -> Result<String, Box<dyn std::error::Error>> {
            let boxes = detector.forward(vec![image.clone()], 0.3, 0.5, 1.6)?;
            let boxes = sort_quad_boxes(&boxes.boxes[0]);
            if boxes.is_empty() {
                return Ok(String::new());
            }
            let crops = boxes
                .iter()
                .map(|bbox| get_rotate_crop_image(&image, &bbox.points))
                .collect::<Result<Vec<_>, _>>()?;
            let result = recognizer.predict(crops)?;
            Ok(result
                .texts
                .into_iter()
                .zip(result.scores)
                .filter(|(_, score)| *score >= 0.5)
                .map(|(text, _)| text)
                .collect::<Vec<_>>()
                .join("\r\n"))
        })();
        let response = match result {
            Ok(text) => serde_json::json!({"text":text,"ms":start.elapsed().as_secs_f64()*1000.0}),
            Err(error) => serde_json::json!({"error":error.to_string()}),
        };
        writeln!(output, "{response}")?;
        output.flush()?;
    }
    Ok(())
}
