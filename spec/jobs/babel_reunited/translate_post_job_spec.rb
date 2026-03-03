# frozen_string_literal: true

RSpec.describe Jobs::BabelReunited::TranslatePostJob do
  fab!(:user)
  fab!(:topic) { Fabricate(:topic, user: user) }
  fab!(:post_record) { Fabricate(:post, topic: topic, user: user) }

  before do
    enable_current_plugin
    SiteSetting.babel_reunited_openai_api_key = "sk-test-key"
    SiteSetting.babel_reunited_preset_model = "gpt-4o"
    Discourse.redis.flushdb
  end

  def success_result(
    translated_raw: "Hola mundo",
    translated_title: "Titulo",
    source_language: "en"
  )
    BabelReunited::TranslationService::Result.new(
      translated_raw: translated_raw,
      translated_title: translated_title,
      source_language: source_language,
      ai_response: {
        confidence: 0.95,
        provider_info: {
          model: "gpt-4o",
          provider: "openai",
        },
      },
    )
  end

  def failure_result(error: "API key not configured")
    BabelReunited::TranslationService::Result.new(error: error)
  end

  describe "argument validation" do
    it "returns early when post_id is blank" do
      expect { described_class.new.execute(post_id: nil, target_language: "es") }.not_to raise_error
    end

    it "returns early when target_language is blank" do
      expect {
        described_class.new.execute(post_id: post_record.id, target_language: nil)
      }.not_to raise_error
    end
  end

  describe "post validation" do
    it "skips non-existent posts" do
      expect { described_class.new.execute(post_id: -1, target_language: "es") }.not_to raise_error
    end

    it "skips deleted posts" do
      post_record.trash!
      expect {
        described_class.new.execute(post_id: post_record.id, target_language: "es")
      }.not_to raise_error
    end

    it "skips hidden posts" do
      post_record.update!(hidden: true)
      expect {
        described_class.new.execute(post_id: post_record.id, target_language: "es")
      }.not_to raise_error
    end
  end

  describe "Redis lock" do
    it "skips if another job holds the lock" do
      lock_key = "babel_reunited:translate:#{post_record.id}:es"
      Discourse.redis.set(lock_key, "1", ex: 300)

      BabelReunited::TranslationService.any_instance.expects(:call).never

      described_class.new.execute(post_id: post_record.id, target_language: "es")
    end

    it "releases lock after completion" do
      BabelReunited::TranslationService.any_instance.stubs(:call).returns(success_result)
      BabelReunited::PostTranslation.create_or_update_record(post_record.id, "es")

      described_class.new.execute(post_id: post_record.id, target_language: "es")

      lock_key = "babel_reunited:translate:#{post_record.id}:es"
      expect(Discourse.redis.exists?(lock_key)).to be false
    end
  end

  describe "source_sha check" do
    it "skips translation when source unchanged and not force_update" do
      translation = BabelReunited::PostTranslation.create_or_update_record(post_record.id, "es")
      sha = Digest::SHA256.hexdigest(post_record.raw)
      translation.update!(status: "completed", source_sha: sha, translated_content: "<p>old</p>")

      BabelReunited::TranslationService.any_instance.expects(:call).never

      described_class.new.execute(post_id: post_record.id, target_language: "es")
    end

    it "translates when force_update even if source unchanged" do
      translation = BabelReunited::PostTranslation.create_or_update_record(post_record.id, "es")
      sha = Digest::SHA256.hexdigest(post_record.raw)
      translation.update!(status: "completed", source_sha: sha, translated_content: "<p>old</p>")

      BabelReunited::TranslationService.any_instance.stubs(:call).returns(success_result)

      described_class.new.execute(
        post_id: post_record.id,
        target_language: "es",
        force_update: true,
      )

      translation.reload
      expect(translation.translated_content).to include("Hola mundo")
    end
  end

  describe "successful translation" do
    before { BabelReunited::TranslationService.any_instance.stubs(:call).returns(success_result) }

    it "creates a completed translation with cooked content" do
      BabelReunited::PostTranslation.create_or_update_record(post_record.id, "es")

      described_class.new.execute(post_id: post_record.id, target_language: "es")

      translation = BabelReunited::PostTranslation.find_translation(post_record.id, "es")
      expect(translation.status).to eq("completed")
      expect(translation.translated_content).to include("Hola mundo")
      expect(translation.translated_raw).to eq("Hola mundo")
      expect(translation.source_sha).to be_present
    end

    it "cooks translated_raw via PrettyText" do
      BabelReunited::TranslationService
        .any_instance
        .stubs(:call)
        .returns(success_result(translated_raw: "**Bold** text"))

      BabelReunited::PostTranslation.create_or_update_record(post_record.id, "es")
      described_class.new.execute(post_id: post_record.id, target_language: "es")

      translation = BabelReunited::PostTranslation.find_translation(post_record.id, "es")
      expect(translation.translated_raw).to eq("**Bold** text")
      expect(translation.translated_content).to include("<strong>Bold</strong>")
    end

    it "publishes success to MessageBus" do
      BabelReunited::PostTranslation.create_or_update_record(post_record.id, "es")

      messages =
        MessageBus.track_publish("/post-translations/#{post_record.id}") do
          described_class.new.execute(post_id: post_record.id, target_language: "es")
        end

      expect(messages.length).to eq(1)
      data = messages.first.data
      expect(data[:language]).to eq("es")
      expect(data[:status]).to eq("completed")
      expect(data[:translation][:translated_content]).to be_present
    end

    it "creates translation record if not pre-created" do
      described_class.new.execute(post_id: post_record.id, target_language: "es")

      translation = BabelReunited::PostTranslation.find_translation(post_record.id, "es")
      expect(translation).to be_present
      expect(translation.status).to eq("completed")
    end

    it "stores source_sha for incremental translation" do
      BabelReunited::PostTranslation.create_or_update_record(post_record.id, "es")
      described_class.new.execute(post_id: post_record.id, target_language: "es")

      translation = BabelReunited::PostTranslation.find_translation(post_record.id, "es")
      expect(translation.source_sha).to eq(Digest::SHA256.hexdigest(post_record.raw))
    end
  end

  describe "failed translation" do
    before { BabelReunited::TranslationService.any_instance.stubs(:call).returns(failure_result) }

    it "marks translation as failed" do
      BabelReunited::PostTranslation.create_or_update_record(post_record.id, "es")

      described_class.new.execute(post_id: post_record.id, target_language: "es")

      translation = BabelReunited::PostTranslation.find_translation(post_record.id, "es")
      expect(translation.status).to eq("failed")
    end

    it "stores error in metadata" do
      BabelReunited::PostTranslation.create_or_update_record(post_record.id, "es")

      described_class.new.execute(post_id: post_record.id, target_language: "es")

      translation = BabelReunited::PostTranslation.find_translation(post_record.id, "es")
      expect(translation.metadata["error"]).to eq("API key not configured")
    end

    it "publishes failure to MessageBus" do
      BabelReunited::PostTranslation.create_or_update_record(post_record.id, "es")

      messages =
        MessageBus.track_publish("/post-translations/#{post_record.id}") do
          described_class.new.execute(post_id: post_record.id, target_language: "es")
        end

      expect(messages.length).to eq(1)
      expect(messages.first.data[:status]).to eq("failed")
      expect(messages.first.data[:error]).to eq("API key not configured")
    end
  end

  describe "unexpected exceptions" do
    before do
      BabelReunited::TranslationService
        .any_instance
        .stubs(:call)
        .raises(StandardError.new("unexpected boom"))
    end

    it "marks translation as failed on exception" do
      BabelReunited::PostTranslation.create_or_update_record(post_record.id, "es")

      described_class.new.execute(post_id: post_record.id, target_language: "es")

      translation = BabelReunited::PostTranslation.find_translation(post_record.id, "es")
      expect(translation.status).to eq("failed")
      expect(translation.metadata["error"]).to eq("unexpected boom")
    end

    it "stores error class in metadata" do
      BabelReunited::PostTranslation.create_or_update_record(post_record.id, "es")

      described_class.new.execute(post_id: post_record.id, target_language: "es")

      translation = BabelReunited::PostTranslation.find_translation(post_record.id, "es")
      expect(translation.metadata["error_class"]).to eq("StandardError")
    end
  end
end
