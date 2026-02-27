# frozen_string_literal: true

Fabricator(:post_translation, class_name: "BabelReunited::PostTranslation") do
  post
  language "es"
  translated_content "<p>Hola mundo</p>"
  translated_title "Titulo traducido"
  source_language "en"
  translation_provider "openai"
  status "completed"
  metadata { { confidence: 0.95, provider_info: { model: "gpt-4o", provider: "openai" } } }
end
