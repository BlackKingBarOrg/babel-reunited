# frozen_string_literal: true

Fabricator(:post_translation, class_name: "BabelReunited::PostTranslation") do
  post
  language "es"
  translated_content "<p>Hola mundo</p>"
  translated_title "Titulo traducido"
  source_language "en"
  translation_provider "openai"
  status "completed"
  # A real translation carries the fingerprint of the content it was made
  # from -- the job writes it, and the display guard checks it. Without this
  # every fixture is a translation of nothing in particular.
  source_sha do |attrs|
    Jobs::BabelReunited::TranslatePostJob.content_sha(attrs[:post])
  end
  metadata do
    { confidence: 0.95, provider_info: { model: "gpt-4o", provider: "openai" } }
  end
end
