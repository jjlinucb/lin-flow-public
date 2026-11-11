//! `next/proofs/LinFlow/Command.lean` proves when a take becomes a command, for a model of
//! `spoken_command`. This runs the real function on the takes in `next/proofs/vectors.json`,
//! which the proved model answered, and fails on any difference. Words are compared by their
//! letters, as the model sees them; punctuation is the Rust's own business.

use linflow_service::command::spoken_command;
use serde_json::Value;

fn letters(s: &str) -> String {
    s.chars().filter(|c| c.is_alphanumeric()).flat_map(char::to_lowercase).collect()
}

#[test]
fn spoken_commands_match_the_proved_model() {
    let path = concat!(env!("CARGO_MANIFEST_DIR"), "/../proofs/vectors.json");
    let vectors: Value = serde_json::from_str(&std::fs::read_to_string(path).unwrap()).unwrap();
    let cases = vectors["command"].as_array().unwrap();
    assert!(cases.len() >= 1000);
    for c in cases {
        let (word, take) = (c["word"].as_str().unwrap(), c["take"].as_str().unwrap());
        let got = spoken_command(take, word)
            .map(|cmd| cmd.split_whitespace().map(letters).filter(|w| !w.is_empty()).collect::<Vec<_>>());
        let want = c["command"].as_array().map(|ws| ws.iter().map(|w| w.as_str().unwrap().to_string()).collect::<Vec<_>>());
        assert_eq!(got, want, "{word:?} in {take:?}");
    }
}
