use crate::model::*;
use reqwest::{
    header::{HeaderValue, ACCEPT},
    Client, Method, Response,
};
use serde_json::{json, Value};
use std::{
    sync::{
        atomic::{AtomicBool, AtomicU64, Ordering},
        Arc,
    },
    time::Duration,
};
use tokio::sync::{Mutex, RwLock};
use url::Url;
use zeroize::Zeroizing;

const FIELDS: &str = "Overview,Genres,PrimaryImageAspectRatio,DateCreated";

pub struct Auth {
    pub session: Session,
    pub base: Url,
    token: Zeroizing<String>,
    revoked: AtomicBool,
}

pub struct EmbyClient {
    client: Client,
    current: RwLock<Option<Arc<Auth>>>,
    connecting: Mutex<()>,
    epoch: AtomicU64,
    device_id: String,
}

pub fn normalize_server(input: &str) -> AppResult<Url> {
    let input = input.trim();
    if input.is_empty() || input.len() > 2048 {
        return Err(AppError::new(
            "INVALID_SERVER",
            "请输入有效的 Emby 服务器地址。",
        ));
    }
    let supplied = if input.contains("://") {
        input.to_owned()
    } else {
        format!("http://{input}")
    };
    let mut url = Url::parse(&supplied)
        .map_err(|_| AppError::new("INVALID_SERVER", "服务器地址格式不正确。"))?;
    if !matches!(url.scheme(), "http" | "https")
        || url.host_str().is_none()
        || !url.username().is_empty()
        || url.password().is_some()
        || url.query().is_some()
        || url.fragment().is_some()
    {
        return Err(AppError::new(
            "INVALID_SERVER",
            "请使用 HTTP 或 HTTPS 服务器地址，不包含账号、查询参数或页面锚点。",
        ));
    }
    let path = url.path().trim_end_matches('/');
    if path.contains("/web") || path.ends_with(".html") {
        return Err(AppError::new(
            "INVALID_SERVER",
            "请输入服务器根地址（如 http://localhost:8096），不要包含 /web 页面路径。",
        ));
    }
    let path = if path.is_empty() {
        "/emby/".to_owned()
    } else {
        format!("{path}/")
    };
    url.set_path(&path);
    Ok(url)
}

fn valid_id(id: &str) -> AppResult<&str> {
    if id.is_empty()
        || id.len() > 256
        || !id
            .bytes()
            .all(|b| b.is_ascii_alphanumeric() || b == b'-' || b == b'_')
    {
        return Err(AppError::new("INVALID_INPUT", "媒体标识无效。"));
    }
    Ok(id)
}

/// Emby may return API-relative, /emby-relative, proxy-prefixed, or absolute URLs.
/// Never attach the server credential to a different origin.
fn media_url(auth: &Auth, value: &str) -> AppResult<Url> {
    let mut url = if value.starts_with("http://") || value.starts_with("https://") {
        Url::parse(value)
            .map_err(|_| AppError::new("PLAYBACK_UNSUPPORTED", "服务器返回了无效的媒体地址。"))?
    } else {
        if value.starts_with("//") || value.contains("://") {
            return Err(AppError::new(
                "PLAYBACK_UNSUPPORTED",
                "服务器返回了不支持的媒体协议。",
            ));
        }
        let relative = value.trim_start_matches('/');
        let base_path = auth.base.path().trim_matches('/');
        if relative.starts_with(&format!("{base_path}/")) {
            auth.base.join(&format!("/{relative}"))
        } else if base_path.ends_with("emby") && relative.starts_with("emby/") {
            auth.base.join(relative.trim_start_matches("emby/"))
        } else {
            auth.base.join(relative)
        }
        .map_err(|_| AppError::new("PLAYBACK_UNSUPPORTED", "服务器返回了无效的媒体地址。"))?
    };
    if url.origin() != auth.base.origin() || !url.username().is_empty() || url.password().is_some()
    {
        return Err(AppError::new(
            "PLAYBACK_UNSUPPORTED",
            "媒体地址指向其他服务器，无法安全附加播放凭据。",
        ));
    }
    if !url
        .query_pairs()
        .any(|(key, _)| key.eq_ignore_ascii_case("api_key"))
    {
        url.query_pairs_mut().append_pair("api_key", &auth.token);
    }
    Ok(url)
}

impl EmbyClient {
    pub fn new() -> AppResult<Self> {
        let client = Client::builder()
            .connect_timeout(Duration::from_secs(10))
            .timeout(Duration::from_secs(30))
            .pool_max_idle_per_host(8)
            .user_agent(concat!("Luma/", env!("CARGO_PKG_VERSION")))
            // Authenticated redirects must not leak X-Emby-Token to another host.
            .redirect(reqwest::redirect::Policy::none())
            .build()
            .map_err(AppError::network)?;
        Ok(Self {
            client,
            current: RwLock::new(None),
            connecting: Mutex::new(()),
            epoch: AtomicU64::new(0),
            device_id: uuid::Uuid::new_v4().to_string(),
        })
    }

    fn authorization(&self) -> String {
        format!(
            "Emby Client=\"Luma\", Device=\"{}\", DeviceId=\"{}\", Version=\"{}\"",
            std::env::consts::OS,
            self.device_id,
            env!("CARGO_PKG_VERSION")
        )
    }

    pub async fn session(&self) -> Option<Session> {
        self.current
            .read()
            .await
            .as_ref()
            .filter(|a| !a.revoked.load(Ordering::Acquire))
            .map(|a| a.session.clone())
    }

    async fn auth(&self) -> AppResult<Arc<Auth>> {
        self.current
            .read()
            .await
            .as_ref()
            .filter(|a| !a.revoked.load(Ordering::Acquire))
            .cloned()
            .ok_or_else(|| AppError::new("AUTH_REQUIRED", "请先连接 Emby 服务器。"))
    }

    async fn response(&self, response: Response, auth: Option<&Auth>) -> AppResult<Response> {
        let status = response.status();
        if status.is_success() {
            return Ok(response);
        }
        let error = match status.as_u16() {
            401 => {
                if let Some(auth) = auth {
                    auth.revoked.store(true, Ordering::Release);
                }
                AppError::new(
                    if auth.is_some() {
                        "AUTH_REQUIRED"
                    } else {
                        "AUTH_FAILED"
                    },
                    if auth.is_some() {
                        "登录已过期，请重新连接服务器。"
                    } else {
                        "用户名或密码不正确。"
                    },
                )
            }
            403 => AppError::new("FORBIDDEN", "服务器未允许此操作，请检查账号权限。"),
            404 => AppError::new("NOT_FOUND", "未找到媒体或 API，请检查服务器地址和版本。"),
            429 => AppError::new("RATE_LIMITED", "服务器请求过于频繁，请稍后重试。"),
            300..=399 => AppError::new(
                "INVALID_SERVER",
                "服务器要求重定向，请使用最终的服务器地址。",
            ),
            _ => AppError::new(
                "SERVER",
                format!("服务器返回错误（HTTP {}），请稍后重试。", status.as_u16()),
            ),
        };
        Err(error)
    }

    async fn request(
        &self,
        auth: &Auth,
        method: Method,
        path: &str,
        query: &[(String, String)],
        body: Option<Value>,
    ) -> AppResult<Response> {
        let url = auth
            .base
            .join(path)
            .map_err(|_| AppError::new("INVALID_INPUT", "请求地址无效。"))?;
        let mut token = HeaderValue::from_str(&auth.token)
            .map_err(|_| AppError::new("AUTH_FAILED", "服务器返回了无效的访问凭据。"))?;
        token.set_sensitive(true);
        let mut request = self
            .client
            .request(method, url)
            .header(ACCEPT, "application/json")
            .header("X-Emby-Authorization", self.authorization())
            .header("X-Emby-Token", token)
            .query(query);
        if let Some(body) = body {
            request = request.json(&body);
        }
        let response = request.send().await.map_err(AppError::network)?;
        self.response(response, Some(auth)).await
    }

    async fn json(&self, auth: &Auth, path: &str, query: &[(String, String)]) -> AppResult<Value> {
        self.request(auth, Method::GET, path, query, None)
            .await?
            .json()
            .await
            .map_err(|_| AppError::new("INVALID_RESPONSE", "服务器返回了无法解析的数据。"))
    }

    pub async fn connect(
        &self,
        server_url: String,
        username: String,
        password: String,
    ) -> AppResult<Session> {
        let password = Zeroizing::new(password);
        let base = normalize_server(&server_url)?;
        if username.trim().is_empty() {
            return Err(AppError::new("INVALID_INPUT", "请输入用户名。"));
        }
        let epoch = self.epoch.fetch_add(1, Ordering::AcqRel) + 1;
        // Emby may reuse a token for a device. Serialize logins so cancellation
        // cannot revoke the credential of a newer in-flight authentication.
        let _connecting = self.connecting.lock().await;
        if self.epoch.load(Ordering::Acquire) != epoch {
            return Err(AppError::new("SESSION_CHANGED", "连接请求已取消。"));
        }
        let response = self
            .client
            .post(base.join("Users/AuthenticateByName").unwrap())
            .header("X-Emby-Authorization", self.authorization())
            .header(ACCEPT, "application/json")
            .json(&json!({"Username": username.trim(), "Pw": password.as_str()}))
            .send()
            .await
            .map_err(AppError::network)?;
        let value: Value = self
            .response(response, None)
            .await?
            .json()
            .await
            .map_err(|_| AppError::new("INVALID_RESPONSE", "服务器返回了无法解析的登录数据。"))?;
        let token = value["AccessToken"]
            .as_str()
            .filter(|v| !v.is_empty())
            .ok_or_else(|| AppError::new("AUTH_FAILED", "服务器未返回访问凭据。"))?;
        let user_id = value["User"]["Id"]
            .as_str()
            .ok_or_else(|| AppError::new("AUTH_FAILED", "服务器未返回用户信息。"))?;
        valid_id(user_id)?;
        let mut auth = Auth {
            session: Session {
                server_url: base.as_str().trim_end_matches('/').to_owned(),
                user_id: user_id.to_owned(),
                user_name: value["User"]["Name"]
                    .as_str()
                    .unwrap_or(username.trim())
                    .to_owned(),
                server_name: base.host_str().unwrap_or("Emby").to_owned(),
                device_id: self.device_id.clone(),
            },
            base,
            token: Zeroizing::new(token.to_owned()),
            revoked: AtomicBool::new(false),
        };
        if let Ok(info) = self.json(&auth, "System/Info/Public", &[]).await {
            if let Some(name) = info["ServerName"].as_str() {
                auth.session.server_name = name.to_owned();
            }
        }
        let session = auth.session.clone();
        let mut current = self.current.write().await;
        if self.epoch.load(Ordering::Acquire) != epoch {
            drop(current);
            let _ = self
                .request(&auth, Method::POST, "Sessions/Logout", &[], None)
                .await;
            return Err(AppError::new("SESSION_CHANGED", "连接请求已取消。"));
        }
        let reused_token = current.as_ref().is_some_and(|previous| {
            previous.base.origin() == auth.base.origin()
                && previous.token.as_str() == auth.token.as_str()
        });
        let previous = current.replace(Arc::new(auth));
        drop(current);
        if let Some(previous) = previous {
            // Re-authenticating the same device can return the existing token.
            previous.revoked.store(true, Ordering::Release);
            if !reused_token {
                let _ = self
                    .request(&previous, Method::POST, "Sessions/Logout", &[], None)
                    .await;
            }
        }
        Ok(session)
    }

    pub async fn logout(&self) -> AppResult<()> {
        self.epoch.fetch_add(1, Ordering::AcqRel);
        let previous = self.current.write().await.take();
        if let Some(auth) = previous {
            auth.revoked.store(true, Ordering::Release);
            // Local state is cleared even when the server is offline.
            self.request(&auth, Method::POST, "Sessions/Logout", &[], None)
                .await?;
        }
        Ok(())
    }

    fn decorate(&self, auth: &Auth, item: &mut Value) {
        let Some(id) = item["Id"]
            .as_str()
            .filter(|id| valid_id(id).is_ok())
            .map(str::to_owned)
        else {
            return;
        };
        let primary_tag = item["ImageTags"]["Primary"].as_str().map(str::to_owned);
        let series_id = item["SeriesId"]
            .as_str()
            .filter(|id| valid_id(id).is_ok())
            .map(str::to_owned);
        let series_tag = item["SeriesPrimaryImageTag"].as_str().map(str::to_owned);
        let primary = primary_tag
            .map(|tag| (id.clone(), tag))
            .or_else(|| series_id.zip(series_tag));
        if let Some((image_id, tag)) = primary {
            if let Ok(mut url) = media_url(auth, &format!("Items/{image_id}/Images/Primary")) {
                url.query_pairs_mut()
                    .append_pair("maxWidth", "600")
                    .append_pair("quality", "85")
                    .append_pair("tag", &tag);
                item["PrimaryImageUrl"] = json!(url.as_str());
            }
        }
        let backdrop = item["BackdropImageTags"][0]
            .as_str()
            .map(|tag| (id, tag.to_owned()))
            .or_else(|| {
                Some((
                    item["ParentBackdropItemId"].as_str()?.to_owned(),
                    item["ParentBackdropImageTags"][0].as_str()?.to_owned(),
                ))
            });
        if let Some((image_id, tag)) = backdrop.filter(|(id, _)| valid_id(id).is_ok()) {
            if let Ok(mut url) = media_url(auth, &format!("Items/{image_id}/Images/Backdrop/0")) {
                url.query_pairs_mut()
                    .append_pair("maxWidth", "1920")
                    .append_pair("quality", "85")
                    .append_pair("tag", &tag);
                item["BackdropImageUrl"] = json!(url.as_str());
            }
        }
    }

    fn items(&self, auth: &Auth, value: Value) -> Vec<Value> {
        let mut items = value
            .as_array()
            .cloned()
            .or_else(|| value["Items"].as_array().cloned())
            .unwrap_or_default();
        for item in &mut items {
            self.decorate(auth, item);
        }
        items
    }

    async fn library_for(&self, auth: &Auth, query: LibraryQuery) -> AppResult<Value> {
        let sort_by = query.sort_by.as_deref().unwrap_or("SortName");
        if !matches!(
            sort_by,
            "SortName"
                | "DateCreated"
                | "ProductionYear"
                | "CommunityRating"
                | "DatePlayed"
                | "Random"
                | "PremiereDate"
        ) {
            return Err(AppError::new("INVALID_INPUT", "不支持的排序方式。"));
        }
        let mut params = vec![
            ("Recursive".into(), "true".into()),
            ("Fields".into(), FIELDS.into()),
            ("EnableImages".into(), "true".into()),
            ("ImageTypeLimit".into(), "1".into()),
            ("EnableUserData".into(), "true".into()),
            (
                "StartIndex".into(),
                query.start_index.unwrap_or(0).to_string(),
            ),
            (
                "Limit".into(),
                query.limit.unwrap_or(48).clamp(1, 200).to_string(),
            ),
            ("SortBy".into(), sort_by.into()),
            (
                "SortOrder".into(),
                if query.sort_order.as_deref() == Some("Descending") {
                    "Descending"
                } else {
                    "Ascending"
                }
                .into(),
            ),
            (
                "IncludeItemTypes".into(),
                query.types.unwrap_or_else(|| "Movie,Series".into()),
            ),
        ];
        if let Some(parent) = query.parent_id {
            valid_id(&parent)?;
            params.push(("ParentId".into(), parent));
        }
        if let Some(search) = query.search.filter(|s| !s.trim().is_empty()) {
            params.push(("SearchTerm".into(), search.chars().take(256).collect()));
        }
        if query.favorites == Some(true) {
            params.push(("Filters".into(), "IsFavorite".into()));
        }
        let mut data = self
            .json(
                auth,
                &format!("Users/{}/Items", auth.session.user_id),
                &params,
            )
            .await?;
        if let Some(items) = data["Items"].as_array_mut() {
            for item in items {
                self.decorate(auth, item);
            }
        }
        Ok(data)
    }

    pub async fn library(&self, query: LibraryQuery) -> AppResult<Value> {
        let auth = self.auth().await?;
        self.library_for(&auth, query).await
    }

    pub async fn dashboard(&self) -> AppResult<Dashboard> {
        let auth = self.auth().await?;
        let user = &auth.session.user_id;
        let resume_path = format!("Users/{user}/Items/Resume");
        let latest_path = format!("Users/{user}/Items/Latest");
        let views_path = format!("Users/{user}/Views");
        let params = vec![
            ("Limit".into(), "12".into()),
            ("Fields".into(), FIELDS.into()),
            ("MediaTypes".into(), "Video".into()),
            ("EnableUserData".into(), "true".into()),
            ("ImageTypeLimit".into(), "1".into()),
        ];
        let latest_params = vec![
            ("Limit".into(), "20".into()),
            ("Fields".into(), FIELDS.into()),
            ("IncludeItemTypes".into(), "Movie,Episode".into()),
            ("EnableUserData".into(), "true".into()),
        ];
        let (resume, latest, movies, series, views) = tokio::try_join!(
            self.json(&auth, &resume_path, &params),
            self.json(&auth, &latest_path, &latest_params),
            self.library_for(
                &auth,
                LibraryQuery {
                    types: Some("Movie".into()),
                    limit: Some(18),
                    sort_by: Some("DateCreated".into()),
                    sort_order: Some("Descending".into()),
                    ..Default::default()
                }
            ),
            self.library_for(
                &auth,
                LibraryQuery {
                    types: Some("Series".into()),
                    limit: Some(18),
                    sort_by: Some("DateCreated".into()),
                    sort_order: Some("Descending".into()),
                    ..Default::default()
                }
            ),
            self.json(&auth, &views_path, &[])
        )?;
        Ok(Dashboard {
            resume: self.items(&auth, resume),
            latest: self.items(&auth, latest),
            movies: self.items(&auth, movies),
            series: self.items(&auth, series),
            views: self.items(&auth, views),
        })
    }

    pub async fn item(&self, id: &str) -> AppResult<Value> {
        valid_id(id)?;
        let auth = self.auth().await?;
        let mut item = self
            .json(
                &auth,
                &format!("Users/{}/Items/{id}", auth.session.user_id),
                &[],
            )
            .await?;
        self.decorate(&auth, &mut item);
        Ok(item)
    }

    pub async fn episodes(&self, id: &str) -> AppResult<Vec<Value>> {
        valid_id(id)?;
        let auth = self.auth().await?;
        let params = vec![
            ("UserId".into(), auth.session.user_id.clone()),
            ("Fields".into(), FIELDS.into()),
            ("EnableUserData".into(), "true".into()),
        ];
        let data = self
            .json(&auth, &format!("Shows/{id}/Episodes"), &params)
            .await?;
        Ok(self.items(&auth, data))
    }

    pub async fn favorite(&self, id: &str, value: bool) -> AppResult<Value> {
        valid_id(id)?;
        let auth = self.auth().await?;
        self.request(
            &auth,
            if value { Method::POST } else { Method::DELETE },
            &format!("Users/{}/FavoriteItems/{id}", auth.session.user_id),
            &[],
            None,
        )
        .await?
        .json()
        .await
        .map_err(|_| AppError::new("INVALID_RESPONSE", "服务器返回了无法解析的收藏状态。"))
    }

    pub async fn playback(
        &self,
        id: &str,
        max_bitrate: Option<u32>,
        start_ticks: Option<u64>,
    ) -> AppResult<Playback> {
        valid_id(id)?;
        let auth = self.auth().await?;
        let start_ticks = start_ticks.unwrap_or(0);
        let bitrate = max_bitrate
            .unwrap_or(40_000_000)
            .clamp(500_000, 120_000_000);
        let body = json!({
            "UserId": auth.session.user_id, "MaxStreamingBitrate": bitrate, "StartTimeTicks": 0,
            "IsPlayback": true, "AutoOpenLiveStream": false, "EnableDirectPlay": true,
            "EnableDirectStream": true, "EnableTranscoding": true, "MaxAudioChannels": 2,
            "DeviceProfile": {
                "Name": "Luma WebView", "MaxStreamingBitrate": bitrate,
                "DirectPlayProfiles": [{ "Container": "mp4,m4v", "Type": "Video", "VideoCodec": "h264", "AudioCodec": "aac,mp3" }],
                "TranscodingProfiles": [{ "Container": "ts", "Type": "Video", "VideoCodec": "h264", "AudioCodec": "aac", "Protocol": "hls", "Context": "Streaming", "MaxAudioChannels": "2", "MinSegments": 1, "SegmentLength": 4, "BreakOnNonKeyFrames": true }],
                "SubtitleProfiles": [{"Format": "vtt", "Method": "External"}],
                "CodecProfiles": [{"Type": "Video", "Codec": "h264", "Conditions": [{"Condition": "LessThanEqual", "Property": "VideoBitDepth", "Value": "8", "IsRequired": false}]}]
            }
        });
        let data: Value = self
            .request(
                &auth,
                Method::POST,
                &format!("Items/{id}/PlaybackInfo"),
                &[],
                Some(body),
            )
            .await?
            .json()
            .await
            .map_err(|_| AppError::new("INVALID_RESPONSE", "服务器返回了无法解析的播放信息。"))?;
        if data["ErrorCode"].as_str().is_some_and(|v| !v.is_empty()) {
            return Err(AppError::new(
                "PLAYBACK_UNSUPPORTED",
                "此媒体无法播放，请检查账号的播放 / 转码权限。",
            ));
        }
        let sources = data["MediaSources"]
            .as_array()
            .ok_or_else(|| AppError::new("PLAYBACK_UNSUPPORTED", "没有可用的媒体源。"))?;
        let source = sources
            .iter()
            .find(|s| s["SupportsDirectPlay"] == true && browser_direct(s))
            .or_else(|| {
                sources
                    .iter()
                    .find(|s| s["TranscodingUrl"].as_str().is_some_and(|u| !u.is_empty()))
            })
            .or_else(|| {
                sources
                    .iter()
                    .find(|s| s["SupportsDirectStream"] == true && browser_direct(s))
            })
            .ok_or_else(|| {
                AppError::new(
                    "PLAYBACK_UNSUPPORTED",
                    "没有兼容的播放格式。请启用服务器 H.264 / AAC 转码后重试。",
                )
            })?;
        let source_id = source["Id"]
            .as_str()
            .ok_or_else(|| AppError::new("INVALID_RESPONSE", "媒体源标识缺失。"))?;
        valid_id(source_id)?;
        let session_id = data["PlaySessionId"]
            .as_str()
            .unwrap_or_default()
            .to_owned();
        let (mut url, method, mime) = if source["SupportsDirectPlay"] == true
            && browser_direct(source)
        {
            (
                media_url(&auth, &format!("Videos/{id}/stream.mp4"))?,
                "DirectPlay",
                "video/mp4",
            )
        } else if let Some(transcoding) =
            source["TranscodingUrl"].as_str().filter(|v| !v.is_empty())
        {
            (
                media_url(&auth, transcoding)?,
                "Transcode",
                "application/vnd.apple.mpegurl",
            )
        } else if let Some(direct) = source["DirectStreamUrl"].as_str().filter(|v| !v.is_empty()) {
            (media_url(&auth, direct)?, "DirectStream", "video/mp4")
        } else {
            (
                media_url(&auth, &format!("Videos/{id}/stream.mp4"))?,
                "DirectStream",
                "video/mp4",
            )
        };
        if method != "Transcode" {
            url.query_pairs_mut()
                .append_pair("Static", "true")
                .append_pair("MediaSourceId", source_id)
                .append_pair("DeviceId", &auth.session.device_id)
                .append_pair("PlaySessionId", &session_id);
        }
        let mut subtitles = Vec::new();
        let mut audio_tracks = Vec::new();
        if let Some(streams) = source["MediaStreams"].as_array() {
            for stream in streams {
                let index = stream["Index"].as_i64().unwrap_or(0);
                let title = stream["DisplayTitle"]
                    .as_str()
                    .or_else(|| stream["Title"].as_str())
                    .or_else(|| stream["Language"].as_str())
                    .unwrap_or("Track")
                    .to_owned();
                let language = stream["Language"].as_str().map(str::to_owned);
                if stream["Type"] == "Audio" {
                    audio_tracks.push(AudioTrack {
                        index,
                        title: title.clone(),
                        language: language.clone(),
                    });
                }
                if stream["Type"] == "Subtitle" && stream["IsTextSubtitleStream"] == true {
                    let path = format!("Videos/{id}/{source_id}/Subtitles/{index}/Stream.vtt");
                    if let Ok(url) = media_url(&auth, &path) {
                        subtitles.push(Subtitle {
                            index,
                            title,
                            language,
                            url: url.to_string(),
                            is_default: stream["IsDefault"] == true,
                        });
                    }
                }
            }
        }
        Ok(Playback {
            url: url.to_string(),
            item_id: id.into(),
            media_source_id: source_id.into(),
            play_session_id: session_id,
            play_method: method.into(),
            mime_type: mime.into(),
            start_ticks,
            subtitles,
            audio_tracks,
        })
    }

    pub async fn cancel_playback(&self, play_session_id: &str) -> AppResult<()> {
        valid_id(play_session_id)?;
        let auth = self.auth().await?;
        let query = vec![
            ("DeviceId".into(), auth.session.device_id.clone()),
            ("PlaySessionId".into(), play_session_id.into()),
        ];
        self.request(
            &auth,
            Method::DELETE,
            "Videos/ActiveEncodings",
            &query,
            None,
        )
        .await?;
        Ok(())
    }

    pub async fn report_playback(&self, event: PlaybackEvent) -> AppResult<()> {
        valid_id(&event.item_id)?;
        valid_id(&event.media_source_id)?;
        if !matches!(
            event.play_method.as_str(),
            "DirectPlay" | "DirectStream" | "Transcode"
        ) {
            return Err(AppError::new("INVALID_INPUT", "播放方式无效。"));
        }
        let path = match event.kind.as_str() {
            "start" => "Sessions/Playing",
            "progress" => "Sessions/Playing/Progress",
            "stop" => "Sessions/Playing/Stopped",
            _ => return Err(AppError::new("INVALID_INPUT", "播放事件无效。")),
        };
        let auth = self.auth().await?;
        let body = json!({"ItemId": event.item_id, "MediaSourceId": event.media_source_id, "PlaySessionId": event.play_session_id,
            "PositionTicks": event.position_ticks, "PlayMethod": event.play_method, "IsPaused": event.is_paused.unwrap_or(false),
            "IsMuted": event.is_muted.unwrap_or(false), "VolumeLevel": event.volume_level.unwrap_or(100).min(100),
            "CanSeek": true, "QueueableMediaTypes": ["Video"], "EventName": "TimeUpdate"});
        self.request(&auth, Method::POST, path, &[], Some(body))
            .await?;
        Ok(())
    }
}

fn browser_direct(source: &Value) -> bool {
    let container = source["Container"]
        .as_str()
        .unwrap_or("")
        .to_ascii_lowercase();
    if !matches!(container.as_str(), "mp4" | "m4v") {
        return false;
    }
    let Some(streams) = source["MediaStreams"].as_array() else {
        return false;
    };
    let video_ok = streams
        .iter()
        .filter(|s| s["Type"] == "Video")
        .any(|s| s["Codec"] == "h264" && s["BitDepth"].as_u64().unwrap_or(8) <= 8);
    let audio_ok = streams
        .iter()
        .filter(|s| s["Type"] == "Audio")
        .all(|s| matches!(s["Codec"].as_str(), Some("aac" | "mp3")));
    video_ok && audio_ok
}

#[cfg(test)]
mod tests;
