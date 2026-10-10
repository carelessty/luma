mod api;
mod model;

use api::EmbyClient;
use model::*;
use serde_json::Value;
use tauri::State;

#[tauri::command]
async fn connect(
    state: State<'_, EmbyClient>,
    server_url: String,
    username: String,
    password: String,
) -> AppResult<Session> {
    state.connect(server_url, username, password).await
}

#[tauri::command]
async fn session(state: State<'_, EmbyClient>) -> AppResult<Option<Session>> {
    Ok(state.session().await)
}

#[tauri::command]
async fn logout(state: State<'_, EmbyClient>) -> AppResult<()> {
    state.logout().await
}

#[tauri::command]
async fn dashboard(state: State<'_, EmbyClient>) -> AppResult<Dashboard> {
    state.dashboard().await
}

#[tauri::command]
async fn library(state: State<'_, EmbyClient>, query: LibraryQuery) -> AppResult<Value> {
    state.library(query).await
}

#[tauri::command]
async fn item(state: State<'_, EmbyClient>, id: String) -> AppResult<Value> {
    state.item(&id).await
}

#[tauri::command]
async fn episodes(state: State<'_, EmbyClient>, id: String) -> AppResult<Vec<Value>> {
    state.episodes(&id).await
}

#[tauri::command]
async fn favorite(state: State<'_, EmbyClient>, id: String, value: bool) -> AppResult<Value> {
    state.favorite(&id, value).await
}

#[tauri::command]
async fn playback(
    state: State<'_, EmbyClient>,
    id: String,
    max_bitrate: Option<u32>,
    start_ticks: Option<u64>,
) -> AppResult<Playback> {
    state.playback(&id, max_bitrate, start_ticks).await
}

#[tauri::command]
async fn report_playback(state: State<'_, EmbyClient>, event: PlaybackEvent) -> AppResult<()> {
    state.report_playback(event).await
}

#[tauri::command]
async fn cancel_playback(state: State<'_, EmbyClient>, play_session_id: String) -> AppResult<()> {
    state.cancel_playback(&play_session_id).await
}

#[cfg_attr(mobile, tauri::mobile_entry_point)]
pub fn run() {
    let client = EmbyClient::new()
        .unwrap_or_else(|error| panic!("Unable to initialize HTTP client: {}", error.message));
    tauri::Builder::default()
        .manage(client)
        .invoke_handler(tauri::generate_handler![
            connect,
            session,
            logout,
            dashboard,
            library,
            item,
            episodes,
            favorite,
            playback,
            report_playback,
            cancel_playback
        ])
        .run(tauri::generate_context!())
        .expect("Unable to run Luma");
}
