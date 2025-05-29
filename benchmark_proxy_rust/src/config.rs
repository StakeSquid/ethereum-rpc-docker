use std::env;
use std::str::FromStr;
use std::time::Duration;
use url::Url;
use thiserror::Error;
use log::{warn, info};

#[derive(Debug, Error)]
pub enum ConfigError {
    #[error("Failed to parse environment variable '{var_name}': {source}")]
    ParseError {
        var_name: String,
        source: Box<dyn std::error::Error + Send + Sync>,
    },
    #[error("Missing required environment variable: {var_name}")]
    MissingVariable { var_name: String },
    #[error("Invalid URL format for '{var_name}': {url_str} - {source}")]
    UrlParseError {
        var_name: String,
        url_str: String,
        source: url::ParseError,
    },
}

#[derive(Debug, Clone)]
pub struct AppConfig {
    pub listen_addr: String,
    pub primary_backend_url: Url,
    pub secondary_backend_urls: Vec<Url>,
    pub summary_interval_secs: u64,
    pub enable_detailed_logs: bool,
    pub enable_secondary_probing: bool,
    pub probe_interval_secs: u64,
    pub min_delay_buffer_ms: u64,
    pub probe_methods: Vec<String>,
    pub enable_block_height_tracking: bool,
    pub max_blocks_behind: u64,
    pub enable_expensive_method_routing: bool,
    pub max_body_size_bytes: usize,
    pub http_client_timeout_secs: u64,
    pub request_context_timeout_secs: u64,
}

// Helper function to get and parse environment variables
fn get_env_var<T: FromStr>(key: &str, default_value: T) -> T
where
    <T as FromStr>::Err: std::fmt::Display,
{
    match env::var(key) {
        Ok(val_str) => match val_str.parse::<T>() {
            Ok(val) => val,
            Err(e) => {
                warn!(
                    "Failed to parse environment variable '{}' with value '{}': {}. Using default: {:?}",
                    key, val_str, e, default_value
                );
                default_value
            }
        },
        Err(_) => default_value,
    }
}

// Helper function for boolean environment variables
fn get_env_var_bool(key: &str, default_value: bool) -> bool {
    match env::var(key) {
        Ok(val_str) => val_str.to_lowercase() == "true",
        Err(_) => default_value,
    }
}

// Helper function for Vec<String> from comma-separated string
fn get_env_var_vec_string(key: &str, default_value: Vec<String>) -> Vec<String> {
    match env::var(key) {
        Ok(val_str) => {
            if val_str.is_empty() {
                default_value
            } else {
                val_str.split(',').map(|s| s.trim().to_string()).collect()
            }
        }
        Err(_) => default_value,
    }
}

// Helper function for Vec<Url> from comma-separated string
fn get_env_var_vec_url(key: &str, default_value: Vec<Url>) -> Result<Vec<Url>, ConfigError> {
    match env::var(key) {
        Ok(val_str) => {
            if val_str.is_empty() {
                return Ok(default_value);
            }
            val_str
                .split(',')
                .map(|s| s.trim())
                .filter(|s| !s.is_empty())
                .map(|url_str| {
                    Url::parse(url_str).map_err(|e| ConfigError::UrlParseError {
                        var_name: key.to_string(),
                        url_str: url_str.to_string(),
                        source: e,
                    })
                })
                .collect()
        }
        Err(_) => Ok(default_value),
    }
}


pub fn load_from_env() -> Result<AppConfig, ConfigError> {
    info!("Loading configuration from environment variables...");

    let primary_backend_url_str = env::var("PRIMARY_BACKEND_URL").map_err(|_| {
        ConfigError::MissingVariable {
            var_name: "PRIMARY_BACKEND_URL".to_string(),
        }
    })?;
    let primary_backend_url =
        Url::parse(&primary_backend_url_str).map_err(|e| ConfigError::UrlParseError {
            var_name: "PRIMARY_BACKEND_URL".to_string(),
            url_str: primary_backend_url_str,
            source: e,
        })?;

    let secondary_backend_urls = get_env_var_vec_url("SECONDARY_BACKEND_URLS", Vec::new())?;

    let config = AppConfig {
        listen_addr: get_env_var("LISTEN_ADDR", "127.0.0.1:8080".to_string()),
        primary_backend_url,
        secondary_backend_urls,
        summary_interval_secs: get_env_var("SUMMARY_INTERVAL_SECS", 60),
        enable_detailed_logs: get_env_var_bool("ENABLE_DETAILED_LOGS", false),
        enable_secondary_probing: get_env_var_bool("ENABLE_SECONDARY_PROBING", true),
        probe_interval_secs: get_env_var("PROBE_INTERVAL_SECS", 10),
        min_delay_buffer_ms: get_env_var("MIN_DELAY_BUFFER_MS", 500),
        probe_methods: get_env_var_vec_string(
            "PROBE_METHODS",
            vec!["eth_blockNumber".to_string(), "net_version".to_string()],
        ),
        enable_block_height_tracking: get_env_var_bool("ENABLE_BLOCK_HEIGHT_TRACKING", true),
        max_blocks_behind: get_env_var("MAX_BLOCKS_BEHIND", 5),
        enable_expensive_method_routing: get_env_var_bool("ENABLE_EXPENSIVE_METHOD_ROUTING", false),
        max_body_size_bytes: get_env_var("MAX_BODY_SIZE_BYTES", 10 * 1024 * 1024), // 10MB
        http_client_timeout_secs: get_env_var("HTTP_CLIENT_TIMEOUT_SECS", 30),
        request_context_timeout_secs: get_env_var("REQUEST_CONTEXT_TIMEOUT_SECS", 35),
    };

    info!("Configuration loaded successfully: {:?}", config);
    Ok(config)
}

impl AppConfig {
    pub fn http_client_timeout(&self) -> Duration {
        Duration::from_secs(self.http_client_timeout_secs)
    }

    pub fn request_context_timeout(&self) -> Duration {
        Duration::from_secs(self.request_context_timeout_secs)
    }

    pub fn summary_interval(&self) -> Duration {
        Duration::from_secs(self.summary_interval_secs)
    }

    pub fn probe_interval(&self) -> Duration {
        Duration::from_secs(self.probe_interval_secs)
    }
}
