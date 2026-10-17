use crate::Identity;
use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "lowercase")]
pub enum SwitchSensitivity { Low, #[default] Medium, High }

#[derive(Clone, Copy, Debug, Default, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase")]
pub enum StartupDisplay { #[default] LastUsed, Xnook, Xisland }

#[derive(Clone, Debug, Serialize, Deserialize, PartialEq, Eq)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct IntegrationPreferences {
    pub swipe_enabled: bool,
    pub sensitivity: SwitchSensitivity,
    pub startup_display: StartupDisplay,
}
impl Default for IntegrationPreferences {
    fn default() -> Self { Self { swipe_enabled: true, sensitivity: SwitchSensitivity::Medium, startup_display: StartupDisplay::LastUsed } }
}

#[derive(Default, Serialize, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub(crate) struct PreferenceRecord {
    #[serde(default)]
    pub preferences: IntegrationPreferences,
    pub last_shown: Option<Identity>,
}
impl PreferenceRecord {
    pub fn preferred(&self, previous_owner: Option<Identity>, current: Identity) -> Identity {
        match self.preferences.startup_display {
            StartupDisplay::LastUsed => previous_owner.or(self.last_shown).unwrap_or(current),
            StartupDisplay::Xnook => Identity::XNook,
            StartupDisplay::Xisland => Identity::XIsland,
        }
    }
}

#[cfg(test)]
mod tests {
    use super::*;
    #[test]
    fn preferences_are_strict_and_last_used_has_safe_fallback() {
        assert!(serde_json::from_str::<IntegrationPreferences>(r#"{"swipeEnabled":"false","sensitivity":"medium","startupDisplay":"lastUsed"}"#).is_err());
        assert!(serde_json::from_str::<IntegrationPreferences>(r#"{"swipeEnabled":true,"sensitivity":"bad","startupDisplay":"lastUsed"}"#).is_err());
        let record = PreferenceRecord::default();
        assert_eq!(record.preferred(None,Identity::XNook),Identity::XNook);
        assert_eq!(record.preferred(Some(Identity::XIsland),Identity::XNook),Identity::XIsland);
    }
}
