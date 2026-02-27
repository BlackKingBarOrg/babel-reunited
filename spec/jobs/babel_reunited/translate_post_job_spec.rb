# frozen_string_literal: true

RSpec.describe Jobs::BabelReunited::TranslatePostJob do
  fab!(:user)
  fab!(:topic) { Fabricate(:topic, user: user) }
  fab!(:post_record) { Fabricate(:post, topic: topic, user: user) }

  before do
    enable_current_plugin
    SiteSetting.babel_reunited_openai_api_key = "sk-test-key"
    SiteSetting.babel_reunited_preset_model = "gpt-4o"
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

  describe "successful translation" do
    let(:translation_result) do
      OpenStruct.new(
        translated_content: "<p>Hola mundo</p>",
        translated_title: "Titulo",
        source_language: "en",
      )
    end

    let(:successful_context) do
      context = Service::Base::Context.build
      context[:translation] = translation_result
      context[:ai_response] = {
        confidence: 0.95,
        provider_info: {
          model: "gpt-4o",
          provider: "openai",
        },
      }
      context
    end

    before do
      BabelReunited::TranslationService.any_instance.stubs(:call).returns(successful_context)
    end

    it "creates a completed translation record" do
      post_record.create_or_update_translation_record("es")

      described_class.new.execute(post_id: post_record.id, target_language: "es")

      translation = BabelReunited::PostTranslation.find_translation(post_record.id, "es")
      expect(translation.status).to eq("completed")
      expect(translation.translated_content).to include("Hola mundo")
    end

    it "publishes to MessageBus on success" do
      post_record.create_or_update_translation_record("es")

      messages =
        MessageBus.track_publish("/post-translations/#{post_record.id}") do
          described_class.new.execute(post_id: post_record.id, target_language: "es")
        end

      expect(messages.length).to eq(1)
      data = messages.first.data
      expect(data[:language]).to eq("es")
      expect(data[:status]).to eq("completed")
    end

    it "creates translation record if not pre-created" do
      described_class.new.execute(post_id: post_record.id, target_language: "es")

      translation = BabelReunited::PostTranslation.find_translation(post_record.id, "es")
      expect(translation).to be_present
      expect(translation.status).to eq("completed")
    end
  end

  describe "failed translation" do
    let(:failed_context) do
      context = Service::Base::Context.build
      context.fail(error: "API key not configured")
      context
    end

    before { BabelReunited::TranslationService.any_instance.stubs(:call).returns(failed_context) }

    it "marks translation as failed" do
      post_record.create_or_update_translation_record("es")

      described_class.new.execute(post_id: post_record.id, target_language: "es")

      translation = BabelReunited::PostTranslation.find_translation(post_record.id, "es")
      expect(translation.status).to eq("failed")
    end

    it "stores error in metadata" do
      post_record.create_or_update_translation_record("es")

      described_class.new.execute(post_id: post_record.id, target_language: "es")

      translation = BabelReunited::PostTranslation.find_translation(post_record.id, "es")
      expect(translation.metadata["error"]).to eq("API key not configured")
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
      post_record.create_or_update_translation_record("es")

      described_class.new.execute(post_id: post_record.id, target_language: "es")

      translation = BabelReunited::PostTranslation.find_translation(post_record.id, "es")
      expect(translation.status).to eq("failed")
      expect(translation.metadata["error"]).to eq("unexpected boom")
    end

    it "stores error class in metadata" do
      post_record.create_or_update_translation_record("es")

      described_class.new.execute(post_id: post_record.id, target_language: "es")

      translation = BabelReunited::PostTranslation.find_translation(post_record.id, "es")
      expect(translation.metadata["error_class"]).to eq("StandardError")
    end
  end
end
