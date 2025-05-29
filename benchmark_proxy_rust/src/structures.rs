use serde::{Serialize, Deserialize};
use url::Url;
use http::StatusCode;
use std::time::{Duration, SystemTime};

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct JsonRpcRequest {
    pub method: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub id: Option<serde_json::Value>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub jsonrpc: Option<String>,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub params: Option<serde_json::Value>,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct BatchInfo {
    pub is_batch: bool,
    pub methods: Vec<String>,
    pub request_count: usize,
    pub has_stateful: bool,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
pub struct Backend {
    #[serde(with = "url_serde")]
    pub url: Url,
    pub name: String,
    pub role: String, // Consider an enum BackendRole { Primary, Secondary } later
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct ResponseStats {
    pub backend_name: String,
    #[serde(skip_serializing_if = "Option::is_none")]
    #[serde(with = "http_serde_status_code_option", default)]
    pub status_code: Option<StatusCode>,
    #[serde(with = "humantime_serde")]
    pub duration: Duration,
    #[serde(skip_serializing_if = "Option::is_none")]
    pub error: Option<String>,
    pub method: String,
}

#[derive(Debug, Clone, serde::Serialize, serde::Deserialize)]
pub struct WebSocketStats {
    pub backend_name: String,
    pub error: Option<String>, // Default Option<String> serde is fine
    pub connect_time: std::time::Duration, // Default Duration serde (secs/nanos struct)
    pub is_active: bool,
    pub client_to_backend_messages: u64,
    pub backend_to_client_messages: u64,
}

#[derive(Debug, Serialize, Deserialize, Clone)]
pub struct CuDataPoint {
    pub timestamp: SystemTime,
    pub cu: u64,
}

// Helper module for serializing/deserializing Option<http::StatusCode>
mod http_serde_status_code_option {
    use http::StatusCode;
    use serde::{self, Deserializer, Serializer, AsOwned};

    pub fn serialize<S>(status_code: &Option<StatusCode>, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        match status_code {
            Some(sc) => serializer.serialize_some(&sc.as_u16()),
            None => serializer.serialize_none(),
        }
    }

    pub fn deserialize<'de, D>(deserializer: D) -> Result<Option<StatusCode>, D::Error>
    where
        D: Deserializer<'de>,
    {
        Option::<u16>::deserialize(deserializer)?
            .map(|code| StatusCode::from_u16(code).map_err(serde::de::Error::custom))
            .transpose()
    }
}

// Helper module for serializing/deserializing url::Url
mod url_serde {
    use url::Url;
    use serde::{self, Deserializer, Serializer};

    pub fn serialize<S>(url: &Url, serializer: S) -> Result<S::Ok, S::Error>
    where
        S: Serializer,
    {
        serializer.serialize_str(url.as_str())
    }

    pub fn deserialize<'de, D>(deserializer: D) -> Result<Url, D::Error>
    where
        D: Deserializer<'de>,
    {
        String::deserialize(deserializer)?
            .parse()
            .map_err(serde::de::Error::custom)
    }
}
