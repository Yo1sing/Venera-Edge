use crate::api::cookies::CookieStore;
use anyhow::{anyhow, Context, Result};
use std::{
    collections::HashMap,
    net::{IpAddr, SocketAddr},
    sync::{Mutex, OnceLock},
    time::Duration,
};
use tokio::sync::{watch, Mutex as AsyncMutex};

type UploadChunk = std::result::Result<Vec<u8>, String>;

pub(crate) fn transport_error(error: reqwest::Error) -> anyhow::Error {
    if error.is_timeout() {
        let message = if error.is_connect() {
            "HTTP connection timed out"
        } else {
            "HTTP response timed out"
        };
        return anyhow::Error::new(error).context(message);
    }
    error.into()
}

#[flutter_rust_bridge::frb(opaque)]
pub struct HttpUpload {
    sender: Mutex<Option<tokio::sync::mpsc::Sender<UploadChunk>>>,
    receiver: Mutex<Option<tokio::sync::mpsc::Receiver<UploadChunk>>>,
    aborted: HttpCancellation,
}

impl HttpUpload {
    #[flutter_rust_bridge::frb(sync)]
    pub fn new() -> Self {
        let (sender, receiver) = tokio::sync::mpsc::channel(8);
        Self {
            sender: Mutex::new(Some(sender)),
            receiver: Mutex::new(Some(receiver)),
            aborted: HttpCancellation::new(),
        }
    }

    pub async fn write(&self, bytes: Vec<u8>) -> Result<()> {
        let sender = self
            .sender
            .lock()
            .map_err(|_| anyhow!("upload lock poisoned"))?
            .clone()
            .context("upload closed")?;
        tokio::select! {
            biased;
            _ = self.aborted.cancelled() => Err(anyhow!("upload request closed")),
            result = sender.send(Ok(bytes)) => result.map_err(|_| anyhow!("upload request closed")),
        }
    }

    pub async fn fail(&self, message: String) -> Result<()> {
        let sender = self
            .sender
            .lock()
            .map_err(|_| anyhow!("upload lock poisoned"))?
            .take();
        if let Some(sender) = sender {
            tokio::select! {
                biased;
                _ = self.aborted.cancelled() => {},
                _ = sender.send(Err(message)) => {},
            }
        }
        Ok(())
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn finish(&self) -> Result<()> {
        self.sender
            .lock()
            .map_err(|_| anyhow!("upload lock poisoned"))?
            .take();
        Ok(())
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn abort(&self) -> Result<()> {
        self.aborted.cancel();
        self.finish()?;
        self.receiver
            .lock()
            .map_err(|_| anyhow!("upload lock poisoned"))?
            .take();
        Ok(())
    }

    #[flutter_rust_bridge::frb(ignore)]
    fn body(&self) -> Result<reqwest::Body> {
        let receiver = self
            .receiver
            .lock()
            .map_err(|_| anyhow!("upload lock poisoned"))?
            .take()
            .context("upload already consumed")?;
        let stream = futures_util::stream::unfold(receiver, |mut receiver| async {
            receiver
                .recv()
                .await
                .map(|chunk| (chunk.map_err(std::io::Error::other), receiver))
        });
        Ok(reqwest::Body::wrap_stream(stream))
    }
}

impl Default for HttpUpload {
    fn default() -> Self {
        Self::new()
    }
}

#[derive(Clone)]
pub struct HttpHeader {
    pub name: String,
    pub value: String,
}

#[derive(Clone, serde::Serialize, serde::Deserialize)]
pub struct HttpOptions {
    pub proxy: Option<String>,
    pub dns_overrides: HashMap<String, String>,
    pub tls_sni: bool,
    pub verify_certificates: bool,
    pub connect_timeout_ms: u32,
    pub receive_timeout_ms: u32,
    pub max_redirects: u32,
}

#[derive(Clone)]
pub struct SourceHttpOptions {
    pub cookie_path: String,
    pub user_agent: String,
    pub legacy_clearance_user_agent: Option<String>,
}

#[flutter_rust_bridge::frb(sync)]
pub fn configure_source_http(cookie_path: String, options: HttpOptions) {
    crate::http_policy::configure_source(&cookie_path, options);
}

#[flutter_rust_bridge::frb(sync)]
pub fn is_cloudflare_challenge_page(head: String, body: String) -> bool {
    crate::http_policy::is_challenge_page(&head, &body)
}

#[flutter_rust_bridge::frb(opaque)]
pub struct HttpCancellation {
    sender: watch::Sender<bool>,
}

impl HttpCancellation {
    #[flutter_rust_bridge::frb(ignore)]
    pub(crate) fn is_cancelled(&self) -> bool {
        *self.sender.borrow()
    }
    #[flutter_rust_bridge::frb(sync)]
    pub fn new() -> Self {
        Self {
            sender: watch::channel(false).0,
        }
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn cancel(&self) {
        self.sender.send_replace(true);
    }

    #[flutter_rust_bridge::frb(ignore)]
    pub(crate) async fn cancelled(&self) {
        let mut receiver = self.sender.subscribe();
        if !*receiver.borrow_and_update() {
            let _ = receiver.changed().await;
        }
    }
}

impl Default for HttpCancellation {
    fn default() -> Self {
        Self::new()
    }
}

#[flutter_rust_bridge::frb(opaque)]
pub struct HttpResponse {
    response: AsyncMutex<ResponseState>,
    headers: Vec<HttpHeader>,
    status: u16,
    url: String,
}

struct ResponseState {
    native: Option<reqwest::Response>,
    cached: Option<Vec<u8>>,
    collecting: Option<Vec<u8>>,
    key: Option<String>,
    serial: Option<tokio::sync::OwnedMutexGuard<()>>,
}

impl HttpResponse {
    #[flutter_rust_bridge::frb(sync)]
    pub fn status(&self) -> u16 {
        self.status
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn headers(&self) -> Vec<HttpHeader> {
        self.headers.clone()
    }

    #[flutter_rust_bridge::frb(sync)]
    pub fn url(&self) -> String {
        self.url.clone()
    }

    // Pull-based streaming provides backpressure: Dart requests the next chunk
    // only after its consumer has processed the previous chunk.
    pub async fn next_chunk(&self, cancellation: &HttpCancellation) -> Result<Option<Vec<u8>>> {
        let mut guard = tokio::select! {
            biased;
            _ = cancellation.cancelled() => return Err(anyhow!("Request cancelled")),
            guard = self.response.lock() => guard,
        };
        if let Some(bytes) = guard.cached.take() {
            return Ok(Some(bytes));
        }
        let Some(response) = guard.native.as_mut() else {
            guard.serial.take();
            return Ok(None);
        };
        let result = tokio::select! {
            biased;
            _ = cancellation.cancelled() => Err(anyhow!("Request cancelled")),
            chunk = response.chunk() => chunk.map(|value| value.map(|bytes| bytes.to_vec())).map_err(transport_error),
        };
        match &result {
            Ok(Some(bytes)) => {
                if let Some(buffer) = guard.collecting.as_mut() {
                    if buffer.len() + bytes.len() <= 1024 * 1024 {
                        buffer.extend_from_slice(bytes);
                    } else {
                        guard.collecting = None;
                    }
                }
            }
            Ok(None) => {
                if let (Some(key), Some(bytes)) = (guard.key.take(), guard.collecting.take()) {
                    crate::http_policy::put(
                        key,
                        self.headers.clone(),
                        self.status,
                        self.url.clone(),
                        bytes,
                    );
                }
                guard.native.take();
                guard.serial.take();
            }
            Err(_) => {
                guard.native.take();
                guard.collecting.take();
                guard.serial.take();
            }
        }
        result
    }

    pub async fn close(&self) {
        let mut state = self.response.lock().await;
        state.native.take();
        state.cached.take();
        state.collecting.take();
        state.serial.take();
    }
}

static CLIENTS: OnceLock<Mutex<HashMap<String, reqwest::Client>>> = OnceLock::new();

fn partition(options: &HttpOptions) -> String {
    let mut dns: Vec<_> = options.dns_overrides.iter().collect();
    dns.sort();
    format!(
        "{:?}|{:?}|{}|{}|{}|{}|{}",
        options.proxy,
        dns,
        options.tls_sni,
        options.verify_certificates,
        options.connect_timeout_ms,
        options.receive_timeout_ms,
        options.max_redirects
    )
}

pub(crate) fn client(options: &HttpOptions) -> Result<reqwest::Client> {
    let key = partition(options);
    let mut clients = CLIENTS
        .get_or_init(Default::default)
        .lock()
        .map_err(|_| anyhow!("HTTP pool lock poisoned"))?;
    if let Some(client) = clients.get(&key) {
        return Ok(client.clone());
    }
    let mut builder = reqwest::Client::builder()
        .no_proxy()
        .tls_sni(options.tls_sni)
        .danger_accept_invalid_certs(!options.verify_certificates)
        .redirect(if options.max_redirects == 0 {
            reqwest::redirect::Policy::none()
        } else {
            reqwest::redirect::Policy::limited(options.max_redirects as usize)
        })
        .connect_timeout(Duration::from_millis(u64::from(options.connect_timeout_ms)))
        .read_timeout(Duration::from_millis(u64::from(options.receive_timeout_ms)))
        .pool_idle_timeout(Duration::from_secs(60));
    if let Some(proxy) = &options.proxy {
        let proxy = if proxy.contains("://") {
            proxy.clone()
        } else {
            format!("http://{proxy}")
        };
        builder = builder.proxy(reqwest::Proxy::all(proxy)?);
    }
    for (host, address) in &options.dns_overrides {
        let ip: IpAddr = address
            .parse()
            .with_context(|| format!("Invalid DNS override for {host}"))?;
        builder = builder.resolve(host, SocketAddr::new(ip, 0));
    }
    let client = builder.build()?;
    // Bound the number of pools when settings change repeatedly.
    if clients.len() >= 8 {
        clients.clear();
    }
    clients.insert(key, client.clone());
    Ok(client)
}

#[allow(clippy::too_many_arguments)]
pub async fn http_request(
    url: String,
    method: String,
    headers: Vec<HttpHeader>,
    body: Option<Vec<u8>>,
    upload: &HttpUpload,
    has_upload: bool,
    options: HttpOptions,
    cancellation: &HttpCancellation,
) -> Result<HttpResponse> {
    request(
        url,
        method,
        headers,
        body,
        upload,
        has_upload,
        options,
        None,
        cancellation,
    )
    .await
}

#[allow(clippy::too_many_arguments)]
pub async fn source_http_request(
    url: String,
    method: String,
    headers: Vec<HttpHeader>,
    body: Option<Vec<u8>>,
    upload: &HttpUpload,
    has_upload: bool,
    options: HttpOptions,
    source: SourceHttpOptions,
    cancellation: &HttpCancellation,
) -> Result<HttpResponse> {
    request(
        url,
        method,
        headers,
        body,
        upload,
        has_upload,
        options,
        Some(source),
        cancellation,
    )
    .await
}

#[allow(clippy::too_many_arguments)]
async fn request(
    url: String,
    method: String,
    headers: Vec<HttpHeader>,
    body: Option<Vec<u8>>,
    upload: &HttpUpload,
    has_upload: bool,
    mut options: HttpOptions,
    source: Option<SourceHttpOptions>,
    cancellation: &HttpCancellation,
) -> Result<HttpResponse> {
    use crate::http_policy as policy;
    anyhow::ensure!(!cancellation.is_cancelled(), "Request cancelled");
    let url = reqwest::Url::parse(&url)?;
    let serial = if policy::header(&headers, "prevent-parallel") == Some("true") {
        Some(tokio::select! {
            biased;
            _ = cancellation.cancelled() => return Err(anyhow!("Request cancelled")),
            guard = policy::serial(url.as_str()) => guard,
        })
    } else {
        None
    };
    let store = source
        .as_ref()
        .map(|s| CookieStore::open(s.cookie_path.clone()))
        .transpose()?;
    let generation = store.as_ref().map(CookieStore::generation).transpose()?;
    let session =
        source
            .as_ref()
            .zip(store.as_ref())
            .zip(generation)
            .map(|((config, store), generation)| policy::Session {
                config,
                store,
                generation,
            });
    let cache_partition = format!("{}|{generation:?}", partition(&options));
    let initial_headers = match &session {
        Some(session) => session.headers(url.as_str(), &headers)?,
        None => headers.clone(),
    };
    let bypass_cache = policy::header(&headers, "cache-time") == Some("no");
    if bypass_cache {
        policy::remove(&policy::key(
            url.as_str(),
            &initial_headers,
            &cache_partition,
        ));
    }
    let cacheable = method.eq_ignore_ascii_case("GET")
        && !has_upload
        && body.is_none()
        && policy::header(&headers, "range").is_none()
        && !bypass_cache;
    let key = cacheable.then(|| policy::key(url.as_str(), &initial_headers, &cache_partition));
    if let Some(cached) = key
        .as_ref()
        .and_then(|k| policy::get(k, policy::header(&headers, "cache-time") == Some("long")))
    {
        let mut headers = cached.headers;
        headers.push(HttpHeader {
            name: "venera-cache".into(),
            value: "true".into(),
        });
        return Ok(HttpResponse {
            status: cached.status,
            url: cached.url,
            headers,
            response: AsyncMutex::new(ResponseState {
                native: None,
                cached: Some(cached.body),
                collecting: None,
                key: None,
                serial,
            }),
        });
    }
    let redirects = options.max_redirects;
    if session.is_some() {
        options.max_redirects = 0;
    }
    let client = client(&options)?;
    let method = method.parse()?;
    let body = if has_upload {
        Some(upload.body()?)
    } else {
        body.map(reqwest::Body::from)
    };
    let (response, redirected) = tokio::select! {
        biased;
        _ = cancellation.cancelled() => return Err(anyhow!("Request cancelled")),
        response = async {
            if let Some(session) = session {
                session.send(&client, url.clone(), method, headers, initial_headers, body, redirects).await
            } else {
                let response = policy::request(&client, method, url.clone(), &initial_headers, body)
                    .send().await.map_err(transport_error)?;
                Ok((response, false))
            }
        } => response?,
    };
    let key = key.filter(|_| {
        store.is_none()
            || (!redirected && !response.headers().contains_key(reqwest::header::SET_COOKIE))
    });
    let headers = response
        .headers()
        .iter()
        .map(|(name, value)| HttpHeader {
            name: name.to_string(),
            value: String::from_utf8_lossy(value.as_bytes()).into_owned(),
        })
        .collect();
    Ok(HttpResponse {
        status: response.status().as_u16(),
        url: response.url().to_string(),
        headers,
        response: AsyncMutex::new(ResponseState {
            native: Some(response),
            cached: None,
            collecting: key.as_ref().map(|_| Vec::new()),
            key,
            serial,
        }),
    })
}

#[flutter_rust_bridge::frb(sync)]
pub fn clear_http_cache() {
    crate::http_policy::clear();
}

#[cfg(test)]
mod tests {
    use super::*;
    use std::io::{Read, Write};
    use tokio::io::{AsyncReadExt, AsyncWriteExt};

    fn options() -> HttpOptions {
        HttpOptions {
            proxy: None,
            dns_overrides: HashMap::new(),
            tls_sni: true,
            verify_certificates: true,
            connect_timeout_ms: 5000,
            receive_timeout_ms: 5000,
            max_redirects: 5,
        }
    }

    #[tokio::test]
    async fn streams_binary_response_and_preserves_duplicate_headers() -> Result<()> {
        let server = std::net::TcpListener::bind("127.0.0.1:0")?;
        let url = format!("http://{}/", server.local_addr()?);
        let thread = std::thread::spawn(move || {
            let (mut socket, _) = server.accept().unwrap();
            let mut buffer = [0; 4096];
            let mut request = Vec::new();
            while !request.ends_with(b"\r\n\r\n") {
                let read = socket.read(&mut buffer).unwrap();
                assert!(read > 0, "client closed before sending headers");
                request.extend_from_slice(&buffer[..read]);
            }
            socket.write_all(b"HTTP/1.1 200 OK\r\nContent-Length: 3\r\nSet-Cookie: a=1\r\nSet-Cookie: b=2\r\nConnection: close\r\n\r\n\x00\x7f\xff").unwrap();
        });
        let cancellation = HttpCancellation::new();
        let response = http_request(
            url,
            "GET".into(),
            vec![],
            None,
            &HttpUpload::new(),
            false,
            options(),
            &cancellation,
        )
        .await?;
        assert_eq!(response.status(), 200);
        assert_eq!(
            response
                .headers()
                .iter()
                .filter(|h| h.name == "set-cookie")
                .count(),
            2
        );
        let mut bytes = Vec::new();
        while let Some(chunk) = response.next_chunk(&cancellation).await? {
            bytes.extend(chunk);
        }
        assert_eq!(bytes, vec![0, 127, 255]);
        thread.join().unwrap();
        Ok(())
    }

    #[tokio::test]
    async fn cancellation_is_not_lost_before_request_starts() {
        let cancellation = HttpCancellation::new();
        cancellation.cancel();
        assert!(http_request(
            "http://127.0.0.1:1/".into(),
            "GET".into(),
            vec![],
            None,
            &HttpUpload::new(),
            false,
            options(),
            &cancellation
        )
        .await
        .is_err());
    }

    async fn server(
        replies: Vec<String>,
    ) -> Result<(SocketAddr, tokio::task::JoinHandle<Result<Vec<String>>>)> {
        let listener = tokio::net::TcpListener::bind("127.0.0.1:0").await?;
        let address = listener.local_addr()?;
        let task = tokio::spawn(async move {
            tokio::time::timeout(Duration::from_secs(10), async move {
                let mut requests = Vec::new();
                for reply in replies {
                    let (mut socket, _) = listener.accept().await?;
                    let mut request = Vec::new();
                    let mut chunk = [0; 4096];
                    while !request.windows(4).any(|window| window == b"\r\n\r\n") {
                        let size = socket.read(&mut chunk).await?;
                        anyhow::ensure!(size != 0, "Client closed before sending headers");
                        request.extend_from_slice(&chunk[..size]);
                    }
                    socket.write_all(reply.as_bytes()).await?;
                    requests.push(String::from_utf8(request)?.to_ascii_lowercase());
                }
                Ok(requests)
            })
            .await?
        });
        Ok((address, task))
    }

    fn source(path: String) -> SourceHttpOptions {
        SourceHttpOptions {
            cookie_path: path,
            user_agent: "source-agent".into(),
            legacy_clearance_user_agent: Some("legacy-agent".into()),
        }
    }

    async fn source_get(
        url: &str,
        headers: Vec<HttpHeader>,
        options: HttpOptions,
        source: SourceHttpOptions,
    ) -> Result<HttpResponse> {
        source_http_request(
            url.into(),
            "GET".into(),
            headers,
            None,
            &HttpUpload::new(),
            false,
            options,
            source,
            &HttpCancellation::new(),
        )
        .await
    }

    #[tokio::test]
    async fn source_redirects_scope_credentials_and_report_the_effective_challenge_url(
    ) -> Result<()> {
        let directory = tempfile::tempdir()?;
        let path = directory
            .path()
            .join("cookie.db")
            .to_string_lossy()
            .into_owned();
        let jar = CookieStore::open(path.clone())?;
        let (address, target) = server(vec![
            "HTTP/1.1 403 Forbidden\r\ncf-mitigated: challenge\r\nSet-Cookie: ignored=1; Path=/\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".into(),
            "HTTP/1.1 403 Forbidden\r\ncf-mitigated: challenge\r\nContent-Length: 0\r\nConnection: close\r\n\r\n".into(),
        ]).await?;
        let destination = format!("http://other.example:{}/challenge", address.port());
        let (initial, origin) = server(vec![format!(
            "HTTP/1.1 302 Found\r\nLocation: {destination}\r\nSet-Cookie: origin=1; Path=/\r\nContent-Length: 0\r\nConnection: close\r\n\r\n",
        )]).await?;
        let original = format!("http://source.example:{}/", initial.port());
        jar.save_headers(destination.clone(), vec!["target=1; Path=/".into()])?;
        let mut transport = options();
        transport.dns_overrides = ["source.example", "other.example"]
            .into_iter()
            .map(|host| (host.into(), "127.0.0.1".into()))
            .collect();
        let error = source_get(
            &original,
            vec![HttpHeader {
                name: "Authorization".into(),
                value: "secret".into(),
            }],
            transport.clone(),
            source(path),
        )
        .await
        .err()
        .context("Expected challenge")?;
        assert_eq!(
            error.to_string(),
            format!("CloudflareException: {destination}")
        );
        assert_eq!(jar.header(original)?, "origin=1");
        assert_eq!(jar.header(destination.clone())?, "target=1");

        let response = http_request(
            destination,
            "GET".into(),
            vec![],
            None,
            &HttpUpload::new(),
            false,
            transport,
            &HttpCancellation::new(),
        )
        .await?;
        assert_eq!(response.status(), 403);
        let origin_requests = origin.await??;
        assert!(origin_requests[0].contains("authorization: secret"));
        let target_requests = target.await??;
        assert!(target_requests[0].contains("cookie: target=1"));
        assert!(!target_requests[0].contains("authorization:"));
        assert!(!target_requests[0].contains("origin=1"));
        assert!(!target_requests[1].contains("cookie:"));
        Ok(())
    }

    #[tokio::test]
    async fn source_cache_follows_account_and_transport_changes() -> Result<()> {
        let (address, origin) = server(
            ["first", "second", "direct"]
                .map(|body| {
                    format!(
                        "HTTP/1.1 200 OK\r\nContent-Length: {}\r\nConnection: close\r\n\r\n{body}",
                        body.len()
                    )
                })
                .into(),
        )
        .await?;
        let directory = tempfile::tempdir()?;
        let path = directory
            .path()
            .join("cookie.db")
            .to_string_lossy()
            .into_owned();
        let jar = CookieStore::open(path.clone())?;
        let url = format!("http://source.example:{}/", address.port());
        let source = source(path);
        let mut transport = options();
        transport
            .dns_overrides
            .insert("source.example".into(), "127.0.0.1".into());
        let headers = vec![HttpHeader {
            name: "cache-time".into(),
            value: "long".into(),
        }];
        let body = |transport| {
            let url = &url;
            let headers = headers.clone();
            let source = source.clone();
            async move {
                let response = source_get(url, headers, transport, source).await?;
                let cancellation = HttpCancellation::new();
                let mut bytes = Vec::new();
                while let Some(chunk) = response.next_chunk(&cancellation).await? {
                    bytes.extend(chunk);
                }
                Ok::<_, anyhow::Error>(String::from_utf8(bytes)?)
            }
        };
        jar.save_headers(url.clone(), vec!["account=one; Path=/".into()])?;
        assert_eq!(body(transport.clone()).await?, "first");
        assert_eq!(body(transport.clone()).await?, "first");
        jar.save_headers(url.clone(), vec!["account=two; Path=/".into()])?;
        assert_eq!(body(transport.clone()).await?, "second");
        transport
            .dns_overrides
            .insert("source.example".into(), "invalid-ip".into());
        assert!(body(transport.clone())
            .await
            .unwrap_err()
            .to_string()
            .contains("Invalid DNS"));
        let (proxy, proxy_server) = server(vec![
            "HTTP/1.1 200 OK\r\nContent-Length: 5\r\nConnection: close\r\n\r\nproxy".into(),
        ])
        .await?;
        transport.dns_overrides.clear();
        transport.proxy = Some(proxy.to_string());
        assert_eq!(body(transport.clone()).await?, "proxy");
        assert!(proxy_server.await??[0].starts_with(&format!("get {url} ")));
        jar.clear()?;
        transport.proxy = None;
        transport
            .dns_overrides
            .insert("source.example".into(), "127.0.0.1".into());
        assert_eq!(body(transport).await?, "direct");
        let requests = origin.await??;
        assert!(requests[0].contains("cookie: account=one"));
        assert!(requests[1].contains("cookie: account=two"));
        assert!(!requests[2].contains("cookie:"));
        Ok(())
    }

    #[tokio::test]
    async fn cancels_serial_wait_and_blocked_upload() -> Result<()> {
        let url = "http://localhost/serial-cancellation";
        let guard = crate::http_policy::serial(url).await;
        let cancellation = HttpCancellation::new();
        let upload = HttpUpload::new();
        let source = source("unused-while-waiting".into());
        let request = source_http_request(
            url.into(),
            "GET".into(),
            vec![HttpHeader {
                name: "prevent-parallel".into(),
                value: "true".into(),
            }],
            None,
            &upload,
            false,
            options(),
            source,
            &cancellation,
        );
        tokio::pin!(request);
        assert!(futures_util::poll!(&mut request).is_pending());
        cancellation.cancel();
        assert_eq!(
            request
                .await
                .err()
                .context("Expected cancellation")?
                .to_string(),
            "Request cancelled"
        );
        drop(guard);

        let body = upload.body()?;
        for _ in 0..8 {
            upload.write(vec![1]).await?;
        }
        let write = upload.write(vec![2]);
        tokio::pin!(write);
        assert!(futures_util::poll!(&mut write).is_pending());
        upload.abort()?;
        assert!(write.await.is_err());
        drop(body);
        Ok(())
    }
}
