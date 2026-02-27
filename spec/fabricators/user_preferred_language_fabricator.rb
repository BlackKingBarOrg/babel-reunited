# frozen_string_literal: true

Fabricator(:user_preferred_language, class_name: "BabelReunited::UserPreferredLanguage") do
  user
  language "en"
  enabled true
end
