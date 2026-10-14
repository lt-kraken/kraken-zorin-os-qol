use crate::backend::{self, SetupProfile};
use adw::prelude::*;
use std::cell::RefCell;
use std::path::PathBuf;
use std::rc::Rc;
use std::sync::mpsc;
use std::time::Duration;

const CLIPBOARD_UUID: &str = "clipboard-indicator@tudmotu.com";
const SEARCH_UUID: &str = "search-light@icedman.github.com";
#[derive(Clone)]
enum ToggleAction {
    ClipboardExtension,
    SpotlightExtension,
    FocusShortcut,
    ClipboardPrivacy,
}

#[derive(Clone)]
struct ToggleControl {
    row: adw::SwitchRow,
    action: ToggleAction,
}

#[derive(Clone)]
enum Change {
    Extension {
        uuid: String,
        enabled: bool,
    },
    ExtensionSetting {
        uuid: String,
        key: String,
        value: String,
        label: String,
    },
    FocusShortcut(bool),
}

impl Change {
    fn description(&self) -> String {
        match self {
            Self::ExtensionSetting { label, .. } => label.clone(),
            Self::Extension { uuid, enabled } => {
                format!("{uuid}: {}", if *enabled { "Enable" } else { "Disable" })
            }
            Self::FocusShortcut(enabled) => format!(
                "Focus mode shortcut: {}",
                if *enabled { "Install" } else { "Remove" }
            ),
        }
    }
}

fn switch_row(title: &str, subtitle: &str, active: bool) -> adw::SwitchRow {
    adw::SwitchRow::builder()
        .title(title)
        .subtitle(subtitle)
        .active(active)
        .build()
}

fn preferences_group(title: &str, description: &str) -> adw::PreferencesGroup {
    adw::PreferencesGroup::builder()
        .title(title)
        .description(description)
        .build()
}

fn add_action_row(group: &adw::PreferencesGroup, title: &str, subtitle: &str) -> adw::ActionRow {
    let row = adw::ActionRow::builder()
        .title(title)
        .subtitle(subtitle)
        .build();
    group.add(&row);
    row
}

fn add_switch(
    group: &adw::PreferencesGroup,
    title: &str,
    subtitle: &str,
    active: bool,
    action: ToggleAction,
    controls: &Rc<RefCell<Vec<ToggleControl>>>,
) -> adw::SwitchRow {
    let row = switch_row(title, subtitle, active);
    group.add(&row);
    controls.borrow_mut().push(ToggleControl {
        row: row.clone(),
        action,
    });
    row
}

fn profile_from_controls(name: String, controls: &[ToggleControl]) -> SetupProfile {
    let mut profile = SetupProfile {
        name,
        clipboard_enabled: false,
        search_enabled: false,
        focus_shortcut_enabled: false,
        clear_clipboard_at_login: false,
    };
    for control in controls {
        match control.action {
            ToggleAction::ClipboardExtension => {
                profile.clipboard_enabled = control.row.is_active();
            }
            ToggleAction::SpotlightExtension => {
                profile.search_enabled = control.row.is_active();
            }
            ToggleAction::FocusShortcut => {
                profile.focus_shortcut_enabled = control.row.is_active();
            }
            ToggleAction::ClipboardPrivacy => {
                profile.clear_clipboard_at_login = control.row.is_active();
            }
        }
    }
    profile
}

fn stage_profile(profile: &SetupProfile, controls: &[ToggleControl]) {
    for control in controls {
        let active = match control.action {
            ToggleAction::ClipboardExtension => profile.clipboard_enabled,
            ToggleAction::SpotlightExtension => profile.search_enabled,
            ToggleAction::FocusShortcut => profile.focus_shortcut_enabled,
            ToggleAction::ClipboardPrivacy => profile.clear_clipboard_at_login,
        };
        control.row.set_active(active);
    }
}

fn refresh_profile_dropdown(
    dropdown: &gtk::DropDown,
    stage_button: &gtk::Button,
    delete_button: &gtk::Button,
    profiles: &[SetupProfile],
) {
    let names = profiles
        .iter()
        .map(|profile| profile.name.as_str())
        .collect::<Vec<_>>();
    dropdown.set_model(Some(&gtk::StringList::new(&names)));
    dropdown.set_selected(0);
    dropdown.set_sensitive(!profiles.is_empty());
    stage_button.set_sensitive(!profiles.is_empty());
    delete_button.set_sensitive(!profiles.is_empty());
}

fn save_profile(
    profile: SetupProfile,
    profiles: &Rc<RefCell<Vec<SetupProfile>>>,
    dropdown: &gtk::DropDown,
    stage_button: &gtk::Button,
    delete_button: &gtk::Button,
) -> Result<(), String> {
    let mut updated = profiles.borrow().clone();
    if let Some(existing) = updated
        .iter_mut()
        .find(|item| item.name.eq_ignore_ascii_case(&profile.name))
    {
        *existing = profile;
    } else {
        updated.push(profile);
    }
    backend::save_setup_profiles(&updated)?;
    *profiles.borrow_mut() = updated;
    refresh_profile_dropdown(dropdown, stage_button, delete_button, &profiles.borrow());
    Ok(())
}

fn delete_profile(
    index: usize,
    profiles: &Rc<RefCell<Vec<SetupProfile>>>,
    dropdown: &gtk::DropDown,
    stage_button: &gtk::Button,
    delete_button: &gtk::Button,
) -> Result<(), String> {
    let mut updated = profiles.borrow().clone();
    if index >= updated.len() {
        return Err("No profile is selected.".to_owned());
    }
    updated.remove(index);
    backend::save_setup_profiles(&updated)?;
    *profiles.borrow_mut() = updated;
    refresh_profile_dropdown(dropdown, stage_button, delete_button, &profiles.borrow());
    Ok(())
}

fn page(title: &str, description: &str) -> gtk::Box {
    let content = gtk::Box::new(gtk::Orientation::Vertical, 20);
    content.set_margin_top(28);
    content.set_margin_bottom(32);
    content.set_margin_start(36);
    content.set_margin_end(36);
    content.set_hexpand(true);
    content.set_halign(gtk::Align::Start);

    let heading = gtk::Label::builder()
        .label(title)
        .xalign(0.0)
        .css_classes(["title-1"])
        .build();
    let subtitle = gtk::Label::builder()
        .label(description)
        .xalign(0.0)
        .wrap(true)
        .css_classes(["dim-label"])
        .build();
    content.append(&heading);
    content.append(&subtitle);
    content
}

fn add_scrolled_page(stack: &gtk::Stack, name: &str, title: &str, content: &gtk::Box) {
    let scrolled = gtk::ScrolledWindow::builder()
        .hexpand(true)
        .vexpand(true)
        .hscrollbar_policy(gtk::PolicyType::Never)
        .vscrollbar_policy(gtk::PolicyType::Automatic)
        .min_content_height(0)
        .propagate_natural_height(false)
        .child(content)
        .build();
    stack.add_titled(&scrolled, Some(name), title);
}

fn build_window(app: &adw::Application) {
    let window = adw::ApplicationWindow::builder()
        .application(app)
        .title("Zorin Personal Setup")
        .default_width(980)
        .default_height(640)
        .build();

    let controls = Rc::new(RefCell::new(Vec::<ToggleControl>::new()));
    let (loaded_profiles, profile_load_error) = match backend::load_setup_profiles() {
        Ok(profiles) => (profiles, None),
        Err(error) => (Vec::new(), Some(error)),
    };
    let setup_profiles = Rc::new(RefCell::new(loaded_profiles));
    let awake_process = Rc::new(RefCell::new(None::<std::process::Child>));
    let backup_paths = Rc::new(RefCell::new(Vec::<PathBuf>::new()));
    let status = gtk::Label::builder()
        .label("Stage optional tools, save personal profiles, then review before applying.")
        .xalign(0.0)
        .hexpand(true)
        .ellipsize(gtk::pango::EllipsizeMode::End)
        .css_classes(["dim-label"])
        .build();
    if let Some(error) = profile_load_error {
        status.set_text(&format!("Could not load saved profiles: {error}"));
    }

    let toolbar = adw::ToolbarView::new();
    let header = adw::HeaderBar::new();
    header.set_title_widget(Some(&gtk::Label::new(Some("Zorin Setup"))));
    toolbar.add_top_bar(&header);

    let split = gtk::Box::new(gtk::Orientation::Horizontal, 0);
    let stack = gtk::Stack::builder()
        .hexpand(true)
        .vexpand(true)
        .transition_type(gtk::StackTransitionType::Crossfade)
        .build();
    let sidebar = gtk::StackSidebar::new();
    sidebar.set_stack(&stack);
    sidebar.set_width_request(190);
    split.append(&sidebar);

    let overview = page("Your Zorin desktop", "A considered set of desktop improvements. Current settings are shown; only changes you make will be applied.");
    let overview_group = preferences_group(
        "Setup",
        "Choose a section from the sidebar to review its settings.",
    );
    let overview_row = add_action_row(
        &overview_group,
        "Changes are staged",
        "Nothing is changed until you press Apply.",
    );
    overview_row.add_prefix(&gtk::Image::from_icon_name("emblem-ok-symbolic"));
    let backup_row = add_action_row(
        &overview_group,
        "Before every apply",
        "A timestamped snapshot of this tool's settings is saved before applying.",
    );
    backup_row.add_prefix(&gtk::Image::from_icon_name("document-save-symbolic"));
    overview.append(&overview_group);
    add_scrolled_page(&stack, "overview", "Overview", &overview);

    let profiles_page = page(
        "Profiles",
        "Save combinations of optional tools and stage them for review before applying.",
    );
    let profiles_group = preferences_group(
        "Personal profiles",
        "Profiles are stored in your user configuration and never apply automatically.",
    );
    let profile_name_row = add_action_row(&profiles_group, "Profile name", "Name this selection.");
    let profile_name = gtk::Entry::builder()
        .placeholder_text("For example, Work or Focus")
        .width_chars(24)
        .build();
    profile_name_row.add_suffix(&profile_name);
    let profile_save_row = add_action_row(
        &profiles_group,
        "Save current selection",
        "Save the staged switches as a reusable profile.",
    );
    let profile_save_button = gtk::Button::with_label("Save");
    profile_save_button.add_css_class("flat");
    profile_save_row.add_suffix(&profile_save_button);
    let profile_select_row = add_action_row(
        &profiles_group,
        "Saved profile",
        "Stage the selected profile; Apply changes still asks for confirmation.",
    );
    let profile_labels = setup_profiles
        .borrow()
        .iter()
        .map(|profile| profile.name.clone())
        .collect::<Vec<_>>();
    let profile_names = profile_labels
        .iter()
        .map(String::as_str)
        .collect::<Vec<_>>();
    let profile_dropdown = gtk::DropDown::from_strings(&profile_names);
    profile_dropdown.set_sensitive(!profile_names.is_empty());
    profile_dropdown.set_valign(gtk::Align::Center);
    profile_dropdown.set_width_request(190);
    profile_select_row.add_suffix(&profile_dropdown);
    let profile_stage_row = add_action_row(
        &profiles_group,
        "Stage profile",
        "Nothing changes until you confirm Apply changes.",
    );
    let profile_stage_button = gtk::Button::with_label("Stage");
    profile_stage_button.add_css_class("flat");
    profile_stage_button.set_sensitive(!profile_names.is_empty());
    profile_stage_row.add_suffix(&profile_stage_button);
    let profile_delete_button = gtk::Button::with_label("Delete");
    profile_delete_button.add_css_class("flat");
    profile_delete_button.set_sensitive(!profile_names.is_empty());
    profile_select_row.add_suffix(&profile_delete_button);
    profiles_page.append(&profiles_group);
    add_scrolled_page(&stack, "profiles", "Profiles", &profiles_page);

    let shortcuts = page("Shortcuts", "Bring familiar actions within easy reach.");
    let search_group = preferences_group(
        "Search and clipboard",
        "Optional GNOME Shell extensions, installed for this user.",
    );
    add_switch(
        &search_group,
        "Spotlight-style search",
        "Search apps and system items with Super + Space.",
        backend::extension_enabled(SEARCH_UUID),
        ToggleAction::SpotlightExtension,
        &controls,
    );
    add_switch(
        &search_group,
        "Clipboard history",
        "Browse recent copied items with Super + V.",
        backend::extension_enabled(CLIPBOARD_UUID),
        ToggleAction::ClipboardExtension,
        &controls,
    );
    shortcuts.append(&search_group);

    let focus_group = preferences_group(
        "Focus mode",
        "Pause notification banners with one shortcut.",
    );
    add_switch(
        &focus_group,
        "Super + Shift + F",
        "Install or remove the Focus mode toggle shortcut.",
        backend::focus_shortcut_enabled(),
        ToggleAction::FocusShortcut,
        &controls,
    );
    shortcuts.append(&focus_group);
    add_scrolled_page(&stack, "shortcuts", "Shortcuts", &shortcuts);

    let workflow = page(
        "Workflow",
        "Add temporary behavior and optional tools beyond Zorin's built-in settings.",
    );
    let awake_group = preferences_group(
        "Temporary keep-awake",
        "Prevent automatic sleep for a limited time. Your power settings stay unchanged.",
    );
    let awake_row = add_action_row(
        &awake_group,
        "Duration",
        "The sleep block ends automatically when the timer expires.",
    );
    let awake_options = ["30 minutes", "1 hour", "2 hours"];
    let awake_duration = gtk::DropDown::from_strings(&awake_options);
    awake_duration.set_valign(gtk::Align::Center);
    awake_duration.set_width_request(150);
    awake_row.add_suffix(&awake_duration);
    let awake_button = gtk::Button::with_label("Start");
    awake_button.add_css_class("flat");
    awake_row.add_suffix(&awake_button);
    workflow.append(&awake_group);

    let sharing = preferences_group(
        "iPhone file sharing",
        "Send files over your local Wi-Fi network.",
    );
    let localsend_row = add_action_row(
        &sharing,
        "LocalSend",
        if backend::local_send_installed() {
            "Installed and ready to send files over your local network."
        } else {
            "Send files between this computer and your iPhone over local Wi-Fi."
        },
    );
    localsend_row.add_prefix(&gtk::Image::from_icon_name("folder-download-symbolic"));
    let localsend_installed = backend::local_send_installed();
    let localsend_button = gtk::Button::with_label(if localsend_installed {
        "Open"
    } else {
        "Install"
    });
    localsend_button.add_css_class("flat");
    localsend_row.add_suffix(&localsend_button);
    let localsend_progress = gtk::ProgressBar::new();
    localsend_progress.set_width_request(150);
    localsend_progress.set_show_text(true);
    localsend_progress.set_text(Some("Installing"));
    localsend_progress.set_visible(false);
    localsend_row.add_suffix(&localsend_progress);
    workflow.append(&sharing);

    add_scrolled_page(&stack, "workflow", "Workflow", &workflow);

    let privacy = page("Privacy", "Control retention of clipboard history.");
    let clipboard = preferences_group(
        "Clipboard",
        "Copied content can include passwords and private messages.",
    );
    add_switch(
        &clipboard,
        "Clear history at login",
        "Clear Clipboard Indicator's saved history when your session starts.",
        backend::extension_setting(CLIPBOARD_UUID, "clear-on-boot").as_deref() == Some("true"),
        ToggleAction::ClipboardPrivacy,
        &controls,
    );
    privacy.append(&clipboard);

    add_scrolled_page(&stack, "privacy", "Privacy", &privacy);

    let backups = page(
        "Backups",
        "New snapshots contain settings and profiles managed by this tool. Older snapshots remain restorable.",
    );
    let backup_group = preferences_group(
        "Snapshots",
        "A new snapshot is created automatically before Apply.",
    );
    let create_backup_row = add_action_row(
        &backup_group,
        "Create snapshot",
        "Save the current managed settings now.",
    );
    let create_backup_button = gtk::Button::with_label("Create");
    create_backup_button.add_css_class("suggested-action");
    create_backup_row.add_suffix(&create_backup_button);
    let restore_row = add_action_row(
        &backup_group,
        "Restore snapshot",
        "Restore this tool's settings and profiles. Older snapshots may include desktop and audio settings.",
    );
    let backup_items = backend::backup_list().unwrap_or_default();
    let backup_labels = backup_items
        .iter()
        .map(|path| {
            path.file_name()
                .and_then(|name| name.to_str())
                .unwrap_or("Snapshot")
                .to_owned()
        })
        .collect::<Vec<_>>();
    let backup_refs = backup_labels.iter().map(String::as_str).collect::<Vec<_>>();
    let backup_dropdown = gtk::DropDown::from_strings(&backup_refs);
    backup_dropdown.set_sensitive(!backup_items.is_empty());
    restore_row.add_suffix(&backup_dropdown);
    let restore_button = gtk::Button::with_label("Restore");
    restore_button.add_css_class("destructive-action");
    restore_button.set_sensitive(!backup_items.is_empty());
    restore_row.add_suffix(&restore_button);
    *backup_paths.borrow_mut() = backup_items;
    backups.append(&backup_group);
    add_scrolled_page(&stack, "backups", "Backups", &backups);

    split.append(&stack);
    toolbar.set_content(Some(&split));

    let root = gtk::Box::new(gtk::Orientation::Vertical, 0);
    root.append(&toolbar);
    let footer = gtk::Box::new(gtk::Orientation::Horizontal, 12);
    footer.set_margin_top(12);
    footer.set_margin_bottom(12);
    footer.set_margin_start(18);
    footer.set_margin_end(18);
    status.set_hexpand(true);
    footer.append(&status);
    let apply_button = gtk::Button::with_label("Apply changes");
    apply_button.add_css_class("suggested-action");
    footer.append(&apply_button);
    root.append(&footer);
    window.set_content(Some(&root));

    let profile_save_status = status.clone();
    let profile_save_name = profile_name.clone();
    let profile_save_controls = controls.clone();
    let profile_save_list = setup_profiles.clone();
    let profile_save_dropdown = profile_dropdown.clone();
    let profile_save_stage_button = profile_stage_button.clone();
    let profile_save_delete_button = profile_delete_button.clone();
    let profile_save_window = window.clone();
    profile_save_button.connect_clicked(move |_| {
        let name = profile_save_name.text().trim().to_owned();
        if name.is_empty() {
            profile_save_status.set_text("Enter a name for this profile.");
            return;
        }
        let profile = profile_from_controls(name, &profile_save_controls.borrow());
        let replacing = profile_save_list
            .borrow()
            .iter()
            .any(|item| item.name.eq_ignore_ascii_case(&profile.name));
        let save_status = profile_save_status.clone();
        let save_list = profile_save_list.clone();
        let save_dropdown = profile_save_dropdown.clone();
        let save_stage_button = profile_save_stage_button.clone();
        let save_delete_button = profile_save_delete_button.clone();
        let save_action = move || match save_profile(
            profile.clone(),
            &save_list,
            &save_dropdown,
            &save_stage_button,
            &save_delete_button,
        ) {
            Ok(()) => save_status.set_text("Profile saved. It has not been applied."),
            Err(error) => save_status.set_text(&format!("Could not save profile: {error}")),
        };
        if replacing {
            confirm_dialog(
                &profile_save_window,
                "Replace this profile?",
                "The saved profile will be replaced with the current selection.",
                save_action,
            );
        } else {
            save_action();
        }
    });

    let profile_stage_status = status.clone();
    let profile_stage_controls = controls.clone();
    let profile_stage_list = setup_profiles.clone();
    let profile_stage_selection = profile_dropdown.clone();
    profile_stage_button.connect_clicked(move |_| {
        let selected = profile_stage_selection.selected() as usize;
        let profile = profile_stage_list.borrow().get(selected).cloned();
        if let Some(profile) = profile {
            stage_profile(&profile, &profile_stage_controls.borrow());
            profile_stage_status.set_text(&format!(
                "Profile '{}' staged. Review it, then apply changes.",
                profile.name
            ));
        } else {
            profile_stage_status.set_text("Select a saved profile first.");
        }
    });

    let profile_delete_status = status.clone();
    let profile_delete_list = setup_profiles.clone();
    let profile_delete_selection = profile_dropdown.clone();
    let profile_delete_stage_button = profile_stage_button.clone();
    let profile_delete_delete_button = profile_delete_button.clone();
    let profile_delete_window = window.clone();
    profile_delete_button.connect_clicked(move |_| {
        let selected = profile_delete_selection.selected() as usize;
        let profile_name = profile_delete_list
            .borrow()
            .get(selected)
            .map(|profile| profile.name.clone());
        let Some(profile_name) = profile_name else {
            profile_delete_status.set_text("Select a saved profile first.");
            return;
        };
        let delete_status = profile_delete_status.clone();
        let delete_list = profile_delete_list.clone();
        let delete_dropdown = profile_delete_selection.clone();
        let delete_stage_button = profile_delete_stage_button.clone();
        let delete_delete_button = profile_delete_delete_button.clone();
        confirm_dialog(
            &profile_delete_window,
            "Delete this profile?",
            &format!("The profile '{profile_name}' will be removed."),
            move || match delete_profile(
                selected,
                &delete_list,
                &delete_dropdown,
                &delete_stage_button,
                &delete_delete_button,
            ) {
                Ok(()) => delete_status.set_text("Profile deleted."),
                Err(error) => delete_status.set_text(&format!("Could not delete profile: {error}")),
            },
        );
    });

    let awake_status = status.clone();
    let awake_child = awake_process.clone();
    let awake_selector = awake_duration.clone();
    let awake_button_for_click = awake_button.clone();
    awake_button.connect_clicked(move |button| {
        if let Some(mut child) = awake_child.borrow_mut().take() {
            let _ = child.kill();
            let _ = child.wait();
            awake_selector.set_sensitive(true);
            button.set_label("Start");
            awake_status.set_text("Temporary keep-awake mode stopped.");
            return;
        }
        let duration_seconds = match awake_selector.selected() {
            0 => 30 * 60,
            1 => 60 * 60,
            _ => 2 * 60 * 60,
        };
        match backend::start_awake(duration_seconds) {
            Ok(child) => {
                *awake_child.borrow_mut() = Some(child);
                awake_selector.set_sensitive(false);
                button.set_label("Stop");
                awake_status.set_text(
                    "Computer will stay awake temporarily; the timer will release the request.",
                );

                let process_watch = awake_child.clone();
                let duration_watch = awake_selector.clone();
                let button_watch = awake_button_for_click.clone();
                let status_watch = awake_status.clone();
                glib::timeout_add_local(Duration::from_secs(1), move || {
                    let mut process = process_watch.borrow_mut();
                    let Some(child) = process.as_mut() else {
                        return glib::ControlFlow::Break;
                    };
                    match child.try_wait() {
                        Ok(Some(exit_status)) if exit_status.success() => {
                            *process = None;
                            duration_watch.set_sensitive(true);
                            button_watch.set_label("Start");
                            status_watch.set_text("Temporary keep-awake timer expired.");
                            glib::ControlFlow::Break
                        }
                        Ok(Some(_)) => {
                            *process = None;
                            duration_watch.set_sensitive(true);
                            button_watch.set_label("Start");
                            status_watch.set_text("The keep-awake request ended unexpectedly.");
                            glib::ControlFlow::Break
                        }
                        Ok(None) => glib::ControlFlow::Continue,
                        Err(error) => {
                            *process = None;
                            duration_watch.set_sensitive(true);
                            button_watch.set_label("Start");
                            status_watch.set_text(&format!("Keep-awake status failed: {error}"));
                            glib::ControlFlow::Break
                        }
                    }
                });
            }
            Err(error) => awake_status.set_text(&error),
        }
    });

    let awake_child_on_close = awake_process.clone();
    window.connect_close_request(move |_| {
        if let Some(mut child) = awake_child_on_close.borrow_mut().take() {
            let _ = child.kill();
            let _ = child.wait();
        }
        glib::Propagation::Proceed
    });

    let localsend_status = status.clone();
    let localsend_window = window.clone();
    let localsend_button_for_click = localsend_button.clone();
    let localsend_row_for_click = localsend_row.clone();
    let localsend_progress_for_click = localsend_progress.clone();
    localsend_button.connect_clicked(move |_| {
        if backend::local_send_installed() {
            match backend::launch_local_send() {
                Ok(()) => localsend_status.set_text("LocalSend launched."),
                Err(error) => localsend_status.set_text(&format!("Could not open LocalSend: {error}")),
            }
        } else {
            let status_after = localsend_status.clone();
            let button_after = localsend_button_for_click.clone();
            let row_after = localsend_row_for_click.clone();
            let progress_after = localsend_progress_for_click.clone();
            confirm_dialog(&localsend_window, "Install LocalSend?", "LocalSend will be installed for your user from Flathub. It can transfer files to your iPhone over your local network.", move || {
                button_after.set_sensitive(false);
                button_after.set_label("Installing…");
                row_after.set_subtitle("Downloading and installing LocalSend for this user…");
                progress_after.set_visible(true);
                progress_after.pulse();
                let (sender, receiver) = mpsc::channel();
                std::thread::spawn(move || {
                    let _ = sender.send(backend::install_local_send());
                });

                let button_done = button_after.clone();
                let row_done = row_after.clone();
                let progress_done = progress_after.clone();
                let status_done = status_after.clone();
                glib::timeout_add_local(Duration::from_millis(120), move || {
                    match receiver.try_recv() {
                        Ok(Ok(())) if backend::local_send_installed() => {
                            progress_done.set_visible(false);
                            button_done.set_label("Open");
                            button_done.set_sensitive(true);
                            row_done.set_subtitle("Installed and ready to send files over your local network.");
                            status_done.set_text("LocalSend installed. You can open it now.");
                            glib::ControlFlow::Break
                        }
                        Ok(Ok(())) => {
                            progress_done.set_visible(false);
                            button_done.set_label("Install");
                            button_done.set_sensitive(true);
                            row_done.set_subtitle("Installation finished, but LocalSend was not detected.");
                            status_done.set_text("LocalSend installation could not be verified.");
                            glib::ControlFlow::Break
                        }
                        Ok(Err(error)) => {
                            progress_done.set_visible(false);
                            button_done.set_label("Install");
                            button_done.set_sensitive(true);
                            row_done.set_subtitle("Installation failed. Check your network and try again.");
                            status_done.set_text(&format!("LocalSend installation failed: {error}"));
                            glib::ControlFlow::Break
                        }
                        Err(mpsc::TryRecvError::Disconnected) => {
                            progress_done.set_visible(false);
                            button_done.set_label("Install");
                            button_done.set_sensitive(true);
                            status_done.set_text("LocalSend installer stopped unexpectedly.");
                            glib::ControlFlow::Break
                        }
                        Err(mpsc::TryRecvError::Empty) => {
                            progress_done.pulse();
                            glib::ControlFlow::Continue
                        }
                    }
                });
            });
        }
    });

    let create_status = status.clone();
    let backup_paths_create = backup_paths.clone();
    let backup_dropdown_create = backup_dropdown.clone();
    let restore_button_create = restore_button.clone();
    create_backup_button.connect_clicked(move |_| match backend::create_backup() {
        Ok(path) => {
            create_status.set_text(&format!("Snapshot created: {}", path.display()));
            let list = backend::backup_list().unwrap_or_default();
            let labels = list
                .iter()
                .map(|item| {
                    item.file_name()
                        .and_then(|name| name.to_str())
                        .unwrap_or("Snapshot")
                        .to_owned()
                })
                .collect::<Vec<_>>();
            let refs = labels.iter().map(String::as_str).collect::<Vec<_>>();
            backup_dropdown_create.set_model(Some(&gtk::StringList::new(&refs)));
            backup_dropdown_create.set_sensitive(!list.is_empty());
            restore_button_create.set_sensitive(!list.is_empty());
            *backup_paths_create.borrow_mut() = list;
        }
        Err(error) => create_status.set_text(&format!("Snapshot failed: {error}")),
    });

    let restore_status = status.clone();
    let restore_paths = backup_paths.clone();
    let restore_window = window.clone();
    let restore_profiles = setup_profiles.clone();
    let restore_profile_dropdown = profile_dropdown.clone();
    let restore_profile_stage_button = profile_stage_button.clone();
    let restore_profile_delete_button = profile_delete_button.clone();
    restore_button.connect_clicked(move |_| {
        let selected = backup_dropdown.selected() as usize;
        let path = restore_paths.borrow().get(selected).cloned();
        let Some(path) = path else {
            restore_status.set_text("No snapshot selected.");
            return;
        };
        let restore_status_after = restore_status.clone();
        let restore_profiles_after = restore_profiles.clone();
        let restore_dropdown_after = restore_profile_dropdown.clone();
        let restore_stage_after = restore_profile_stage_button.clone();
        let restore_delete_after = restore_profile_delete_button.clone();
        confirm_dialog(&restore_window, "Restore snapshot?", "Current managed settings will be backed up before the selected snapshot is restored.", move || {
            if let Err(error) = backend::create_backup().and_then(|_| backend::restore_backup(&path)) {
                restore_status_after.set_text(&format!("Restore failed: {error}"));
            } else {
                match backend::load_setup_profiles() {
                    Ok(profiles) => {
                        *restore_profiles_after.borrow_mut() = profiles.clone();
                        refresh_profile_dropdown(
                            &restore_dropdown_after,
                            &restore_stage_after,
                            &restore_delete_after,
                            &profiles,
                        );
                        restore_status_after.set_text("Snapshot restored. Log out and back in if an extension needs reloading.");
                    }
                    Err(error) => restore_status_after.set_text(&format!("Snapshot restored, but saved profiles could not be reloaded: {error}")),
                }
            }
        });
    });

    let apply_status = status.clone();
    let apply_window = window.clone();
    let apply_controls = controls.clone();
    apply_button.connect_clicked(move |_| {
        let changes = collect_changes(&apply_controls.borrow());
        if changes.is_empty() {
            apply_status.set_text("No changes to apply.");
            return;
        }
        let summary = changes
            .iter()
            .map(Change::description)
            .collect::<Vec<_>>()
            .join("\n");
        let status_after = apply_status.clone();
        confirm_dialog(&apply_window, "Apply these changes?", &summary, move || {
            let result = backend::create_backup().and_then(|_| apply_changes(&changes));
            match result {
                Ok(()) => status_after.set_text("Changes applied. A snapshot was saved first."),
                Err(error) => {
                    status_after.set_text(&format!("Some changes could not be applied: {error}"))
                }
            }
        });
    });

    window.present();
}

fn collect_changes(controls: &[ToggleControl]) -> Vec<Change> {
    let mut changes = Vec::new();
    for control in controls {
        let enabled = control.row.is_active();
        match &control.action {
            ToggleAction::ClipboardExtension => {
                if backend::extension_enabled(CLIPBOARD_UUID) != enabled {
                    changes.push(Change::Extension {
                        uuid: CLIPBOARD_UUID.to_owned(),
                        enabled,
                    });
                }
            }
            ToggleAction::SpotlightExtension => {
                if backend::extension_enabled(SEARCH_UUID) != enabled {
                    changes.push(Change::Extension {
                        uuid: SEARCH_UUID.to_owned(),
                        enabled,
                    });
                }
            }
            ToggleAction::FocusShortcut => {
                if backend::focus_shortcut_enabled() != enabled {
                    changes.push(Change::FocusShortcut(enabled));
                }
            }
            ToggleAction::ClipboardPrivacy => {
                if (backend::extension_setting(CLIPBOARD_UUID, "clear-on-boot").as_deref()
                    == Some("true"))
                    != enabled
                {
                    changes.push(Change::ExtensionSetting {
                        uuid: CLIPBOARD_UUID.to_owned(),
                        key: "clear-on-boot".to_owned(),
                        value: enabled.to_string(),
                        label: format!(
                            "Clear clipboard history at login: {}",
                            if enabled { "On" } else { "Off" }
                        ),
                    });
                }
            }
        }
    }

    changes
}

fn apply_changes(changes: &[Change]) -> Result<(), String> {
    for change in changes {
        match change {
            Change::Extension { uuid, enabled } => {
                backend::set_extension_enabled(uuid, *enabled)?;
                if *enabled && uuid == CLIPBOARD_UUID {
                    backend::set_extension_setting(uuid, "history-size", "25")?;
                    backend::set_extension_setting(uuid, "cache-only-favorites", "true")?;
                    backend::set_extension_setting(uuid, "cache-images", "false")?;
                    backend::set_extension_setting(uuid, "toggle-menu", "['<Super>v']")?;
                }
                if *enabled && uuid == SEARCH_UUID {
                    backend::set_extension_setting(uuid, "shortcut-search", "['<Super>space']")?;
                    backend::set_extension_setting(uuid, "popup-at-cursor-monitor", "true")?;
                    backend::set_extension_setting(uuid, "show-panel-icon", "true")?;
                    backend::gsettings_set(
                        "org.gnome.desktop.wm.keybindings",
                        "switch-input-source",
                        "['<Super><Alt>space', 'XF86Keyboard']",
                    )?;
                }
            }
            Change::ExtensionSetting {
                uuid, key, value, ..
            } => {
                if value == "true" {
                    backend::set_extension_enabled(uuid, true)?;
                }
                backend::set_extension_setting(uuid, key, value)?;
                if value == "true" {
                    backend::set_extension_setting(uuid, "cache-only-favorites", "true")?;
                    backend::set_extension_setting(uuid, "cache-images", "false")?;
                }
            }
            Change::FocusShortcut(enabled) => {
                if *enabled {
                    backend::setup_focus_shortcut()?;
                } else {
                    backend::remove_focus_shortcut()?;
                }
            }
        }
    }
    Ok(())
}

fn confirm_dialog(
    window: &adw::ApplicationWindow,
    title: &str,
    body: &str,
    on_confirm: impl Fn() + 'static,
) {
    let dialog = gtk::MessageDialog::builder()
        .transient_for(window)
        .modal(true)
        .message_type(gtk::MessageType::Question)
        .buttons(gtk::ButtonsType::OkCancel)
        .text(title)
        .secondary_text(body)
        .build();
    dialog.connect_response(move |dialog, response| {
        if response == gtk::ResponseType::Ok {
            on_confirm();
        }
        dialog.close();
    });
    dialog.present();
}

pub fn run() -> glib::ExitCode {
    let app = adw::Application::builder()
        .application_id("org.zorin.PersonalSetup")
        .build();
    app.connect_activate(build_window);
    app.run()
}
