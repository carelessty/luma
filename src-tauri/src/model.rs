use serde::{Deserialize, Serialize};
use serde_json::Value;

#[derive(Debug, Clone, Serialize)]
pub struct AppError {
    pub code: &'static str,
    pub message: String,
}

impl AppError {
    pub fn new(code: &'static str, message: impl Into<String>) -> Self {
        Self {
            code,
            message: message.into(),
        }
    }

    pub fn network(error: reqwest::Error) -> Self {
        // Never expose reqwest's display string: it can include authenticated URLs.
        if error.is_timeout() {
            Self::new("TIMEOUT", "服务器响应超时，请检查网络后重试。")
        } else if error.is_connect() {
            Self::new("NETWORK", "无法连接服务器，请检查地址、网络和 TLS 证书。")
        } else {
            Self::new("NETWORK", "网络请求失败，请稍后重试。")
        }
    }
}

pub type AppResult<T> = Result<T, AppError>;

#[derive(Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Session {
    pub server_url: String,
    pub user_id: String,
    pub user_name: String,
    pub server_name: String,
    pub device_id: String,
}

#[derive(Default, Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct LibraryQuery {
    pub parent_id: Option<String>,
    pub search: Option<String>,
    pub types: Option<String>,
    pub favorites: Option<bool>,
    pub start_index: Option<u32>,
    pub limit: Option<u32>,
    pub sort_by: Option<String>,
    pub sort_order: Option<String>,
}

#[derive(Serialize)]
pub struct Dashboard {
    pub resume: Vec<Value>,
    pub latest: Vec<Value>,
    pub movies: Vec<Value>,
    pub series: Vec<Value>,
    pub views: Vec<Value>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Playback {
    pub url: String,
    pub item_id: String,
    pub media_source_id: String,
    pub play_session_id: String,
    pub play_method: String,
    pub mime_type: String,
    pub start_ticks: u64,
    pub subtitles: Vec<Subtitle>,
    pub audio_tracks: Vec<AudioTrack>,
}

#[derive(Serialize)]
#[serde(rename_all = "camelCase")]
pub struct Subtitle {
    pub index: i64,
    pub title: String,
    pub url: String,
    pub language: Option<String>,
    pub is_default: bool,
}

#[derive(Serialize)]
pub struct AudioTrack {
    pub index: i64,
    pub title: String,
    pub language: Option<String>,
}

#[derive(Deserialize)]
#[serde(rename_all = "camelCase")]
pub struct PlaybackEvent {
    #[serde(rename = "type")]
    pub kind: String,
    pub item_id: String,
    pub media_source_id: String,
    pub play_session_id: String,
    pub play_method: String,
    pub position_ticks: u64,
    pub is_paused: Option<bool>,
    pub is_muted: Option<bool>,
    pub volume_level: Option<u8>,
}
