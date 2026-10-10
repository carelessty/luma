use super::*;
use wiremock::{
    matchers::{body_json, header, method, path, query_param},
    Mock, MockServer, ResponseTemplate,
};

fn auth(base: &str) -> Auth {
    Auth {
        session: Session {
            server_url: base.into(),
            user_id: "user1".into(),
            user_name: "Viewer".into(),
            server_name: "Home".into(),
            device_id: "device1".into(),
        },
        base: normalize_server(base).unwrap(),
        token: Zeroizing::new("secret-token".into()),
        revoked: AtomicBool::new(false),
    }
}

#[test]
fn server_urls_preserve_reverse_proxy_prefix() {
    assert_eq!(
        normalize_server(" https://example.com/proxy/emby/ ")
            .unwrap()
            .as_str(),
        "https://example.com/proxy/emby/"
    );
    assert_eq!(
        normalize_server("http://localhost:8096").unwrap().as_str(),
        "http://localhost:8096/emby/"
    );
    assert_eq!(
        normalize_server("192.168.1.2:8096").unwrap().as_str(),
        "http://192.168.1.2:8096/emby/"
    );
    assert_eq!(
        normalize_server("https://example.com/media")
            .unwrap()
            .as_str(),
        "https://example.com/media/"
    );
}

#[test]
fn rejects_ambiguous_or_unsafe_server_urls() {
    for url in [
        "file:///etc/passwd",
        "ftp://localhost",
        "https://user:pass@example.com",
        "https://example.com?api_key=secret",
        "https://example.com#anchor",
        "https://example.com/web/index.html",
        "",
    ] {
        assert!(normalize_server(url).is_err(), "accepted {url}");
    }
}

#[test]
fn media_urls_handle_all_emby_forms_and_keep_proxy_prefix() {
    let auth = auth("https://example.com/proxy/emby");
    for path in [
        "Videos/12/master.m3u8",
        "/emby/Videos/12/master.m3u8",
        "/proxy/emby/Videos/12/master.m3u8",
        "https://example.com/proxy/emby/Videos/12/master.m3u8",
    ] {
        let url = media_url(&auth, path).unwrap();
        assert_eq!(url.path(), "/proxy/emby/Videos/12/master.m3u8");
        assert_eq!(
            url.query_pairs().find(|(k, _)| k == "api_key").unwrap().1,
            "secret-token"
        );
    }
    assert!(media_url(&auth, "https://evil.example/stream").is_err());
    assert!(media_url(&auth, "//evil.example/stream").is_err());
    assert!(media_url(&auth, "file:///tmp/movie.mp4").is_err());
}

#[test]
fn direct_play_only_advertises_browser_decodable_media() {
    let source = json!({"Container":"mp4","MediaStreams":[{"Type":"Video","Codec":"h264","BitDepth":8},{"Type":"Audio","Codec":"aac"}]});
    assert!(browser_direct(&source));
    let mut unsupported = source.clone();
    unsupported["MediaStreams"][0]["Codec"] = json!("hevc");
    assert!(!browser_direct(&unsupported));
    unsupported = source.clone();
    unsupported["MediaStreams"][1]["Codec"] = json!("dts");
    assert!(!browser_direct(&unsupported));
    unsupported = source;
    unsupported["Container"] = json!("mkv");
    assert!(!browser_direct(&unsupported));
}

async fn logged_in() -> (MockServer, EmbyClient) {
    let server = MockServer::start().await;
    Mock::given(method("POST"))
        .and(path("/emby/Users/AuthenticateByName"))
        .and(body_json(json!({"Username":"viewer","Pw":"password"})))
        .respond_with(ResponseTemplate::new(200).set_body_json(
            json!({"AccessToken":"secret-token","User":{"Id":"user1","Name":"Viewer"}}),
        ))
        .mount(&server)
        .await;
    Mock::given(method("GET"))
        .and(path("/emby/System/Info/Public"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({"ServerName":"Home cinema"})))
        .mount(&server)
        .await;
    let client = EmbyClient::new().unwrap();
    client
        .connect(server.uri(), "viewer".into(), "password".into())
        .await
        .unwrap();
    (server, client)
}

#[tokio::test]
async fn authentication_returns_public_session_and_library_is_authenticated() {
    let (server, client) = logged_in().await;
    let session = serde_json::to_string(&client.session().await.unwrap()).unwrap();
    assert!(session.contains("Home cinema"));
    assert!(!session.contains("secret-token"));
    assert!(!session.contains("password"));
    Mock::given(method("GET")).and(path("/emby/Users/user1/Items")).and(header("X-Emby-Token", "secret-token"))
        .and(query_param("SearchTerm", "Arrival & aliens"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({"Items":[{"Id":"12","Name":"Arrival","ImageTags":{"Primary":"tag1"}}],"TotalRecordCount":1}))).expect(1).mount(&server).await;
    let result = client
        .library(LibraryQuery {
            search: Some("Arrival & aliens".into()),
            ..Default::default()
        })
        .await
        .unwrap();
    assert_eq!(result["TotalRecordCount"], 1);
    assert!(result["Items"][0]["PrimaryImageUrl"]
        .as_str()
        .unwrap()
        .contains("/emby/Items/12/Images/Primary"));
}

#[tokio::test]
async fn unauthorized_response_expires_only_the_current_auth() {
    let (server, client) = logged_in().await;
    Mock::given(path("/emby/Users/user1/Items/12"))
        .respond_with(ResponseTemplate::new(401).set_body_string("secret-token"))
        .mount(&server)
        .await;
    let error = client.item("12").await.unwrap_err();
    assert_eq!(error.code, "AUTH_REQUIRED");
    assert!(!error.message.contains("secret-token"));
    assert!(client.session().await.is_none());
}

#[tokio::test]
async fn logout_always_clears_local_session_even_if_server_fails() {
    let (server, client) = logged_in().await;
    Mock::given(method("POST"))
        .and(path("/emby/Sessions/Logout"))
        .respond_with(ResponseTemplate::new(500))
        .mount(&server)
        .await;
    assert!(client.logout().await.is_err());
    assert!(client.session().await.is_none());
}

#[tokio::test]
async fn playback_negotiates_hls_and_reports_position_in_ticks() {
    let (server, client) = logged_in().await;
    Mock::given(method("POST")).and(path("/emby/Items/12/PlaybackInfo")).and(header("X-Emby-Token", "secret-token"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({"PlaySessionId":"play1","MediaSources":[{"Id":"source1","Container":"mkv","SupportsDirectPlay":false,"TranscodingUrl":"/emby/Videos/12/master.m3u8?VideoCodec=h264","MediaStreams":[]}]}))).mount(&server).await;
    let playback = client.playback("12", None, Some(50_000_000)).await.unwrap();
    assert_eq!(playback.play_method, "Transcode");
    assert_eq!(playback.start_ticks, 50_000_000);
    assert!(playback.url.contains("/emby/Videos/12/master.m3u8"));
    Mock::given(method("POST")).and(path("/emby/Sessions/Playing/Progress"))
        .and(body_json(json!({"ItemId":"12","MediaSourceId":"source1","PlaySessionId":"play1","PositionTicks":70_000_000u64,"PlayMethod":"Transcode","IsPaused":false,"IsMuted":false,"VolumeLevel":80,"CanSeek":true,"QueueableMediaTypes":["Video"],"EventName":"TimeUpdate"})))
        .respond_with(ResponseTemplate::new(204)).expect(1).mount(&server).await;
    client
        .report_playback(PlaybackEvent {
            kind: "progress".into(),
            item_id: "12".into(),
            media_source_id: "source1".into(),
            play_session_id: "play1".into(),
            play_method: "Transcode".into(),
            position_ticks: 70_000_000,
            is_paused: Some(false),
            is_muted: Some(false),
            volume_level: Some(80),
        })
        .await
        .unwrap();
}

#[tokio::test]
async fn logout_cancels_in_flight_login() {
    let server = MockServer::start().await;
    Mock::given(path("/emby/Users/AuthenticateByName"))
        .respond_with(
            ResponseTemplate::new(200)
                .set_delay(Duration::from_millis(150))
                .set_body_json(
                    json!({"AccessToken":"late-token","User":{"Id":"user1","Name":"Viewer"}}),
                ),
        )
        .mount(&server)
        .await;
    Mock::given(path("/emby/System/Info/Public"))
        .respond_with(ResponseTemplate::new(200).set_body_json(json!({"ServerName":"Cinema"})))
        .mount(&server)
        .await;
    Mock::given(path("/emby/Sessions/Logout"))
        .respond_with(ResponseTemplate::new(204))
        .mount(&server)
        .await;
    let client = Arc::new(EmbyClient::new().unwrap());
    let connecting = client.clone();
    let uri = server.uri();
    let task = tokio::spawn(async move {
        connecting
            .connect(uri, "viewer".into(), "password".into())
            .await
    });
    tokio::time::sleep(Duration::from_millis(40)).await;
    client.logout().await.unwrap();
    let result = task.await.unwrap();
    assert!(matches!(
        result,
        Err(AppError {
            code: "SESSION_CHANGED",
            ..
        })
    ));
    assert!(client.session().await.is_none());
}

#[tokio::test]
async fn cancel_playback_targets_only_the_active_session() {
    let (server, client) = logged_in().await;
    let device_id = client.session().await.unwrap().device_id;
    Mock::given(method("DELETE"))
        .and(path("/emby/Videos/ActiveEncodings"))
        .and(query_param("DeviceId", device_id))
        .and(query_param("PlaySessionId", "play1"))
        .respond_with(ResponseTemplate::new(204))
        .expect(1)
        .mount(&server)
        .await;
    client.cancel_playback("play1").await.unwrap();
    assert!(client.cancel_playback("").await.is_err());
}
