# frozen_string_literal: true

RSpec.describe BabelReunited::PostExtension do
  fab!(:user)
  fab!(:topic) { Fabricate(:topic, user: user) }
  fab!(:post_record) { Fabricate(:post, topic: topic, user: user) }

  before do
    enable_current_plugin
    SiteSetting.babel_reunited_openai_api_key = "sk-test-key"
    SiteSetting.babel_reunited_preset_model = "gpt-4o"
  end

  describe "#get_translation" do
    it "finds translation by language" do
      translation = Fabricate(:post_translation, post: post_record, language: "es")
      expect(post_record.get_translation("es")).to eq(translation)
    end

    it "returns nil when not found" do
      expect(post_record.get_translation("fr")).to be_nil
    end
  end

  describe "#has_translation?" do
    it "returns true when translation exists" do
      Fabricate(:post_translation, post: post_record, language: "es")
      expect(post_record.has_translation?("es")).to be true
    end

    it "returns false when no translation exists" do
      expect(post_record.has_translation?("fr")).to be false
    end
  end

  describe "#available_translations" do
    it "returns all translation languages" do
      Fabricate(:post_translation, post: post_record, language: "es")
      Fabricate(:post_translation, post: post_record, language: "fr")
      expect(post_record.available_translations).to contain_exactly("es", "fr")
    end

    it "returns empty array when no translations" do
      expect(post_record.available_translations).to eq([])
    end
  end

  describe "#enqueue_translation_jobs" do
    it "enqueues jobs for each language" do
      expect_enqueued_with(
        job: Jobs::BabelReunited::TranslatePostJob,
        args: {
          post_id: post_record.id,
          target_language: "es",
        },
      ) do
        expect_enqueued_with(
          job: Jobs::BabelReunited::TranslatePostJob,
          args: {
            post_id: post_record.id,
            target_language: "fr",
          },
        ) { post_record.enqueue_translation_jobs(%w[es fr]) }
      end
    end

    it "does nothing when target_languages is blank" do
      post_record.enqueue_translation_jobs([])
    end
  end

  describe "#create_or_update_translation_record" do
    it "creates a new translation record with translating status" do
      record = post_record.create_or_update_translation_record("es")
      expect(record.status).to eq("translating")
      expect(record.language).to eq("es")
      expect(record.post_id).to eq(post_record.id)
    end

    it "updates existing record to translating status" do
      Fabricate(:post_translation, post: post_record, language: "es", status: "completed")

      record = post_record.create_or_update_translation_record("es")
      expect(record.status).to eq("translating")
    end

    it "handles race condition with RecordNotUnique" do
      BabelReunited::PostTranslation
        .stubs(:find_or_initialize_by)
        .raises(ActiveRecord::RecordNotUnique)
        .then
        .returns(nil)

      existing = Fabricate(:post_translation, post: post_record, language: "es")
      BabelReunited::PostTranslation.stubs(:find_translation).returns(existing)

      record = post_record.create_or_update_translation_record("es")
      expect(record.status).to eq("translating")
    end
  end
end
