//! The text pipeline: what turns the engine's words into what gets pasted.

pub mod cleaner;
pub mod glossary;
pub mod matcher;
pub mod numbers;
pub mod unicode;

pub use cleaner::TextCleaner;
pub use glossary::Replacement;
