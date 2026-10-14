//! The language models the notetaker talks to, each behind `meeting::summary::NoteModel`.
//!
//! Claude reads whole meetings: summaries, recaps and John's own questions mid-call. The
//! transcript goes to Anthropic's API, so it is used only once a key is saved. Ollama is the
//! local model, free and on the machine, for running notes and for summaries without a key.

use crate::meeting::summary::{ListSpec, ModelError, NoteModel, Request};
use crate::net::{HttpRequest, NetError, Transport};
use crate::notes::QuestionTurn;
use crate::text::unicode::trim_ws_nl;
use serde_json::{json, Value};
use std::path::PathBuf;
use std::sync::Arc;

// MARK: Claude

pub const CLAUDE_MODEL: &str = "claude-opus-5-5";
pub const CLAUDE_ENDPOINT: &str = "https://api.anthropic.com/v1/messages";

/// `~/.config/anthropic/lin-flow-key`, or `LINFLOW_CLAUDE_KEY_FILE` for a test. The same file the
/// Mac app reads, which `scripts/setup-claude.sh` writes.
pub fn claude_key_file() -> PathBuf {
    match std::env::var_os("LINFLOW_CLAUDE_KEY_FILE") {
        Some(p) => PathBuf::from(p),
        None => crate::paths::home().join(".config").join("anthropic").join("lin-flow-key"),
    }
}

pub fn load_claude_key() -> Option<String> {
    let raw = std::fs::read_to_string(claude_key_file()).ok()?;
    let key = trim_ws_nl(&raw);
    (!key.is_empty()).then(|| key.to_string())
}

pub struct Claude {
    key: String,
    net: Arc<dyn Transport>,
}

impl Claude {
    pub fn new(key: String, net: Arc<dyn Transport>) -> Self {
        Claude { key, net }
    }

    /// A client when a key is saved.
    pub fn from_saved_key(net: Arc<dyn Transport>) -> Option<Self> {
        load_claude_key().map(|k| Claude::new(k, net))
    }

    /// One request, one answer. Low effort: these are reading questions, often asked during a
    /// call, where a quick answer matters more than a deep one. `fallbacks: "default"` reruns a
    /// declined request on the model Anthropic picks for it instead of returning the refusal.
    pub fn request(key: &str, system: &str, user: &str, max_tokens: u32) -> HttpRequest {
        let body = json!({
            "model": CLAUDE_MODEL,
            "max_tokens": max_tokens,
            "fallbacks": "default",
            "output_config": {"effort": "low"},
            "system": system,
            "messages": [{"role": "user", "content": user}],
        });
        HttpRequest::post(CLAUDE_ENDPOINT, serde_json::to_vec(&body).unwrap())
            .header("content-type", "application/json")
            .header("x-api-key", key)
            .header("anthropic-version", "2023-06-01")
            .header("anthropic-beta", "server-side-fallback-2026-07-01")
            .timeout(120)
    }

    /// The answer's text blocks joined. Thinking blocks come back empty and are skipped.
    pub fn parse(status: u16, body: &[u8]) -> Result<String, ModelError> {
        let json: Option<Value> = serde_json::from_slice(body).ok();
        if !(200..300).contains(&status) {
            let message = json
                .as_ref()
                .and_then(|j| j["error"]["message"].as_str().map(String::from))
                .unwrap_or_else(|| String::from_utf8_lossy(&body[..body.len().min(300)]).to_string());
            return Err(if status == 401 {
                ModelError::Unavailable(format!("Claude refused the saved key: {message}"))
            } else {
                ModelError::Failed(format!("Claude answered {status}: {message}"))
            });
        }
        let json = json.unwrap_or(Value::Null);
        if json["stop_reason"] == "refusal" {
            return Err(ModelError::Refused);
        }
        let text: String = json["content"]
            .as_array()
            .map(|blocks| blocks.iter().filter(|b| b["type"] == "text").filter_map(|b| b["text"].as_str()).collect())
            .unwrap_or_default();
        let trimmed = trim_ws_nl(&text);
        if trimmed.is_empty() {
            return Err(ModelError::Empty);
        }
        Ok(trimmed.to_string())
    }

    pub fn ask(&self, system: &str, user: &str, max_tokens: u32) -> Result<String, ModelError> {
        match self.net.send(&Self::request(&self.key, system, user, max_tokens)) {
            Ok(r) => Self::parse(r.status, &r.body),
            Err(NetError::TimedOut) => Err(ModelError::Failed("Claude did not answer in 120 seconds".into())),
            Err(NetError::Other(why)) => Err(ModelError::Failed(why)),
        }
    }
}

/// How a list-shaped answer is asked for from a model with no schema to hold it to.
fn json_instructions(lists: &[ListSpec]) -> String {
    let keys = lists.iter().map(|l| format!("\"{}\": at most {} strings ({})", l.key, l.at_most, l.description)).collect::<Vec<_>>().join("; ");
    format!("\n\nAnswer with only a JSON object, no prose and no code fence, with these keys, each a list of strings: {keys}.")
}

impl NoteModel for Claude {
    fn name(&self) -> String {
        format!("Claude ({CLAUDE_MODEL})")
    }

    /// The whole meeting fits in one request.
    fn window_characters(&self) -> usize {
        500_000
    }

    fn complete(&mut self, request: &Request) -> Result<String, ModelError> {
        let instructions =
            if request.lists.is_empty() { request.instructions.clone() } else { format!("{}{}", request.instructions, json_instructions(&request.lists)) };
        self.ask(&instructions, &request.prompt, request.max_tokens.max(1024))
    }
}

/// What John can ask about a meeting, while it runs or after. Each question goes as one request
/// carrying the whole transcript so far, his own notes and the conversation before it, so
/// nothing depends on a server-side session.
pub mod questions {
    use super::*;

    /// The buttons above the question box. Each is just a question, so it lands in the
    /// conversation like a typed one.
    pub const QUICK: [(&str, &str); 3] = [
        ("Summarize so far", "Summarize the meeting so far: the main points, anything decided, and who owes what."),
        ("Last 5 minutes", "What did we talk about in the last 5 minutes?"),
        ("What should I ask?", "What are the best questions I could ask right now, given where the conversation is?"),
    ];

    pub const SYSTEM: &str = "You help John during and after his meetings. You get the transcript so far, any notes he typed, and his question. \"You\" in the transcript is John's microphone and \"Others\" is everyone else on the call, so names come only from what people say. The transcript is machine speech recognition: words can be misheard, so read through obvious errors and say so when something important is unclear rather than guessing. Answer from the transcript only. Be brief and concrete: he is often reading this while the call goes on.";

    pub fn prompt(title: &str, transcript: &str, notes: &str, earlier: &[QuestionTurn], question: &str) -> String {
        let mut parts = vec![format!("Meeting: {title}"), format!("Transcript so far:\n{}", if transcript.is_empty() { "(nothing yet)" } else { transcript })];
        let typed = trim_ws_nl(notes);
        if !typed.is_empty() {
            parts.push(format!("John's notes:\n{typed}"));
        }
        if !earlier.is_empty() {
            parts.push(format!(
                "Earlier in this conversation:\n{}",
                earlier.iter().map(|t| format!("John: {}\nYou: {}", t.question, t.answer)).collect::<Vec<_>>().join("\n\n")
            ));
        }
        parts.push(format!("John asks: {question}"));
        parts.join("\n\n")
    }
}

// MARK: Ollama

pub const OLLAMA_HOST: &str = "http://127.0.0.1:11434";
pub const OLLAMA_MODEL: &str = "qwen2.5:3b";

/// Ollama's local HTTP API with a small instruct model. Nothing leaves the machine. Address it as
/// 127.0.0.1, never localhost: Ollama binds IPv4 only, Windows tries ::1 first, and that dead
/// connection takes longer to fail than the health check allows.
pub struct Ollama {
    pub host: String,
    pub model: String,
    net: Arc<dyn Transport>,
    /// Ollama before 0.5 knows `format: "json"` but not a schema.
    schema_unsupported: bool,
}

impl Ollama {
    pub fn new(host: &str, model: &str, net: Arc<dyn Transport>) -> Self {
        let host = if host.trim().is_empty() { OLLAMA_HOST } else { host.trim().trim_end_matches('/') };
        let model = if model.trim().is_empty() { OLLAMA_MODEL } else { model.trim() };
        Ollama { host: host.into(), model: model.into(), net, schema_unsupported: false }
    }

    /// None when the server answers and the model is there; otherwise one sentence saying what to
    /// do about it. Two seconds at most, for `doctor` and for the start of a meeting.
    pub fn check(&self) -> Option<String> {
        let r = self.net.send(&HttpRequest::get(format!("{}/api/tags", self.host)).timeout(2));
        let Ok(r) = r.map_err(|_| ()).and_then(|r| if r.status == 200 { Ok(r) } else { Err(()) }) else {
            return Some(format!("Ollama is not answering at {}. Install it from ollama.com, then run: ollama pull {}", self.host, self.model));
        };
        let names: Vec<String> = serde_json::from_slice::<Value>(&r.body)
            .ok()
            .and_then(|v| v["models"].as_array().map(|a| a.iter().filter_map(|m| m["name"].as_str().map(String::from)).collect()))
            .unwrap_or_default();
        let m = &self.model;
        let have = names.iter().any(|n| n == m || *n == format!("{m}:latest") || (!m.contains(':') && n.starts_with(&format!("{m}:"))));
        if have {
            None
        } else {
            Some(format!("Ollama is running but the model is not there. Run: ollama pull {m}"))
        }
    }

    fn schema(lists: &[ListSpec]) -> Value {
        let mut properties = serde_json::Map::new();
        for l in lists {
            properties.insert(l.key.clone(), json!({"type": "array", "items": {"type": "string"}, "maxItems": l.at_most}));
        }
        json!({"type": "object", "properties": properties, "required": lists.iter().map(|l| l.key.clone()).collect::<Vec<_>>()})
    }

    pub fn chat(&mut self, request: &Request) -> Result<String, ModelError> {
        let mut instructions = request.instructions.clone();
        if !request.lists.is_empty() {
            instructions.push_str(&json_instructions(&request.lists));
        }
        let mut body = json!({
            "model": self.model,
            "stream": false,
            "keep_alive": "15m",
            "options": {"temperature": if request.greedy { 0.0 } else { 0.1 }, "num_predict": request.max_tokens, "num_ctx": 8192},
            "messages": [{"role": "system", "content": instructions}, {"role": "user", "content": request.prompt}],
        });
        if !request.lists.is_empty() {
            body["format"] = if self.schema_unsupported { json!("json") } else { Self::schema(&request.lists) };
        }
        let r = self
            .net
            .send(&HttpRequest::post(format!("{}/api/chat", self.host), serde_json::to_vec(&body).unwrap()).header("Content-Type", "application/json").timeout(120))
            .map_err(|e| ModelError::Unavailable(format!("Ollama is not answering at {}: {e}", self.host)))?;
        if r.status != 200 {
            let detail = String::from_utf8_lossy(&r.body).trim().to_string();
            if r.status == 400 && !request.lists.is_empty() && !self.schema_unsupported {
                self.schema_unsupported = true;
                return self.chat(request);
            }
            if detail.contains("context") && detail.contains("length") {
                return Err(ModelError::TooLong);
            }
            return Err(ModelError::Failed(format!("Ollama {}: {detail}", r.status)));
        }
        let json: Value = serde_json::from_slice(&r.body).map_err(|e| ModelError::Failed(e.to_string()))?;
        Ok(json["message"]["content"].as_str().unwrap_or("").to_string())
    }
}

impl NoteModel for Ollama {
    fn name(&self) -> String {
        format!("Ollama · {}", self.model)
    }

    /// A small model's context is held to 8192 tokens; this leaves room for the instructions and
    /// the answer.
    fn window_characters(&self) -> usize {
        6_500
    }

    fn complete(&mut self, request: &Request) -> Result<String, ModelError> {
        self.chat(request)
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    use crate::net::HttpResponse;
    use std::sync::Mutex;

    struct Canned {
        status: u16,
        body: String,
        seen: Mutex<Vec<HttpRequest>>,
    }

    impl Transport for Canned {
        fn send(&self, request: &HttpRequest) -> Result<HttpResponse, NetError> {
            self.seen.lock().unwrap().push(request.clone());
            Ok(HttpResponse { status: self.status, body: self.body.clone().into_bytes() })
        }
    }

    fn canned(status: u16, body: &str) -> Arc<Canned> {
        Arc::new(Canned { status, body: body.into(), seen: Mutex::new(vec![]) })
    }

    #[test]
    fn claude_request_and_answers() {
        let r = Claude::request("k", "sys", "hello", 8000);
        let body: Value = serde_json::from_slice(r.body.as_ref().unwrap()).unwrap();
        assert_eq!(body["model"], CLAUDE_MODEL);
        assert_eq!(body["output_config"]["effort"], "low");
        assert_eq!(r.header_value("x-api-key"), Some("k"));
        assert_eq!(Claude::parse(200, br#"{"content":[{"type":"thinking","thinking":""},{"type":"text","text":" Permit due Friday. "}]}"#), Ok("Permit due Friday.".into()));
        assert_eq!(Claude::parse(200, br#"{"stop_reason":"refusal","content":[]}"#), Err(ModelError::Refused));
        assert!(matches!(Claude::parse(401, br#"{"error":{"message":"invalid x-api-key"}}"#), Err(ModelError::Unavailable(_))));
        assert_eq!(Claude::parse(529, b"overloaded"), Err(ModelError::Failed("Claude answered 529: overloaded".into())));
    }

    #[test]
    fn claude_is_asked_for_json_when_lists_are_wanted() {
        let net = canned(200, r#"{"content":[{"type":"text","text":"{\"notes\":[\"Ted will call the county about the permit\"]}"}]}"#);
        let mut c = Claude::new("k".into(), net.clone());
        let notes = crate::meeting::summary::running_notes(&mut c, &[], "[0:05] Others: Ted will call the county about the permit.", "t").unwrap();
        assert_eq!(notes, vec!["Ted will call the county about the permit".to_string()]);
        let sent: Value = serde_json::from_slice(net.seen.lock().unwrap()[0].body.as_ref().unwrap()).unwrap();
        assert!(sent["system"].as_str().unwrap().contains("Answer with only a JSON object"));
    }

    #[test]
    fn ollama_check_and_schema_fallback() {
        let o = Ollama::new("", "qwen2.5:3b", canned(200, r#"{"models":[{"name":"qwen2.5:3b"}]}"#));
        assert_eq!(o.check(), None);
        assert_eq!(o.host, OLLAMA_HOST);
        let o = Ollama::new("http://127.0.0.1:11434/", "llama3", canned(200, r#"{"models":[{"name":"llama3:8b"}]}"#));
        assert_eq!(o.check(), None, "a bare name matches any tag");
        let o = Ollama::new("", "phi4", canned(200, r#"{"models":[]}"#));
        assert!(o.check().unwrap().contains("ollama pull phi4"));
    }

    #[test]
    fn a_question_carries_the_conversation() {
        let earlier = vec![QuestionTurn { question: "Who calls?".into(), answer: "Ted.".into(), asked_at: crate::notes::now() }];
        let p = questions::prompt("Permit call", "", "  bring forms ", &earlier, "When?");
        assert_eq!(p, "Meeting: Permit call\n\nTranscript so far:\n(nothing yet)\n\nJohn's notes:\nbring forms\n\nEarlier in this conversation:\nJohn: Who calls?\nYou: Ted.\n\nJohn asks: When?");
    }
}
