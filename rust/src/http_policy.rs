use crate::api::{
    cookies::CookieStore,
    http::{transport_error, HttpHeader, HttpOptions, SourceHttpOptions},
};
use anyhow::{ensure, Result};
use reqwest::{header, Body, Client, Method, RequestBuilder, Response, StatusCode, Url};
use sha2::{Digest, Sha256};
use std::{
    collections::{HashMap, VecDeque},
    path::{Path, PathBuf},
    sync::{Arc, Mutex, OnceLock, Weak},
    time::{Duration, Instant},
};

fn source_settings() -> &'static Mutex<HashMap<PathBuf, HttpOptions>> {
    static SETTINGS: OnceLock<Mutex<HashMap<PathBuf, HttpOptions>>> = OnceLock::new();
    SETTINGS.get_or_init(Default::default)
}

pub(crate) fn configure_source(cookie_path: &str, options: HttpOptions) {
    source_settings()
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .insert(Path::new(cookie_path).components().collect(), options);
}

pub(crate) fn source_options(cookie_path: &str, fallback: &HttpOptions) -> HttpOptions {
    let path: PathBuf = Path::new(cookie_path).components().collect();
    source_settings()
        .lock()
        .unwrap_or_else(|e| e.into_inner())
        .get(&path)
        .unwrap_or(fallback)
        .clone()
}

pub(crate) fn is_challenge_page(head: &str, body: &str) -> bool {
    [
        "#challenge-success-text",
        "#challenge-error-text",
        "#challenge-form",
    ]
    .iter()
    .any(|marker| head.contains(marker))
        || ["challenge-platform", "window._cf_chl_opt"]
            .iter()
            .any(|marker| body.contains(marker))
}

pub(crate) fn request(
    client: &Client,
    method: Method,
    url: Url,
    headers: &[HttpHeader],
    body: Option<Body>,
) -> RequestBuilder {
    let mut request = client.request(method, url);
    for header in headers.iter().filter(|h| !is_policy(&h.name)) {
        request = request.header(&header.name, &header.value);
    }
    if let Some(body) = body {
        request = request.body(body);
    }
    request
}

pub(crate) struct Session<'a> {
    pub config: &'a SourceHttpOptions,
    pub store: &'a CookieStore,
    pub generation: i64,
}

impl Session<'_> {
    pub fn headers(&self, url: &str, supplied: &[HttpHeader]) -> Result<Vec<HttpHeader>> {
        let stored = self.store.request_cookies(url, self.generation)?;
        let mut headers = supplied.to_vec();
        let explicit_cookie = header(supplied, "cookie");
        if explicit_cookie.is_none() && !stored.is_empty() {
            let mut has_clearance = false;
            let mut values = Vec::new();
            for (cookie, _) in &stored {
                if cookie.name == "cf_clearance" {
                    if has_clearance || cookie.value.is_empty() {
                        continue;
                    }
                    has_clearance = true;
                }
                values.push(format!("{}={}", cookie.name, cookie.value));
            }
            if !values.is_empty() {
                headers.push(HttpHeader {
                    name: "cookie".into(),
                    value: values.join("; "),
                });
            }
        }
        let clearance = header(&headers, "cookie").and_then(|value| {
            value
                .split(';')
                .filter_map(|pair| pair.trim().split_once('='))
                .find_map(|(name, value)| {
                    (name == "cf_clearance" && !value.is_empty()).then_some(value)
                })
        });
        let agent = clearance.and_then(|value| {
            stored
                .iter()
                .find(|(cookie, _)| cookie.name == "cf_clearance" && cookie.value == value)
                .and_then(|(_, agent)| {
                    agent
                        .as_deref()
                        .or(self.config.legacy_clearance_user_agent.as_deref())
                })
        });
        if agent.is_some() {
            headers.retain(|h| !h.name.eq_ignore_ascii_case("user-agent"));
        }
        if header(&headers, "user-agent").is_none() {
            headers.push(HttpHeader {
                name: "user-agent".into(),
                value: agent.unwrap_or(&self.config.user_agent).into(),
            });
        }
        Ok(headers)
    }

    #[allow(clippy::too_many_arguments)]
    pub async fn send(
        &self,
        client: &Client,
        mut url: Url,
        mut method: Method,
        mut supplied: Vec<HttpHeader>,
        mut headers: Vec<HttpHeader>,
        mut body: Option<Body>,
        max_redirects: u32,
    ) -> Result<(Response, bool)> {
        let mut redirects = 0;
        loop {
            let reusable_body = body
                .as_ref()
                .and_then(|body| body.as_bytes())
                .map(Vec::from);
            let streaming = body.is_some() && reusable_body.is_none();
            let response = request(client, method.clone(), url.clone(), &headers, body)
                .send()
                .await
                .map_err(transport_error)?;
            if response.status() == StatusCode::FORBIDDEN
                && response
                    .headers()
                    .get_all("cf-mitigated")
                    .iter()
                    .any(|value| value.as_bytes().eq_ignore_ascii_case(b"challenge"))
            {
                anyhow::bail!("CloudflareException: {}", response.url());
            }
            self.store.save_response(
                response.url().as_str(),
                response
                    .headers()
                    .get_all(header::SET_COOKIE)
                    .iter()
                    .filter_map(|value| value.to_str().ok())
                    .map(str::to_owned)
                    .collect(),
                header(&headers, "user-agent"),
                self.generation,
            )?;

            let drop_body = matches!(
                response.status(),
                StatusCode::MOVED_PERMANENTLY | StatusCode::FOUND | StatusCode::SEE_OTHER
            );
            let preserve_body = matches!(
                response.status(),
                StatusCode::TEMPORARY_REDIRECT | StatusCode::PERMANENT_REDIRECT
            );
            if max_redirects == 0 || !(drop_body || preserve_body && !streaming) {
                return Ok((response, redirects != 0));
            }
            let Some(next) = response
                .headers()
                .get(header::LOCATION)
                .and_then(|value| value.to_str().ok())
                .and_then(|location| url.join(location).ok())
            else {
                return Ok((response, redirects != 0));
            };
            ensure!(redirects < max_redirects, "Too many redirects: {url}");
            ensure!(
                matches!(next.scheme(), "http" | "https"),
                "Invalid redirect URL: {next}"
            );
            redirects += 1;
            if drop_body {
                if method != Method::GET && method != Method::HEAD {
                    method = Method::GET;
                }
                supplied.retain(|h| {
                    ![
                        "content-length",
                        "content-type",
                        "content-encoding",
                        "transfer-encoding",
                    ]
                    .iter()
                    .any(|name| h.name.eq_ignore_ascii_case(name))
                });
                body = None;
            } else {
                body = reusable_body.map(Body::from);
            }
            if next.origin() != url.origin() {
                supplied.retain(|h| {
                    ![
                        "authorization",
                        "cookie",
                        "proxy-authorization",
                        "www-authenticate",
                        "host",
                    ]
                    .iter()
                    .any(|name| h.name.eq_ignore_ascii_case(name))
                });
            }
            supplied.retain(|h| !h.name.eq_ignore_ascii_case("referer"));
            if url.scheme() != "https" || next.scheme() != "http" {
                let mut referer = url.clone();
                let _ = referer.set_username("");
                let _ = referer.set_password(None);
                referer.set_fragment(None);
                supplied.push(HttpHeader {
                    name: "referer".into(),
                    value: referer.into(),
                });
            }
            url = next;
            headers = self.headers(url.as_str(), &supplied)?;
        }
    }
}

#[derive(Clone)]
pub struct Cached {
    pub headers: Vec<HttpHeader>,
    pub status: u16,
    pub url: String,
    pub body: Vec<u8>,
    time: Instant,
}
struct Cache {
    entries: VecDeque<(String, Cached)>,
    size: usize,
}
static CACHE: OnceLock<Mutex<Cache>> = OnceLock::new();
fn cache() -> &'static Mutex<Cache> {
    CACHE.get_or_init(|| {
        Mutex::new(Cache {
            entries: VecDeque::new(),
            size: 0,
        })
    })
}
pub fn clear() {
    let mut c = cache().lock().unwrap_or_else(|e| e.into_inner());
    c.entries.clear();
    c.size = 0;
}

pub fn remove(key: &str) {
    let mut cache = cache().lock().unwrap_or_else(|e| e.into_inner());
    if let Some(index) = cache.entries.iter().position(|(k, _)| k == key) {
        cache.size -= cache.entries.remove(index).unwrap().1.body.len();
    }
}
pub fn get(key: &str, long: bool) -> Option<Cached> {
    let c = cache().lock().unwrap_or_else(|e| e.into_inner());
    c.entries
        .iter()
        .find(|(k, v)| {
            k == key && v.time.elapsed() < Duration::from_secs(if long { 21600 } else { 5 })
        })
        .map(|(_, v)| v.clone())
}
pub fn put(key: String, headers: Vec<HttpHeader>, status: u16, url: String, body: Vec<u8>) {
    if status != 200
        || body.is_empty()
        || body.len() > 1024 * 1024
        || headers.iter().any(|h| {
            h.name.eq_ignore_ascii_case("cache-control")
                && h.value.to_lowercase().contains("no-store")
        })
    {
        return;
    }
    let mut c = cache().lock().unwrap_or_else(|e| e.into_inner());
    if let Some(index) = c.entries.iter().position(|(k, _)| k == &key) {
        c.size -= c.entries.remove(index).unwrap().1.body.len();
    }
    while c.size + body.len() > 10 * 1024 * 1024 {
        if let Some((_, old)) = c.entries.pop_front() {
            c.size -= old.body.len();
        } else {
            break;
        }
    }
    c.size += body.len();
    c.entries.push_back((
        key,
        Cached {
            headers,
            status,
            url,
            body,
            time: Instant::now(),
        },
    ));
}
pub fn key(url: &str, headers: &[HttpHeader], partition: &str) -> String {
    let mut headers: Vec<_> = headers
        .iter()
        .filter(|h| !is_policy(&h.name))
        .map(|h| (h.name.to_ascii_lowercase(), h.value.clone()))
        .collect();
    headers.sort();
    // Authorization, cookies and source tokens partition the cache without retaining their values.
    format!(
        "{:x}",
        Sha256::digest(format!("{:?}", (url, partition, headers)))
    )
}
pub fn is_policy(name: &str) -> bool {
    ["cache-time", "prevent-parallel", "http_client"]
        .iter()
        .any(|n| name.eq_ignore_ascii_case(n))
}
pub fn header<'a>(headers: &'a [HttpHeader], name: &str) -> Option<&'a str> {
    headers
        .iter()
        .find(|h| h.name.eq_ignore_ascii_case(name))
        .map(|h| h.value.as_str())
}
pub async fn serial(url: &str) -> tokio::sync::OwnedMutexGuard<()> {
    static LOCKS: OnceLock<Mutex<HashMap<String, Weak<tokio::sync::Mutex<()>>>>> = OnceLock::new();
    let mutex = {
        let mut locks = LOCKS
            .get_or_init(Default::default)
            .lock()
            .unwrap_or_else(|e| e.into_inner());
        locks.retain(|_, v| v.strong_count() > 0);
        if let Some(lock) = locks.get(url).and_then(Weak::upgrade) {
            lock
        } else {
            let lock = Arc::new(tokio::sync::Mutex::new(()));
            locks.insert(url.into(), Arc::downgrade(&lock));
            lock
        }
    };
    mutex.lock_owned().await
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn cache_isolates_credentials_and_honors_no_store() {
        let a = key(
            "test",
            &[HttpHeader {
                name: "Authorization".into(),
                value: "a".into(),
            }],
            "",
        );
        let b = key(
            "test",
            &[HttpHeader {
                name: "authorization".into(),
                value: "b".into(),
            }],
            "",
        );
        assert_ne!(a, b);
        put(a.clone(), vec![], 200, "test".into(), vec![1]);
        assert!(get(&a, false).is_some());
        assert!(get(&b, false).is_none());
        put(
            b.clone(),
            vec![HttpHeader {
                name: "cache-control".into(),
                value: "no-store".into(),
            }],
            200,
            "test".into(),
            vec![1],
        );
        assert!(get(&b, false).is_none());
    }
}
