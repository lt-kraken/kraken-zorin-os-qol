use serde_json::Value;
use std::env;
use std::fs;
use std::path::{Path, PathBuf};
use std::process::{Child, Command, Output, Stdio};

const MANAGED_PATHS: &[&str] = &[
    "/org/gnome/shell/",
    "/org/gnome/desktop/wm/keybindings/",
    "/org/gnome/settings-daemon/plugins/media-keys/",
    "/org/gnome/desktop/notifications/",
    "/org/gnome/shell/extensions/clipboard-indicator/",
    "/org/gnome/shell/extensions/search-light/",
];

#[derive(Clone, Debug)]
pub struct AudioProfile {
    pub index: u32,
    pub name: String,
}

#[derive(Clone, Debug)]
pub struct AudioDevice {
    pub description: String,
    pub profiles: Vec<AudioProfile>,
}

#[derive(Clone, Debug)]
pub struct SetupProfile {
    pub name: String,
    pub clipboard_enabled: bool,
    pub search_enabled: bool,
    pub focus_shortcut_enabled: bool,
    pub clear_clipboard_at_login: bool,
}

fn command(program: &str, args: &[&str]) -> Output {
    let mut invocation = if env::var_os("FLATPAK_ID").is_some() && program != "flatpak-spawn" {
        let mut command = Command::new("flatpak-spawn");
        command.arg("--host").arg(program);
        command
    } else {
        Command::new(program)
    };
    invocation
        .args(args)
        .output()
        .unwrap_or_else(|error| Output {
            status: std::process::ExitStatus::default(),
            stdout: Vec::new(),
            stderr: error.to_string().into_bytes(),
        })
}

fn run(program: &str, args: &[&str]) -> Result<String, String> {
    let output = command(program, args);
    if !output.status.success() {
        return Err(String::from_utf8_lossy(&output.stderr).trim().to_owned());
    }
    Ok(String::from_utf8_lossy(&output.stdout).trim().to_owned())
}

pub fn gsettings_get(schema: &str, key: &str) -> Option<String> {
    run("gsettings", &["get", schema, key]).ok()
}

pub fn gsettings_set(schema: &str, key: &str, value: &str) -> Result<(), String> {
    run("gsettings", &["set", schema, key, value]).map(|_| ())
}

pub fn extension_enabled(uuid: &str) -> bool {
    run("gnome-extensions", &["info", uuid])
        .map(|output| output.lines().any(|line| line.trim() == "Enabled: Yes"))
        .unwrap_or(false)
}

pub fn extension_installed(uuid: &str) -> bool {
    command("gnome-extensions", &["info", uuid])
        .status
        .success()
}

pub fn set_extension_enabled(uuid: &str, enabled: bool) -> Result<(), String> {
    if enabled {
        ensure_extension(uuid)
    } else if extension_installed(uuid) {
        run("gnome-extensions", &["disable", uuid]).map(|_| ())
    } else {
        Ok(())
    }
}

pub fn extension_setting(uuid: &str, key: &str) -> Option<String> {
    let schema = match uuid {
        "clipboard-indicator@tudmotu.com" => "org.gnome.shell.extensions.clipboard-indicator",
        "search-light@icedman.github.com" => "org.gnome.shell.extensions.search-light",
        _ => return None,
    };
    let schema_dir = home_dir()
        .join(".local/share/gnome-shell/extensions")
        .join(uuid)
        .join("schemas");
    let schema_dir = schema_dir.to_string_lossy().to_string();
    run(
        "gsettings",
        &["--schemadir", &schema_dir, "get", schema, key],
    )
    .ok()
}

pub fn set_extension_setting(uuid: &str, key: &str, value: &str) -> Result<(), String> {
    let schema = match uuid {
        "clipboard-indicator@tudmotu.com" => "org.gnome.shell.extensions.clipboard-indicator",
        "search-light@icedman.github.com" => "org.gnome.shell.extensions.search-light",
        _ => return Err(format!("Unknown extension schema for {uuid}")),
    };
    let schema_dir = home_dir()
        .join(".local/share/gnome-shell/extensions")
        .join(uuid)
        .join("schemas");
    let schema_dir = schema_dir.to_string_lossy().to_string();
    run(
        "gsettings",
        &["--schemadir", &schema_dir, "set", schema, key, value],
    )
    .map(|_| ())
}

pub fn focus_shortcut_enabled() -> bool {
    gsettings_get(
        "org.gnome.settings-daemon.plugins.media-keys",
        "custom-keybindings",
    )
    .is_some_and(|value| value.contains("zorin-focus-toggle"))
}

pub fn setup_focus_shortcut() -> Result<(), String> {
    const SHORTCUT_PATH: &str =
        "/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/zorin-focus-toggle/";
    const UUID: &str = "org.gnome.settings-daemon.plugins.media-keys.custom-keybinding";
    let helper = home_dir().join(".local/bin/zorin-toggle-focus");
    if let Some(parent) = helper.parent() {
        fs::create_dir_all(parent).map_err(|error| error.to_string())?;
    }
    fs::write(&helper, include_str!("../../toggle-focus-mode.sh"))
        .map_err(|error| error.to_string())?;
    use std::os::unix::fs::PermissionsExt;
    fs::set_permissions(&helper, fs::Permissions::from_mode(0o755))
        .map_err(|error| error.to_string())?;

    let current = gsettings_get(
        "org.gnome.settings-daemon.plugins.media-keys",
        "custom-keybindings",
    )
    .unwrap_or_else(|| "[]".to_owned());
    let mut paths = current
        .trim_matches(['[', ']'])
        .split(',')
        .map(|path| path.trim().trim_matches('\'').to_owned())
        .filter(|path| !path.is_empty())
        .collect::<Vec<_>>();
    if !paths.iter().any(|path| path == SHORTCUT_PATH) {
        paths.push(SHORTCUT_PATH.to_owned());
    }
    let variant = format!(
        "[{}]",
        paths
            .iter()
            .map(|path| format!("'{path}'"))
            .collect::<Vec<_>>()
            .join(", ")
    );
    gsettings_set(
        "org.gnome.settings-daemon.plugins.media-keys",
        "custom-keybindings",
        &variant,
    )?;
    run(
        "gsettings",
        &["--path", SHORTCUT_PATH, "set", UUID, "name", "'Focus mode'"],
    )?;
    run(
        "gsettings",
        &[
            "--path",
            SHORTCUT_PATH,
            "set",
            UUID,
            "command",
            &format!("'{}'", helper.display()),
        ],
    )?;
    run(
        "gsettings",
        &[
            "--path",
            SHORTCUT_PATH,
            "set",
            UUID,
            "binding",
            "'<Super><Shift>f'",
        ],
    )?;
    Ok(())
}

pub fn remove_focus_shortcut() -> Result<(), String> {
    const SHORTCUT_PATH: &str =
        "/org/gnome/settings-daemon/plugins/media-keys/custom-keybindings/zorin-focus-toggle/";
    let current = gsettings_get(
        "org.gnome.settings-daemon.plugins.media-keys",
        "custom-keybindings",
    )
    .unwrap_or_else(|| "[]".to_owned());
    let paths = current
        .trim_matches(['[', ']'])
        .split(',')
        .map(|path| path.trim().trim_matches('\'').to_owned())
        .filter(|path| !path.is_empty() && path != SHORTCUT_PATH)
        .collect::<Vec<_>>();
    let variant = format!(
        "[{}]",
        paths
            .iter()
            .map(|path| format!("'{path}'"))
            .collect::<Vec<_>>()
            .join(", ")
    );
    gsettings_set(
        "org.gnome.settings-daemon.plugins.media-keys",
        "custom-keybindings",
        &variant,
    )?;
    let helper = home_dir().join(".local/bin/zorin-toggle-focus");
    if helper.exists() {
        fs::remove_file(helper).map_err(|error| error.to_string())?;
    }
    Ok(())
}

pub fn ensure_extension(uuid: &str) -> Result<(), String> {
    if extension_installed(uuid) {
        if !extension_enabled(uuid) {
            run("gnome-extensions", &["enable", uuid])?;
        }
        return Ok(());
    }

    let shell = run("gnome-shell", &["--version"])?;
    let major = shell
        .split_whitespace()
        .last()
        .unwrap_or("46")
        .split('.')
        .next()
        .unwrap_or("46");
    let metadata = run(
        "curl",
        &[
            "-fLsSG",
            "--max-time",
            "45",
            "--data-urlencode",
            &format!("uuid={uuid}"),
            "--data-urlencode",
            &format!("shell_version={major}"),
            "https://extensions.gnome.org/extension-info/",
        ],
    )?;
    let metadata: Value = serde_json::from_str(&metadata).map_err(|error| error.to_string())?;
    let version_map = metadata
        .get("shell_version_map")
        .and_then(Value::as_object)
        .ok_or_else(|| "The extension catalog returned no compatible versions.".to_owned())?;
    if !version_map.contains_key(major) {
        return Err(format!("No version of {uuid} supports GNOME {major}."));
    }
    let download_url = metadata
        .get("download_url")
        .and_then(Value::as_str)
        .ok_or_else(|| "The extension catalog did not provide a download URL.".to_owned())?;

    let cache = home_dir()
        .join(".cache/zorin-setup/extensions")
        .join(format!("{uuid}.zip"));
    if let Some(parent) = cache.parent() {
        fs::create_dir_all(parent).map_err(|error| error.to_string())?;
    }
    let url = format!("https://extensions.gnome.org{download_url}");
    let cache_arg = cache.to_string_lossy().to_string();
    run(
        "curl",
        &["-fLsS", "--max-time", "60", &url, "-o", &cache_arg],
    )?;
    let cache_arg = cache.to_string_lossy().to_string();
    run("gnome-extensions", &["install", "--force", &cache_arg])?;
    run("gnome-extensions", &["enable", uuid])?;
    Ok(())
}

pub fn local_send_installed() -> bool {
    command(
        "flatpak",
        &["info", "--user", "org.localsend.localsend_app"],
    )
    .status
    .success()
        || command(
            "flatpak",
            &["info", "--system", "org.localsend.localsend_app"],
        )
        .status
        .success()
}

pub fn load_setup_profiles() -> Result<Vec<SetupProfile>, String> {
    let path = setup_profiles_path();
    let contents = match fs::read_to_string(path) {
        Ok(contents) => contents,
        Err(error) if error.kind() == std::io::ErrorKind::NotFound => return Ok(Vec::new()),
        Err(error) => return Err(error.to_string()),
    };
    parse_setup_profiles(&contents)
}

pub fn save_setup_profiles(profiles: &[SetupProfile]) -> Result<(), String> {
    let path = setup_profiles_path();
    let parent = path
        .parent()
        .ok_or_else(|| "Could not determine the profile directory.".to_owned())?;
    fs::create_dir_all(parent).map_err(|error| error.to_string())?;
    let data = profiles
        .iter()
        .map(|profile| {
            serde_json::json!({
                "name": profile.name,
                "clipboard_enabled": profile.clipboard_enabled,
                "search_enabled": profile.search_enabled,
                "focus_shortcut_enabled": profile.focus_shortcut_enabled,
                "clear_clipboard_at_login": profile.clear_clipboard_at_login,
            })
        })
        .collect::<Vec<_>>();
    let contents = serde_json::to_vec_pretty(&data).map_err(|error| error.to_string())?;
    let temporary_path = path.with_extension("json.tmp");
    fs::write(&temporary_path, contents).map_err(|error| error.to_string())?;
    fs::rename(temporary_path, path).map_err(|error| error.to_string())
}

fn setup_profiles_path() -> PathBuf {
    home_dir().join(".config/zorin-personal-setup/profiles.json")
}

fn parse_setup_profiles(contents: &str) -> Result<Vec<SetupProfile>, String> {
    let values: Vec<Value> = serde_json::from_str(contents).map_err(|error| error.to_string())?;
    values
        .iter()
        .map(|value| {
            let field = |name| {
                value
                    .get(name)
                    .ok_or_else(|| format!("Profile is missing {name}."))
            };
            Ok(SetupProfile {
                name: field("name")?
                    .as_str()
                    .ok_or_else(|| "Profile name must be text.".to_owned())?
                    .to_owned(),
                clipboard_enabled: field("clipboard_enabled")?
                    .as_bool()
                    .ok_or_else(|| "Profile clipboard setting must be a boolean.".to_owned())?,
                search_enabled: field("search_enabled")?
                    .as_bool()
                    .ok_or_else(|| "Profile search setting must be a boolean.".to_owned())?,
                focus_shortcut_enabled: field("focus_shortcut_enabled")?
                    .as_bool()
                    .ok_or_else(|| "Profile shortcut setting must be a boolean.".to_owned())?,
                clear_clipboard_at_login: field("clear_clipboard_at_login")?
                    .as_bool()
                    .ok_or_else(|| "Profile privacy setting must be a boolean.".to_owned())?,
            })
        })
        .collect()
}

pub fn start_awake(duration_seconds: u32) -> Result<Child, String> {
    if !(60..=14_400).contains(&duration_seconds) {
        return Err("Choose a duration between 1 minute and 4 hours.".to_owned());
    }
    let duration = duration_seconds.to_string();
    let mut invocation = if env::var_os("FLATPAK_ID").is_some() {
        let mut command = Command::new("flatpak-spawn");
        command.arg("--host").arg("systemd-inhibit");
        command
    } else {
        Command::new("systemd-inhibit")
    };
    invocation
        .args([
            "--what=sleep",
            "--mode=block",
            "--who=Zorin Personal Setup",
            "--why=Temporary keep-awake request",
            "sleep",
            &duration,
        ])
        .stdin(Stdio::null())
        .stdout(Stdio::null())
        .stderr(Stdio::null())
        .spawn()
        .map_err(|error| format!("Could not start temporary keep-awake mode: {error}"))
}

pub fn install_local_send() -> Result<(), String> {
    if local_send_installed() {
        return Ok(());
    }
    let remotes = run("flatpak", &["remotes", "--user", "--columns=name"]).unwrap_or_default();
    if !remotes.lines().any(|name| name.trim() == "flathub") {
        run(
            "flatpak",
            &[
                "remote-add",
                "--user",
                "--if-not-exists",
                "flathub",
                "https://flathub.org/repo/flathub.flatpakrepo",
            ],
        )?;
    }
    run(
        "flatpak",
        &[
            "install",
            "--user",
            "--noninteractive",
            "--assumeyes",
            "flathub",
            "org.localsend.localsend_app",
        ],
    )?;
    Ok(())
}

pub fn launch_local_send() -> Result<(), String> {
    spawn("flatpak", &["run", "org.localsend.localsend_app"])
}

fn spawn(program: &str, args: &[&str]) -> Result<(), String> {
    let mut invocation = if env::var_os("FLATPAK_ID").is_some() {
        let mut command = Command::new("flatpak-spawn");
        command.arg("--host").arg(program);
        command
    } else {
        Command::new(program)
    };
    invocation
        .args(args)
        .spawn()
        .map(|_| ())
        .map_err(|error| error.to_string())
}

pub fn audio_devices() -> Result<Vec<AudioDevice>, String> {
    let dump = run("pw-dump", &[])?;
    let objects: Vec<Value> = serde_json::from_str(&dump).map_err(|error| error.to_string())?;
    let mut devices = Vec::new();

    for object in objects {
        if object.get("type").and_then(Value::as_str) != Some("PipeWire:Interface:Device") {
            continue;
        }
        let props = match object.get("info").and_then(|info| info.get("props")) {
            Some(props)
                if props.get("media.class").and_then(Value::as_str) == Some("Audio/Device") =>
            {
                props
            }
            _ => continue,
        };
        let id = match object.get("id").and_then(Value::as_u64) {
            Some(id) => id.to_string(),
            None => continue,
        };
        let description = props
            .get("device.description")
            .and_then(Value::as_str)
            .unwrap_or("Audio device")
            .to_owned();
        let profile_dump = run("pw-cli", &["enum-params", &id, "EnumProfile"])?;
        let profiles = parse_profiles(&profile_dump);
        devices.push(AudioDevice {
            description,
            profiles,
        });
    }
    devices.sort_by(|left, right| left.description.cmp(&right.description));
    Ok(devices)
}

fn parse_profiles(text: &str) -> Vec<AudioProfile> {
    let mut result = Vec::new();
    let mut index = None;
    let mut name = None;
    let mut available = true;

    for line in text.lines() {
        let trimmed = line.trim();
        if trimmed.starts_with("Object: size") && (index.is_some() || name.is_some()) {
            push_profile(&mut result, index.take(), name.take(), available);
            available = true;
        }
        if trimmed.contains("Profile:index") {
            index = None;
        } else if trimmed.starts_with("Int ") && index.is_none() && name.is_none() {
            index = trimmed
                .strip_prefix("Int ")
                .and_then(|value| value.parse().ok());
        }
        if trimmed.contains("Profile:name") {
            name = None;
        } else if trimmed.starts_with("String ") && name.is_none() {
            name = Some(unquote(trimmed.strip_prefix("String ").unwrap_or_default()));
        }
        if trimmed.contains("ParamAvailability:no") {
            available = false;
        }
    }
    push_profile(&mut result, index, name, available);
    result
}

fn push_profile(
    profiles: &mut Vec<AudioProfile>,
    index: Option<u32>,
    name: Option<String>,
    available: bool,
) {
    let (Some(index), Some(name)) = (index, name) else {
        return;
    };
    if !available {
        return;
    }
    profiles.push(AudioProfile { index, name });
}

fn unquote(value: &str) -> String {
    value.trim().trim_matches('"').to_owned()
}

fn find_device_id(description: &str) -> Result<String, String> {
    let dump = run("pw-dump", &[])?;
    let objects: Vec<Value> = serde_json::from_str(&dump).map_err(|error| error.to_string())?;
    objects
        .into_iter()
        .find(|object| {
            object.get("type").and_then(Value::as_str) == Some("PipeWire:Interface:Device")
                && object
                    .get("info")
                    .and_then(|info| info.get("props"))
                    .is_some_and(|props| {
                        props.get("media.class").and_then(Value::as_str) == Some("Audio/Device")
                            && props.get("device.description").and_then(Value::as_str)
                                == Some(description)
                    })
        })
        .and_then(|object| object.get("id").and_then(Value::as_u64))
        .map(|id| id.to_string())
        .ok_or_else(|| format!("Audio device not found: {description}"))
}

pub fn create_backup() -> Result<PathBuf, String> {
    let timestamp = run("date", &["-u", "+%Y%m%dT%H%M%SZ"])?;
    let root = home_dir().join(".local/state/zorin-setup/backups");
    let backup = root.join(timestamp);
    fs::create_dir_all(&backup).map_err(|error| error.to_string())?;

    let mut paths = String::new();
    for path in MANAGED_PATHS {
        let output = run("dconf", &["dump", path])?;
        let filename = format!("{}.dconf", path.trim_matches('/').replace('/', "_"));
        fs::write(backup.join(filename), output).map_err(|error| error.to_string())?;
        paths.push_str(path);
        paths.push('\n');
    }
    fs::write(backup.join("dconf-paths.txt"), paths).map_err(|error| error.to_string())?;
    let profiles = setup_profiles_path();
    if profiles.exists() {
        fs::copy(profiles, backup.join("profiles.json")).map_err(|error| error.to_string())?;
        fs::write(backup.join("profiles-present.txt"), "true")
            .map_err(|error| error.to_string())?;
    } else {
        fs::write(backup.join("profiles-present.txt"), "false")
            .map_err(|error| error.to_string())?;
    }

    Ok(backup)
}

pub fn backup_list() -> Result<Vec<PathBuf>, String> {
    let root = home_dir().join(".local/state/zorin-setup/backups");
    if !root.exists() {
        return Ok(Vec::new());
    }
    let mut backups = fs::read_dir(root)
        .map_err(|error| error.to_string())?
        .filter_map(Result::ok)
        .map(|entry| entry.path())
        .filter(|path| path.is_dir())
        .collect::<Vec<_>>();
    backups.sort_by_key(|path| path.file_name().map(|name| name.to_os_string()));
    backups.reverse();
    Ok(backups)
}

pub fn restore_backup(backup: &Path) -> Result<(), String> {
    let paths_file = backup.join("dconf-paths.txt");
    if paths_file.exists() {
        let paths = fs::read_to_string(paths_file).map_err(|error| error.to_string())?;
        for path in paths.lines().filter(|path| path.starts_with('/')) {
            run("dconf", &["reset", "-f", path])?;
            let filename = format!("{}.dconf", path.trim_matches('/').replace('/', "_"));
            let contents =
                fs::read_to_string(backup.join(filename)).map_err(|error| error.to_string())?;
            pipe_to("dconf", &["load", path], contents.as_bytes())?;
        }
    } else {
        for (path, filename) in [
            ("/org/gnome/shell/", "gnome-shell.dconf"),
            (
                "/org/gnome/desktop/wm/keybindings/",
                "window-keybindings.dconf",
            ),
        ] {
            let contents = match fs::read(backup.join(filename)) {
                Ok(contents) => contents,
                Err(error) if error.kind() == std::io::ErrorKind::NotFound => continue,
                Err(error) => return Err(error.to_string()),
            };
            pipe_to("dconf", &["load", path], &contents)?;
        }
    }

    let audio_file = backup.join("audio-profiles.tsv");
    if audio_file.exists() {
        let contents = fs::read_to_string(audio_file).map_err(|error| error.to_string())?;
        for line in contents.lines() {
            let Some((description, profile)) = line.split_once('\t') else {
                continue;
            };
            let device = audio_devices()?
                .into_iter()
                .find(|device| device.description == description);
            if let Some(device) = device {
                if let Some(profile) = device.profiles.iter().find(|item| item.name == profile) {
                    let id = find_device_id(description)?;
                    run("wpctl", &["set-profile", &id, &profile.index.to_string()])?;
                }
            }
        }
    }
    let profile_backup = backup.join("profiles.json");
    let profiles_present = backup.join("profiles-present.txt");
    if profiles_present.exists() {
        let profile_path = setup_profiles_path();
        if fs::read_to_string(profiles_present)
            .map_err(|error| error.to_string())?
            .trim()
            == "true"
        {
            if let Some(parent) = profile_path.parent() {
                fs::create_dir_all(parent).map_err(|error| error.to_string())?;
            }
            fs::copy(profile_backup, profile_path).map_err(|error| error.to_string())?;
        } else if profile_path.exists() {
            fs::remove_file(profile_path).map_err(|error| error.to_string())?;
        }
    }
    Ok(())
}

fn pipe_to(program: &str, args: &[&str], input: &[u8]) -> Result<(), String> {
    if env::var_os("FLATPAK_ID").is_some() {
        let mut child = Command::new("flatpak-spawn")
            .args(["--host", program])
            .args(args)
            .stdin(std::process::Stdio::piped())
            .spawn()
            .map_err(|error| error.to_string())?;
        use std::io::Write;
        if let Some(stdin) = child.stdin.as_mut() {
            stdin.write_all(input).map_err(|error| error.to_string())?;
        }
        let status = child.wait().map_err(|error| error.to_string())?;
        return if status.success() {
            Ok(())
        } else {
            Err(format!("{program} failed"))
        };
    }
    let mut child = Command::new(program)
        .args(args)
        .stdin(std::process::Stdio::piped())
        .spawn()
        .map_err(|error| error.to_string())?;
    use std::io::Write;
    if let Some(stdin) = child.stdin.as_mut() {
        stdin.write_all(input).map_err(|error| error.to_string())?;
    }
    let status = child.wait().map_err(|error| error.to_string())?;
    if status.success() {
        Ok(())
    } else {
        Err(format!("{program} failed"))
    }
}

fn home_dir() -> PathBuf {
    env::var_os("HOME")
        .map(PathBuf::from)
        .unwrap_or_else(|| Path::new("/").to_path_buf())
}

#[cfg(test)]
mod tests {
    use super::{parse_profiles, parse_setup_profiles};

    #[test]
    fn parses_audio_profiles_for_legacy_restore() {
        let input = r#"
  Object: size 440, type Spa:Pod:Object:Param:Profile (262151), id Spa:Enum:ParamId:EnumProfile (8)
    Prop: key Spa:Pod:Object:Param:Profile:index (1), flags 00000000
      Int 1
    Prop: key Spa:Pod:Object:Param:Profile:name (2), flags 00000000
      String "output:analog-stereo+input:analog-stereo"
    Prop: key Spa:Pod:Object:Param:Profile:description (3), flags 00000000
      String "Analog Stereo Duplex"
    Prop: key Spa:Pod:Object:Param:Profile:available (5), flags 00000000
      Id 2        (Spa:Enum:ParamAvailability:yes)
"#;
        let profiles = parse_profiles(input);
        assert_eq!(profiles.len(), 1);
        assert_eq!(profiles[0].index, 1);
        assert_eq!(profiles[0].name, "output:analog-stereo+input:analog-stereo");
    }

    #[test]
    fn parses_setup_profiles() {
        let profiles = parse_setup_profiles(
            r#"[{"name":"Focus","clipboard_enabled":false,"search_enabled":true,"focus_shortcut_enabled":true,"clear_clipboard_at_login":true}]"#,
        )
        .unwrap();
        assert_eq!(profiles.len(), 1);
        assert_eq!(profiles[0].name, "Focus");
        assert!(!profiles[0].clipboard_enabled);
        assert!(profiles[0].search_enabled);
        assert!(profiles[0].focus_shortcut_enabled);
        assert!(profiles[0].clear_clipboard_at_login);
    }
}
