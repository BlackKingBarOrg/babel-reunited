# frozen_string_literal: true

RSpec.describe "BabelReunited module helpers" do
  fab!(:user)
  fab!(:topic) { Fabricate(:topic, user: user) }
  fab!(:post_record) { Fabricate(:post, topic: topic, user: user) }

  before do
    enable_current_plugin
    SiteSetting.babel_reunited_openai_api_key = "sk-test-key"
    SiteSetting.babel_reunited_preset_model = "gpt-4o"
  end

  describe "BabelReunited.enqueue_translation_jobs" do
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
        ) { BabelReunited.enqueue_translation_jobs(post_record, %w[es fr]) }
      end
    end

    it "does nothing when target_languages is blank" do
      BabelReunited.enqueue_translation_jobs(post_record, [])
    end
  end

  describe "PostTranslation.create_or_update_record" do
    it "creates a new translation record with translating status" do
      record = BabelReunited::PostTranslation.create_or_update_record(post_record.id, "es")
      expect(record.status).to eq("translating")
      expect(record.language).to eq("es")
      expect(record.post_id).to eq(post_record.id)
    end

    it "updates existing record to translating status" do
      Fabricate(:post_translation, post: post_record, language: "es", status: "completed")

      record = BabelReunited::PostTranslation.create_or_update_record(post_record.id, "es")
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

      record = BabelReunited::PostTranslation.create_or_update_record(post_record.id, "es")
      expect(record.status).to eq("translating")
    end
  end

  describe "PostTranslation.find_translation" do
    it "finds translation by post_id and language" do
      translation = Fabricate(:post_translation, post: post_record, language: "es")
      expect(BabelReunited::PostTranslation.find_translation(post_record.id, "es")).to eq(translation)
    end

    it "returns nil when not found" do
      expect(BabelReunited::PostTranslation.find_translation(post_record.id, "fr")).to be_nil
    end
  end
end
