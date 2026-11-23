use std::env;
use std::fs;
use std::path::{Path, PathBuf};

fn parse_mk_vars(text: &str) -> Vec<(String, Vec<String>)> {
    let joined = text.replace("\\\n", " ");
    let mut out = Vec::new();
    for line in joined.lines() {
        let trimmed = line.trim();
        if trimmed.is_empty() || trimmed.starts_with('#') {
            continue;
        }
        if let Some((k, v)) = trimmed.split_once('=') {
            let key = k.trim().to_string();
            let vals: Vec<String> = v.split_whitespace().map(|s| s.to_string()).collect();
            out.push((key, vals));
        }
    }
    out
}

fn collect_opus_sources(opus_root: &Path) -> Vec<PathBuf> {
    let mut map = std::collections::HashMap::<String, Vec<String>>::new();
    for mk in ["silk_sources.mk", "celt_sources.mk", "opus_sources.mk"] {
        let p = opus_root.join(mk);
        println!("cargo:rerun-if-changed={}", p.display());
        let text = fs::read_to_string(&p).expect("read opus mk");
        for (k, v) in parse_mk_vars(&text) {
            map.insert(k, v);
        }
    }
    let mut files = Vec::new();
    for key in [
        "SILK_SOURCES",
        "SILK_SOURCES_FIXED",
        "CELT_SOURCES",
        "OPUS_SOURCES",
    ] {
        if let Some(list) = map.get(key) {
            for rel in list {
                let full = opus_root.join(rel);
                files.push(full);
            }
        }
    }
    files
}

fn prepare_patched_tinyalsa_pcm(tinyalsa_src: &Path, out_dir: &Path) -> PathBuf {
    let pcm_c = tinyalsa_src.join("src/pcm.c");
    println!("cargo:rerun-if-changed={}", pcm_c.display());
    let src = fs::read_to_string(&pcm_c).expect("read tinyalsa pcm.c");
    let old = "int pcm_state(struct pcm *pcm)\n{\n    int err = pcm_sync_ptr(pcm, 0);";
    let new = "int pcm_state(struct pcm *pcm)\n{\n    int err = pcm_sync_ptr(pcm, SNDRV_PCM_SYNC_PTR_APPL | SNDRV_PCM_SYNC_PTR_AVAIL_MIN);";
    assert_eq!(
        src.matches(old).count(),
        1,
        "tinyalsa pcm.c pcm_state patch anchor must match exactly once"
    );
    let patched = src.replace(old, new);
    let dest_dir = out_dir.join("tinyalsa");
    fs::create_dir_all(&dest_dir).expect("mkdir tinyalsa out");
    let dest = dest_dir.join("pcm.c");
    fs::write(&dest, patched).expect("write patched pcm.c");
    dest
}

fn main() {
    let manifest_dir = PathBuf::from(env::var("CARGO_MANIFEST_DIR").unwrap());
    let repo_root = manifest_dir
        .parent()
        .and_then(|p| p.parent())
        .expect("repo root")
        .to_path_buf();
    let out_dir = PathBuf::from(env::var("OUT_DIR").unwrap());
    let target_os = env::var("CARGO_CFG_TARGET_OS").unwrap_or_default();
    let target_arch = env::var("CARGO_CFG_TARGET_ARCH").unwrap_or_default();

    // 1. Always build vendored fixed-point libopus 1.5.2 (for both host tests and target).
    let opus_root = repo_root.join("third_party/opus");
    let opus_files = collect_opus_sources(&opus_root);
    let mut opus_build = cc::Build::new();
    opus_build
        .warnings(false)
        .opt_level(2)
        .define("OPUS_BUILD", None)
        .define("FIXED_POINT", "1")
        .define("DISABLE_FLOAT_API", None)
        .define("USE_ALLOCA", None)
        .define("HAVE_LRINTF", None)
        .define("HAVE_LRINT", None)
        .include(opus_root.join("include"))
        .include(opus_root.join("celt"))
        .include(opus_root.join("silk"))
        .include(opus_root.join("silk/fixed"))
        .include(&opus_root);

    if target_arch == "arm" {
        // Cortex-A7 supports ARMv7-A + VFPv4 + NEON; keep fixed-point portable C clean and fast.
        opus_build.flag_if_supported("-mcpu=cortex-a7");
    }

    for f in &opus_files {
        opus_build.file(f);
    }
    // Thin C shim for opus_encoder_ctl / opus_decoder_ctl variadic macros.
    let opus_shim = manifest_dir.join("csrc/opus_shim.c");
    println!("cargo:rerun-if-changed={}", opus_shim.display());
    opus_build.file(&opus_shim);
    opus_build.compile("airsim_opus");

    // 2. On Linux targets, build TinyALSA (with exact pcm_state sync_ptr fix) + eg25/audio/route.c + alsa shim.
    if target_os == "linux" {
        let tinyalsa_root = repo_root.join("module/rm500/audio/vendor/tinyalsa");
        let patched_pcm = prepare_patched_tinyalsa_pcm(&tinyalsa_root, &out_dir);
        let eg25_route = repo_root.join("module/eg25/audio/route.c");
        let alsa_shim = manifest_dir.join("csrc/alsa_shim.c");
        println!("cargo:rerun-if-changed={}", eg25_route.display());
        println!("cargo:rerun-if-changed={}", alsa_shim.display());

        let mut alsa_build = cc::Build::new();
        alsa_build
            .warnings(false)
            .opt_level(2)
            .flag_if_supported("-std=c11")
            .define("_GNU_SOURCE", None)
            .define("_POSIX_C_SOURCE", "200809L")
            .include(tinyalsa_root.join("include"))
            .include(tinyalsa_root.join("src"))
            .include(repo_root.join("module/eg25/audio"))
            .file(&patched_pcm)
            .file(tinyalsa_root.join("src/pcm_hw.c"))
            .file(tinyalsa_root.join("src/limits.c"))
            .file(tinyalsa_root.join("src/snd_card_plugin.c"))
            .file(&eg25_route)
            .file(&alsa_shim);

        if target_arch == "arm" {
            alsa_build.flag_if_supported("-mcpu=cortex-a7");
        }
        alsa_build.compile("airsim_alsa");
    }
}
