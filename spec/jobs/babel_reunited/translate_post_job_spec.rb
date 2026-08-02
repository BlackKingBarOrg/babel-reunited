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
    Jobs.run_later!
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
          provider: "openai"
        }
      }
    )
  end

  def failure_result(error: "API key not configured")
    BabelReunited::TranslationService::Result.new(error: error)
  end

  describe "argument validation" do
    it "returns early when post_id is blank" do
      expect {
        described_class.new.execute(post_id: nil, target_language: "es")
      }.not_to raise_error
    end

    it "returns early when target_language is blank" do
      expect {
        described_class.new.execute(
          post_id: post_record.id,
          target_language: nil
        )
      }.not_to raise_error
    end
  end

  describe "post validation" do
    it "skips non-existent posts" do
      expect {
        described_class.new.execute(post_id: -1, target_language: "es")
      }.not_to raise_error
    end

    it "skips deleted posts" do
      post_record.trash!
      expect {
        described_class.new.execute(
          post_id: post_record.id,
          target_language: "es"
        )
      }.not_to raise_error
    end

    it "marks existing translation as failed when post is deleted" do
      BabelReunited::PostTranslation.create_or_update_record(
        post_record.id,
        "es"
      )
      post_record.trash!

      described_class.new.execute(
        post_id: post_record.id,
        target_language: "es"
      )

      translation =
        BabelReunited::PostTranslation.find_translation(post_record.id, "es")
      expect(translation.status).to eq("failed")
      expect(translation.metadata["error"]).to eq("post_not_found")
      expect(translation.metadata["error_kind"]).to eq("permanent")
    end

    it "skips hidden posts" do
      post_record.update!(hidden: true)
      expect {
        described_class.new.execute(
          post_id: post_record.id,
          target_language: "es"
        )
      }.not_to raise_error
    end

    it "marks existing translation as failed when post is hidden" do
      BabelReunited::PostTranslation.create_or_update_record(
        post_record.id,
        "es"
      )
      post_record.update!(hidden: true)

      described_class.new.execute(
        post_id: post_record.id,
        target_language: "es"
      )

      translation =
        BabelReunited::PostTranslation.find_translation(post_record.id, "es")
      expect(translation.status).to eq("failed")
      expect(translation.metadata["error"]).to eq("post_deleted_or_hidden")
    end

    it "skips posts in non-whitelisted categories" do
      blocked_category = Fabricate(:category)
      topic_in_blocked =
        Fabricate(:topic, user: user, category: blocked_category)
      blocked_post = Fabricate(:post, topic: topic_in_blocked, user: user)

      allowed_category = Fabricate(:category)
      SiteSetting.babel_reunited_enabled_categories = allowed_category.id.to_s

      BabelReunited::TranslationService.any_instance.expects(:call).never

      described_class.new.execute(
        post_id: blocked_post.id,
        target_language: "es"
      )
    end
  end

  describe "Redis lock" do
    it "skips if another job holds the lock" do
      lock_key = "babel_reunited:translate:#{post_record.id}:es"
      Discourse.redis.set(lock_key, "1", ex: 300)

      BabelReunited::TranslationService.any_instance.expects(:call).never

      described_class.new.execute(
        post_id: post_record.id,
        target_language: "es"
      )
    end

    it "releases lock after completion" do
      BabelReunited::TranslationService
        .any_instance
        .stubs(:call)
        .returns(success_result)
      BabelReunited::PostTranslation.create_or_update_record(
        post_record.id,
        "es"
      )

      described_class.new.execute(
        post_id: post_record.id,
        target_language: "es"
      )

      lock_key = "babel_reunited:translate:#{post_record.id}:es"
      expect(Discourse.redis.exists?(lock_key)).to be false
    end
  end

  describe "source_sha check" do
    it "skips translation when source unchanged and not force_update" do
      translation =
        BabelReunited::PostTranslation.create_or_update_record(
          post_record.id,
          "es"
        )
      sha = described_class.content_sha(post_record)
      translation.update!(
        status: "completed",
        source_sha: sha,
        translated_content: "<p>old</p>"
      )

      BabelReunited::TranslationService.any_instance.expects(:call).never

      described_class.new.execute(
        post_id: post_record.id,
        target_language: "es"
      )
    end

    it "re-announces completion when skipping an already completed translation" do
      translation =
        BabelReunited::PostTranslation.create_or_update_record(
          post_record.id,
          "es"
        )
      sha = described_class.content_sha(post_record)
      translation.update!(
        status: "completed",
        source_sha: sha,
        translated_content: "<p>old</p>"
      )

      BabelReunited::TranslationService.any_instance.expects(:call).never

      messages =
        MessageBus.track_publish("/post-translations/#{post_record.id}") do
          described_class.new.execute(
            post_id: post_record.id,
            target_language: "es"
          )
        end

      expect(messages.length).to eq(1)
      data = messages.first.data
      expect(data[:status]).to eq("completed")
      expect(data[:translation][:translated_content]).to eq("<p>old</p>")
    end

    it "translates when force_update even if source unchanged" do
      translation =
        BabelReunited::PostTranslation.create_or_update_record(
          post_record.id,
          "es"
        )
      sha = described_class.content_sha(post_record)
      translation.update!(
        status: "completed",
        source_sha: sha,
        translated_content: "<p>old</p>"
      )

      BabelReunited::TranslationService
        .any_instance
        .stubs(:call)
        .returns(success_result)

      described_class.new.execute(
        post_id: post_record.id,
        target_language: "es",
        force_update: true
      )

      translation.reload
      expect(translation.translated_content).to include("Hola mundo")
    end

    it "re-translates when the topic title changes on a first post" do
      translation =
        BabelReunited::PostTranslation.create_or_update_record(
          post_record.id,
          "es"
        )
      sha = described_class.content_sha(post_record)
      translation.update!(
        status: "completed",
        source_sha: sha,
        translated_content: "<p>old</p>"
      )

      post_record.topic.update!(title: "A completely different topic title")

      BabelReunited::TranslationService
        .any_instance
        .stubs(:call)
        .returns(success_result)

      described_class.new.execute(
        post_id: post_record.id,
        target_language: "es"
      )

      translation.reload
      expect(translation.translated_content).to include("Hola mundo")
    end
  end

  describe "mid-flight edit guard" do
    it "saves the result as stale and chases the new content when the post changes during translation" do
      job_result = success_result

      fake_service = Object.new
      target_post = post_record
      fake_service.define_singleton_method(:call) do
        target_post.update_columns(
          raw: "Content edited while the LLM was running"
        )
        job_result
      end
      BabelReunited::TranslationService.stubs(:new).returns(fake_service)

      BabelReunited::PostTranslation.create_or_update_record(
        post_record.id,
        "es"
      )

      messages =
        MessageBus.track_publish("/post-translations/#{post_record.id}") do
          described_class.new.execute(
            post_id: post_record.id,
            target_language: "es"
          )
        end

      translation =
        BabelReunited::PostTranslation.find_translation(post_record.id, "es")
      expect(translation.status).to eq("stale")
      expect(translation.translated_content).to include("Hola mundo")

      expect(messages.length).to eq(1)
      expect(messages.first.data[:translation][:status]).to eq("stale")

      expect(
        job_enqueued?(
          job: Jobs::BabelReunited::TranslatePostJob,
          args: {
            post_id: post_record.id,
            target_language: "es"
          }
        )
      ).to be true
    end
  end

  describe "stale fast-path" do
    it "heals a stale translation for free when content is unchanged" do
      translation =
        BabelReunited::PostTranslation.create_or_update_record(
          post_record.id,
          "es"
        )
      sha = described_class.content_sha(post_record)
      translation.update!(
        status: "stale",
        source_sha: sha,
        translated_content: "<p>old</p>"
      )

      BabelReunited::TranslationService.any_instance.expects(:call).never

      messages =
        MessageBus.track_publish("/post-translations/#{post_record.id}") do
          described_class.new.execute(
            post_id: post_record.id,
            target_language: "es"
          )
        end

      expect(translation.reload.status).to eq("completed")
      expect(messages.length).to eq(1)
      expect(messages.first.data[:status]).to eq("completed")
    end

    it "heals a view-claimed translating record with unchanged content" do
      translation =
        BabelReunited::PostTranslation.create_or_update_record(
          post_record.id,
          "es"
        )
      sha = described_class.content_sha(post_record)
      translation.update!(
        status: "completed",
        source_sha: sha,
        translated_content: "<p>old</p>"
      )
      expect(
        BabelReunited::PostTranslation.claim_existing(translation)
      ).to be true

      BabelReunited::TranslationService.any_instance.expects(:call).never

      described_class.new.execute(
        post_id: post_record.id,
        target_language: "es"
      )

      expect(translation.reload.status).to eq("completed")
    end

    it "heals a failed record whose content never changed" do
      translation =
        BabelReunited::PostTranslation.create_or_update_record(
          post_record.id,
          "es"
        )
      sha = described_class.content_sha(post_record)
      translation.update!(
        status: "failed",
        source_sha: sha,
        translated_content: "<p>old</p>",
        metadata: {
          "error_kind" => "transient"
        }
      )

      BabelReunited::TranslationService.any_instance.expects(:call).never

      described_class.new.execute(
        post_id: post_record.id,
        target_language: "es"
      )

      expect(translation.reload.status).to eq("completed")
    end

    it "re-translates a stale translation when content changed" do
      translation =
        BabelReunited::PostTranslation.create_or_update_record(
          post_record.id,
          "es"
        )
      translation.update!(
        status: "stale",
        source_sha: "0" * 64,
        translated_content: "<p>old</p>"
      )

      BabelReunited::TranslationService
        .any_instance
        .stubs(:call)
        .returns(success_result)

      described_class.new.execute(
        post_id: post_record.id,
        target_language: "es"
      )

      translation.reload
      expect(translation.status).to eq("completed")
      expect(translation.translated_content).to include("Hola mundo")
      expect(translation.source_sha).to eq(
        described_class.content_sha(post_record)
      )
    end
  end

  describe "successful translation" do
    before do
      BabelReunited::TranslationService
        .any_instance
        .stubs(:call)
        .returns(success_result)
    end

    it "creates a completed translation with cooked content" do
      BabelReunited::PostTranslation.create_or_update_record(
        post_record.id,
        "es"
      )

      described_class.new.execute(
        post_id: post_record.id,
        target_language: "es"
      )

      translation =
        BabelReunited::PostTranslation.find_translation(post_record.id, "es")
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

      BabelReunited::PostTranslation.create_or_update_record(
        post_record.id,
        "es"
      )
      described_class.new.execute(
        post_id: post_record.id,
        target_language: "es"
      )

      translation =
        BabelReunited::PostTranslation.find_translation(post_record.id, "es")
      expect(translation.translated_raw).to eq("**Bold** text")
      expect(translation.translated_content).to include("<strong>Bold</strong>")
    end

    it "publishes success to MessageBus" do
      BabelReunited::PostTranslation.create_or_update_record(
        post_record.id,
        "es"
      )

      messages =
        MessageBus.track_publish("/post-translations/#{post_record.id}") do
          described_class.new.execute(
            post_id: post_record.id,
            target_language: "es"
          )
        end

      expect(messages.length).to eq(1)
      data = messages.first.data
      expect(data[:language]).to eq("es")
      expect(data[:status]).to eq("completed")
      expect(data[:translation][:translated_content]).to be_present
    end

    it "creates translation record if not pre-created" do
      described_class.new.execute(
        post_id: post_record.id,
        target_language: "es"
      )

      translation =
        BabelReunited::PostTranslation.find_translation(post_record.id, "es")
      expect(translation).to be_present
      expect(translation.status).to eq("completed")
    end

    it "stores source_sha for incremental translation" do
      BabelReunited::PostTranslation.create_or_update_record(
        post_record.id,
        "es"
      )
      described_class.new.execute(
        post_id: post_record.id,
        target_language: "es"
      )

      translation =
        BabelReunited::PostTranslation.find_translation(post_record.id, "es")
      expect(translation.source_sha).to eq(
        described_class.content_sha(post_record)
      )
    end

    it "stores the detected locale as source_language" do
      BabelReunited.store_detected_locale(post_record, "en")

      described_class.new.execute(
        post_id: post_record.id,
        target_language: "es"
      )

      translation =
        BabelReunited::PostTranslation.find_translation(post_record.id, "es")
      expect(translation.source_language).to eq("en")
    end

    it "enqueues detection backfill for posts without a detected locale" do
      described_class.new.execute(
        post_id: post_record.id,
        target_language: "es"
      )

      expect(
        job_enqueued?(
          job: Jobs::BabelReunited::DetectPostLanguageJob,
          args: {
            post_id: post_record.id
          }
        )
      ).to be true
    end

    it "does not enqueue detection backfill when locale is already detected" do
      BabelReunited.store_detected_locale(post_record, "en")

      described_class.new.execute(
        post_id: post_record.id,
        target_language: "es"
      )

      expect(Jobs::BabelReunited::DetectPostLanguageJob.jobs).to be_empty
    end

    it "truncates translated title longer than 255 characters" do
      long_title = "A" * 300
      BabelReunited::TranslationService
        .any_instance
        .stubs(:call)
        .returns(success_result(translated_title: long_title))

      BabelReunited::PostTranslation.create_or_update_record(
        post_record.id,
        "es"
      )
      described_class.new.execute(
        post_id: post_record.id,
        target_language: "es"
      )

      translation =
        BabelReunited::PostTranslation.find_translation(post_record.id, "es")
      expect(translation.status).to eq("completed")
      expect(translation.translated_title.length).to eq(255)
      expect(translation.translated_title).to end_with("...")
    end
  end

  describe "cooked post-processing" do
    it "wraps translated images in lightboxes like regular posts" do
      upload = Fabricate(:image_upload, width: 150, height: 150)
      BabelReunited::TranslationService
        .any_instance
        .stubs(:call)
        .returns(success_result(translated_raw: "<img src=\"#{upload.url}\">"))

      BabelReunited::PostTranslation.create_or_update_record(
        post_record.id,
        "es"
      )
      described_class.new.execute(
        post_id: post_record.id,
        target_language: "es"
      )

      translation =
        BabelReunited::PostTranslation.find_translation(post_record.id, "es")
      expect(translation.status).to eq("completed")
      expect(translation.translated_content).to include("lightbox-wrapper")
    end

    it "expands oneboxes in translated content" do
      onebox_html =
        "<aside class=\"onebox\"><article class=\"onebox-body\">Example page</article></aside>"
      Oneboxer.stubs(:onebox).returns(onebox_html)

      BabelReunited::TranslationService
        .any_instance
        .stubs(:call)
        .returns(
          success_result(
            translated_raw: "https://example.com/interesting-article"
          )
        )

      BabelReunited::PostTranslation.create_or_update_record(
        post_record.id,
        "es"
      )
      described_class.new.execute(
        post_id: post_record.id,
        target_language: "es"
      )

      translation =
        BabelReunited::PostTranslation.find_translation(post_record.id, "es")
      expect(translation.status).to eq("completed")
      expect(translation.translated_content).to include("onebox-body")
    end

    it "falls back to plain cooked HTML when post-processing fails" do
      BabelReunited::TranslatedCookedPostProcessor
        .any_instance
        .stubs(:post_process)
        .raises(StandardError.new("boom"))
      BabelReunited::TranslationService
        .any_instance
        .stubs(:call)
        .returns(success_result)

      BabelReunited::PostTranslation.create_or_update_record(
        post_record.id,
        "es"
      )
      described_class.new.execute(
        post_id: post_record.id,
        target_language: "es"
      )

      translation =
        BabelReunited::PostTranslation.find_translation(post_record.id, "es")
      expect(translation.status).to eq("completed")
      expect(translation.translated_content).to include("Hola mundo")
    end
  end

  describe "failed translation" do
    before do
      BabelReunited::TranslationService
        .any_instance
        .stubs(:call)
        .returns(failure_result)
    end

    it "marks translation as failed" do
      BabelReunited::PostTranslation.create_or_update_record(
        post_record.id,
        "es"
      )

      described_class.new.execute(
        post_id: post_record.id,
        target_language: "es"
      )

      translation =
        BabelReunited::PostTranslation.find_translation(post_record.id, "es")
      expect(translation.status).to eq("failed")
    end

    it "stores error in metadata" do
      BabelReunited::PostTranslation.create_or_update_record(
        post_record.id,
        "es"
      )

      described_class.new.execute(
        post_id: post_record.id,
        target_language: "es"
      )

      translation =
        BabelReunited::PostTranslation.find_translation(post_record.id, "es")
      expect(translation.metadata["error"]).to eq("API key not configured")
    end

    it "classifies configuration errors as transient and counts the failure" do
      BabelReunited::PostTranslation.create_or_update_record(
        post_record.id,
        "es"
      )

      described_class.new.execute(
        post_id: post_record.id,
        target_language: "es"
      )

      translation =
        BabelReunited::PostTranslation.find_translation(post_record.id, "es")
      expect(translation.metadata["error_kind"]).to eq("transient")
      expect(translation.metadata["failure_count"]).to eq(1)
    end

    it "classifies content-too-long errors as permanent" do
      BabelReunited::TranslationService
        .any_instance
        .stubs(:call)
        .returns(failure_result(error: "Content too long for translation"))

      BabelReunited::PostTranslation.create_or_update_record(
        post_record.id,
        "es"
      )
      described_class.new.execute(
        post_id: post_record.id,
        target_language: "es"
      )

      translation =
        BabelReunited::PostTranslation.find_translation(post_record.id, "es")
      expect(translation.metadata["error_kind"]).to eq("permanent")
    end

    it "clears failure metadata after a later success" do
      BabelReunited::PostTranslation.create_or_update_record(
        post_record.id,
        "es"
      )
      described_class.new.execute(
        post_id: post_record.id,
        target_language: "es"
      )
      expect(
        BabelReunited::PostTranslation.find_translation(
          post_record.id,
          "es"
        ).metadata[
          "failure_count"
        ]
      ).to eq(1)

      BabelReunited::TranslationService
        .any_instance
        .stubs(:call)
        .returns(success_result)
      BabelReunited::PostTranslation.create_or_update_record(
        post_record.id,
        "es"
      )
      described_class.new.execute(
        post_id: post_record.id,
        target_language: "es"
      )

      translation =
        BabelReunited::PostTranslation.find_translation(post_record.id, "es")
      expect(translation.status).to eq("completed")
      expect(translation.metadata).not_to have_key("failure_count")
      expect(translation.metadata).not_to have_key("error_kind")
      expect(translation.metadata).not_to have_key("error")
    end

    it "increments failure_count across repeated failures" do
      BabelReunited::PostTranslation.create_or_update_record(
        post_record.id,
        "es"
      )
      described_class.new.execute(
        post_id: post_record.id,
        target_language: "es"
      )

      BabelReunited::PostTranslation.create_or_update_record(
        post_record.id,
        "es"
      )
      described_class.new.execute(
        post_id: post_record.id,
        target_language: "es"
      )

      translation =
        BabelReunited::PostTranslation.find_translation(post_record.id, "es")
      expect(translation.metadata["failure_count"]).to eq(2)
    end

    it "publishes failure to MessageBus" do
      BabelReunited::PostTranslation.create_or_update_record(
        post_record.id,
        "es"
      )

      messages =
        MessageBus.track_publish("/post-translations/#{post_record.id}") do
          described_class.new.execute(
            post_id: post_record.id,
            target_language: "es"
          )
        end

      expect(messages.length).to eq(1)
      expect(messages.first.data[:status]).to eq("failed")
      expect(messages.first.data[:error]).to eq("API key not configured")
    end
  end

  describe "rate limit retry" do
    before do
      BabelReunited::TranslationService
        .any_instance
        .stubs(:call)
        .raises(BabelReunited::RateLimitError.new("Rate limit exceeded"))
    end

    it "raises RateLimitError for Sidekiq retry" do
      BabelReunited::PostTranslation.create_or_update_record(
        post_record.id,
        "es"
      )

      expect {
        described_class.new.execute(
          post_id: post_record.id,
          target_language: "es"
        )
      }.to raise_error(BabelReunited::RateLimitError)
    end

    it "does not mark translation as failed" do
      BabelReunited::PostTranslation.create_or_update_record(
        post_record.id,
        "es"
      )

      begin
        described_class.new.execute(
          post_id: post_record.id,
          target_language: "es"
        )
      rescue StandardError
        nil
      end

      translation =
        BabelReunited::PostTranslation.find_translation(post_record.id, "es")
      expect(translation.status).not_to eq("failed")
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
      BabelReunited::PostTranslation.create_or_update_record(
        post_record.id,
        "es"
      )

      described_class.new.execute(
        post_id: post_record.id,
        target_language: "es"
      )

      translation =
        BabelReunited::PostTranslation.find_translation(post_record.id, "es")
      expect(translation.status).to eq("failed")
      expect(translation.metadata["error"]).to eq("unexpected boom")
    end

    it "stores error class in metadata" do
      BabelReunited::PostTranslation.create_or_update_record(
        post_record.id,
        "es"
      )

      described_class.new.execute(
        post_id: post_record.id,
        target_language: "es"
      )

      translation =
        BabelReunited::PostTranslation.find_translation(post_record.id, "es")
      expect(translation.metadata["error_class"]).to eq("StandardError")
    end
  end
end
