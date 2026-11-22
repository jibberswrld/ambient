mod client;
pub mod publik;
mod session;
mod speech;
mod web_search;

pub use client::{PublikAiClient, PublikCredentialSource};
pub use session::{
    AmbientAgentSession, AMBIENT_BACKGROUND_AGENT_PROMPT, AMBIENT_BASE_SYSTEM_PROMPT,
};
pub use speech::{PublikSpeechClient, DEFAULT_VOICE};
pub use web_search::{PublikWebSearchProvider, WebSearchResult};

#[cfg(test)]
mod tests;
