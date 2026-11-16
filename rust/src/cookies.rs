use crate::{api::cookies::StoredCookie, cache::now_ms};
use anyhow::{Context, Result};
use rusqlite::{params, Connection};
use url::Url;

pub struct Cookies {
    db: Connection,
}

fn domain_matches(host: &str, domain: &str) -> bool {
    if let Some(domain) = domain.strip_prefix('.') {
        psl::domain_str(domain).is_some()
            && (host == domain || host.ends_with(&format!(".{domain}")))
    } else {
        host == domain
    }
}

fn path_matches(request: &str, cookie: &str) -> bool {
    request == cookie
        || request.starts_with(cookie)
            && (cookie.ends_with('/') || request.as_bytes().get(cookie.len()) == Some(&b'/'))
}

fn scope(uri: &Url, cookie: &StoredCookie) -> Option<(String, String, Option<i64>)> {
    if reqwest::header::HeaderName::from_bytes(cookie.name.as_bytes()).is_err()
        || cookie
            .value
            .bytes()
            .any(|b| b == b';' || b.is_ascii_control())
        || (cookie.secure && uri.scheme() != "https")
    {
        return None;
    }
    let host = uri.host_str()?;
    let domain = match &cookie.domain {
        Some(domain) => {
            let domain = domain.trim_start_matches('.').to_ascii_lowercase();
            if domain == host && (uri.domain().is_none() || psl::domain_str(&domain).is_none()) {
                host.to_owned()
            } else {
                let domain = format!(".{domain}");
                if uri.domain().is_none() || !domain_matches(host, &domain) {
                    return None;
                }
                domain
            }
        }
        None => host.to_owned(),
    };
    let path = cookie
        .path
        .clone()
        .filter(|p| p.starts_with('/'))
        .unwrap_or_else(|| match uri.path().rsplit_once('/') {
            Some((path, _)) if !path.is_empty() => path.into(),
            _ => "/".into(),
        });
    let expires = cookie
        .max_age
        .map(|seconds| now_ms().saturating_add(seconds.saturating_mul(1000)))
        .or(cookie.expires_ms);
    Some((domain, path, expires))
}

impl Cookies {
    pub fn open(path: &str) -> Result<Self> {
        let db = Connection::open(path)?;
        db.busy_timeout(std::time::Duration::from_secs(5))?;
        db.execute_batch("CREATE TABLE IF NOT EXISTS cookies (name TEXT NOT NULL, value TEXT NOT NULL, domain TEXT NOT NULL, path TEXT, expires INTEGER, secure INTEGER, httpOnly INTEGER, PRIMARY KEY(name,domain,path));")?;
        if !db.query_row(
            "SELECT EXISTS(SELECT 1 FROM pragma_table_info('cookies') WHERE name='userAgent')",
            [],
            |row| row.get::<_, bool>(0),
        )? {
            db.execute("ALTER TABLE cookies ADD COLUMN userAgent TEXT", [])?;
        }
        Ok(Self { db })
    }

    pub fn save(&mut self, url: &str, cookies: Vec<StoredCookie>) -> Result<()> {
        self.save_with_agent(url, cookies, None)
    }

    pub fn save_with_agent(
        &mut self,
        url: &str,
        cookies: Vec<StoredCookie>,
        user_agent: Option<&str>,
    ) -> Result<()> {
        let uri = Url::parse(url)?;
        uri.host_str().context("cookie URL has no host")?;
        let transaction = self.db.transaction()?;
        for cookie in cookies {
            let Some((domain, path, expires)) = scope(&uri, &cookie) else {
                continue;
            };
            if expires.is_some_and(|t| t <= now_ms()) {
                transaction.execute(
                    "DELETE FROM cookies WHERE name=? AND domain=? AND path=?",
                    params![cookie.name, domain, path],
                )?;
                continue;
            }
            let user_agent = if cookie.name == "cf_clearance" {
                user_agent
            } else {
                None
            };
            transaction.execute(
                "INSERT INTO cookies (name,value,domain,path,expires,secure,httpOnly,userAgent)
                 VALUES (?,?,?,?,?,?,?,?)
                 ON CONFLICT(name,domain,path) DO UPDATE SET value=excluded.value,
                   expires=excluded.expires, secure=excluded.secure, httpOnly=excluded.httpOnly,
                   userAgent=CASE WHEN cookies.value=excluded.value
                     THEN COALESCE(excluded.userAgent,cookies.userAgent) ELSE excluded.userAgent END",
                params![cookie.name,cookie.value,domain,path,expires,cookie.secure,cookie.http_only,user_agent],
            )?;
        }
        transaction.commit()?;
        Ok(())
    }

    pub fn save_verification(
        &mut self,
        url: &str,
        cookies: Vec<StoredCookie>,
        user_agent: &str,
    ) -> Result<bool> {
        let cookies = Self::webview_cookies(url, cookies)?;
        if !cookies
            .iter()
            .any(|cookie| cookie.name == "cf_clearance" && !cookie.value.is_empty())
        {
            return Ok(false);
        }
        self.save_with_agent(url, cookies, Some(user_agent))?;
        Ok(true)
    }

    pub fn save_webview(
        &mut self,
        url: &str,
        cookies: Vec<StoredCookie>,
        user_agent: Option<&str>,
    ) -> Result<()> {
        self.save_with_agent(url, Self::webview_cookies(url, cookies)?, user_agent)
    }

    fn webview_cookies(url: &str, mut cookies: Vec<StoredCookie>) -> Result<Vec<StoredCookie>> {
        let uri = Url::parse(url)?;
        // WebViews use a leading dot for domain cookies and may return all cookies.
        for cookie in &mut cookies {
            if cookie.domain.as_deref() == uri.host_str() {
                cookie.domain = None;
            }
        }
        cookies.retain(|cookie| {
            scope(&uri, cookie).is_some_and(|(_, path, expires)| {
                path_matches(uri.path(), &path) && expires.is_none_or(|time| time > now_ms())
            })
        });
        Ok(cookies)
    }

    pub fn save_headers(
        &mut self,
        url: &str,
        headers: Vec<String>,
        user_agent: Option<&str>,
    ) -> Result<()> {
        let cookies = headers
            .into_iter()
            .filter_map(|header| cookie::Cookie::parse(header).ok())
            .map(|cookie| StoredCookie {
                name: cookie.name().to_owned(),
                value: cookie.value().to_owned(),
                domain: cookie.domain().map(str::to_owned),
                path: cookie.path().map(str::to_owned),
                expires_ms: cookie
                    .expires_datetime()
                    .map(|d| (d.unix_timestamp_nanos() / 1_000_000) as i64),
                max_age: cookie.max_age().map(|d| d.whole_seconds()),
                secure: cookie.secure().unwrap_or(false),
                http_only: cookie.http_only().unwrap_or(false),
            })
            .collect();
        self.save_with_agent(url, cookies, user_agent)
    }

    pub fn load(&mut self, url: &str) -> Result<Vec<StoredCookie>> {
        Ok(self
            .load_with_agents(url)?
            .into_iter()
            .map(|(cookie, _)| cookie)
            .collect())
    }

    pub fn load_with_agents(&mut self, url: &str) -> Result<Vec<(StoredCookie, Option<String>)>> {
        let uri = Url::parse(url)?;
        let host = uri.host_str().context("cookie URL has no host")?;
        self.db.execute(
            "DELETE FROM cookies WHERE expires IS NOT NULL AND expires <= ?",
            [now_ms()],
        )?;
        let mut statement = self.db.prepare(
            "SELECT name,value,domain,path,expires,secure,httpOnly,userAgent FROM cookies
             ORDER BY length(path) DESC, length(ltrim(domain,'.')) DESC, domain LIKE '.%', rowid ASC",
        )?;
        let rows = statement.query_map([], |r| {
            Ok((
                StoredCookie {
                    name: r.get(0)?,
                    value: r.get(1)?,
                    domain: r.get(2)?,
                    path: r.get(3)?,
                    expires_ms: r.get(4)?,
                    secure: r.get::<_, Option<bool>>(5)?.unwrap_or(false),
                    http_only: r.get::<_, Option<bool>>(6)?.unwrap_or(false),
                    max_age: None,
                },
                r.get(7)?,
            ))
        })?;
        Ok(rows
            .collect::<rusqlite::Result<Vec<_>>>()?
            .into_iter()
            .filter(|(c, _)| {
                domain_matches(host, c.domain.as_deref().unwrap_or(""))
                    && path_matches(uri.path(), c.path.as_deref().unwrap_or("/"))
                    && (!c.secure || uri.scheme() == "https")
            })
            .collect())
    }

    pub fn delete(&mut self, url: &str, name: Option<&str>) -> Result<()> {
        let uri = Url::parse(url)?;
        let host = uri.host_str().context("cookie URL has no host")?;
        let domains = {
            let mut statement = self.db.prepare("SELECT DISTINCT domain FROM cookies")?;
            let rows = statement.query_map([], |r| r.get::<_, String>(0))?;
            rows.collect::<rusqlite::Result<Vec<_>>>()?
        };
        let transaction = self.db.transaction()?;
        for domain in domains.into_iter().filter(|d| domain_matches(host, d)) {
            if let Some(name) = name {
                transaction.execute(
                    "DELETE FROM cookies WHERE domain=? AND name=? AND path=?",
                    params![domain, name, uri.path()],
                )?;
            } else {
                transaction.execute("DELETE FROM cookies WHERE domain=?", [domain])?;
            }
        }
        transaction.commit()?;
        Ok(())
    }

    pub fn clear(&mut self) -> Result<()> {
        self.db.execute("DELETE FROM cookies", [])?;
        Ok(())
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn cookie_scope_expiry_and_persistence() -> Result<()> {
        let directory = tempfile::tempdir()?;
        let path = directory.path().join("cookie.db");
        let path = path.to_str().unwrap();
        let mut jar = Cookies::open(path)?;
        jar.save_headers(
            "https://example.com/account/login",
            vec![
                "host=1; Path=/; Secure".into(),
                "shared=2; Domain=example.com; Path=/account; HttpOnly".into(),
                "evil=3; Domain=other.com; Path=/".into(),
                "expired=4; Max-Age=0".into(),
            ],
            None,
        )?;
        assert_eq!(jar.load("https://example.com/account")?.len(), 2);
        assert_eq!(jar.load("https://child.example.com/account")?.len(), 1);
        assert!(jar.load("https://child.example.com/accounting")?.is_empty());
        assert!(jar.load("http://example.com/")?.is_empty());
        drop(jar);
        let mut jar = Cookies::open(path)?;
        assert_eq!(jar.load("https://example.com/")?.len(), 1);
        jar.clear()?;
        assert!(jar.load("https://example.com/")?.is_empty());
        Ok(())
    }
}
