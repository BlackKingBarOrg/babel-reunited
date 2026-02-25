# frozen_string_literal: true

RSpec.describe BabelReunited::PostTranslationSerializer do
  fab!(:user)
  fab!(:topic) { Fabricate(:topic, user: user) }
  fab!(:post) { Fabricate(:post, topic: topic, user: user) }

  before { enable_current_plugin }

  # Create a clean record first, then inject dirty HTML via update_column
  # to bypass before_save callback — simulating historical dirty data in DB.
  def create_dirty_translation(content:, title: nil)
    translation =
      BabelReunited::PostTranslation.create!(
        post: post,
        language: "en",
        translated_content: "<p>placeholder</p>",
        translated_title: "placeholder",
        status: "completed",
        translation_provider: "openai",
        metadata: {
        },
      )
    translation.update_column(:translated_content, content)
    translation.update_column(:translated_title, title) if title
    translation.reload
  end

  def serialize(translation)
    described_class.new(translation, root: nil).as_json
  end

  describe "#translated_content (defense-in-depth for historical dirty data)" do
    it "strips script tags injected directly into DB" do
      translation = create_dirty_translation(content: "<p>Hello</p><script>alert(1)</script>")

      # Verify DB actually has dirty data (callback was bypassed)
      expect(translation.read_attribute(:translated_content)).to include("<script>")

      result = serialize(translation)
      expect(result[:translated_content]).not_to include("<script>")
      expect(result[:translated_content]).to include("<p>Hello</p>")
    end

    it "strips onerror attributes from dirty DB data" do
      translation = create_dirty_translation(content: '<img src="x" onerror="alert(1)">')

      result = serialize(translation)
      expect(result[:translated_content]).not_to include("onerror")
    end

    it "strips javascript: protocol from dirty DB data" do
      translation = create_dirty_translation(content: '<a href="javascript:alert(1)">click</a>')

      result = serialize(translation)
      expect(result[:translated_content]).not_to include("javascript:")
    end

    it "strips onclick from dirty DB data" do
      translation = create_dirty_translation(content: '<div onclick="alert(1)">text</div>')

      result = serialize(translation)
      expect(result[:translated_content]).not_to include("onclick")
    end

    it "strips svg/onload from dirty DB data" do
      translation = create_dirty_translation(content: '<svg onload="alert(1)"></svg>')

      result = serialize(translation)
      expect(result[:translated_content]).not_to include("onload")
    end

    it "preserves safe HTML from DB" do
      safe_html = '<p>Hello <strong>world</strong></p><a href="https://example.com">link</a>'
      translation = create_dirty_translation(content: safe_html)

      result = serialize(translation)
      expect(result[:translated_content]).to include("<p>")
      expect(result[:translated_content]).to include("<strong>world</strong>")
      expect(result[:translated_content]).to include("https://example.com")
    end

    it "is idempotent — clean data passes through unchanged" do
      translation =
        BabelReunited::PostTranslation.create!(
          post: post,
          language: "es",
          translated_content: "<p>Hola <strong>mundo</strong></p>",
          status: "completed",
          translation_provider: "openai",
          metadata: {
          },
        )
      # Model callback already cleaned it; serializer should return the same
      expect(serialize(translation)[:translated_content]).to eq(translation.translated_content)
    end
  end

  describe "#translated_title" do
    it "returns title as-is from DB (model already sanitized on save)" do
      translation =
        BabelReunited::PostTranslation.create!(
          post: post,
          language: "en",
          translated_content: "<p>content</p>",
          translated_title: "<script>alert(1)</script>",
          status: "completed",
          translation_provider: "openai",
          metadata: {
          },
        )

      # Model stripped HTML tags, title is now plain text "alert(1)"
      result = serialize(translation)
      expect(result[:translated_title]).not_to include("<script>")
      expect(result[:translated_title]).to eq("alert(1)")
    end

    it "preserves plain text titles" do
      translation =
        BabelReunited::PostTranslation.create!(
          post: post,
          language: "en",
          translated_content: "<p>content</p>",
          translated_title: "Hello World",
          status: "completed",
          translation_provider: "openai",
          metadata: {
          },
        )

      result = serialize(translation)
      expect(result[:translated_title]).to eq("Hello World")
    end

    it "does not double-escape historical data" do
      # Simulate old data that was saved with CGI.escapeHTML (the old bug)
      translation =
        BabelReunited::PostTranslation.create!(
          post: post,
          language: "es",
          translated_content: "<p>content</p>",
          translated_title: "clean title",
          status: "completed",
          translation_provider: "openai",
          metadata: {
          },
        )
      # Inject already-escaped HTML via update_column
      translation.update_column(:translated_title, "&lt;script&gt;alert(1)&lt;/script&gt;")
      translation.reload

      result = serialize(translation)
      # Serializer should NOT double-escape to &amp;lt;
      expect(result[:translated_title]).not_to include("&amp;")
    end
  end
end
